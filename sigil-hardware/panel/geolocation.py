"""
geolocation.py — Geolocalización por WiFi para Sigil.
Escanea redes WiFi cercanas, envía los datos al servidor Sigil
y registra la ubicación. Sin interacción con el panel del cliente.
No crítica: los fallos no interrumpen audio, WiFi, SSH ni NetworkManager.
"""
import json
import logging
import os
import grp
import pwd
import socket
import stat
import statistics
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from wifi import (
    WIFI_SCAN_SOCKET_TIMEOUT_SECONDS,
    WifiControlUnavailable,
    WifiScanBusy,
    WifiScanTimeout,
    _bssid_rejection_reason,
    _frequency_to_channel,
    _is_locally_administered_bssid,
    _normalize_bssid,
    scan_wifi_aps,
)
from device_identity import resolve_device_id

logger = logging.getLogger(__name__)

CONFIG_PATH = "/etc/sigil/audio.conf"
API_KEY_PATH = "/etc/sigil/secrets/device-api-key"
STATE_DIR = "/var/lib/sigil"
STATE_FILE = os.path.join(STATE_DIR, "geolocation_state.json")
LOCK_FILE = "/var/run/sigil/geolocate.lock"
SCHEMA_VERSION = "1.0"

MAX_SCAN_SAMPLES = 3
SCAN_SAMPLE_DELAY_SECONDS = 0.75
SCAN_TOTAL_BUDGET_SECONDS = 15.0
SCAN_AGGREGATION_RESERVE_SECONDS = 0.5
MIN_QUALITY_BSSIDS = 4
MIN_STRONG_BSSIDS = 3
STRONG_RSSI_DBM = -85
MIN_RSSI_DBM = -92
DEFAULT_SHORT_COOLDOWN_SECONDS = 60


def _load_config(path: str) -> dict:
    config = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, _, val = line.partition("=")
                    config[key.strip()] = val.strip().strip('"').strip("'")
    except FileNotFoundError:
        logger.warning("Config not found: %s", path)
    return config


def _get_device_id() -> str:
    """Compatibility seam delegating all parsing to the canonical helper."""
    return resolve_device_id()


def _read_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {
            "_schema_version": SCHEMA_VERSION,
            "device_id": "",
            "last_attempt_time": 0,
            "last_success_time": 0,
            "last_result": "",
            "last_http_status": 0,
            "last_ap_count": 0,
            "last_retryable": False,
        }


def _atomic_write_json(path: str, document: dict) -> None:
    """Atomically replace JSON while preserving protected file metadata."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)

    if os.path.exists(path):
        metadata = os.stat(path)
        target_uid = metadata.st_uid
        target_gid = metadata.st_gid
        target_mode = stat.S_IMODE(metadata.st_mode)
    else:
        target_uid = pwd.getpwnam("sigil").pw_uid
        target_gid = grp.getgrnam("sigil").gr_gid
        target_mode = 0o660

    fd, temporary = tempfile.mkstemp(
        dir=directory,
        prefix=".geolocation-state.",
        suffix=".tmp",
    )
    try:
        os.fchown(fd, target_uid, target_gid)
        os.fchmod(fd, target_mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = ""
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_fd = os.open(directory, flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        if fd >= 0:
            os.close(fd)
        raise
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def _write_state(state: dict) -> None:
    allowed_fields = (
        "device_id",
        "last_attempt_time",
        "last_success_time",
        "last_result",
        "last_http_status",
        "last_ap_count",
        "last_retryable",
    )
    document = {"_schema_version": SCHEMA_VERSION}
    document.update({key: state[key] for key in allowed_fields if key in state})
    _atomic_write_json(STATE_FILE, document)


def _acquire_lock() -> bool:
    try:
        os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except (ImportError, OSError):
            os.close(fd)
            return False
    except Exception:
        return False


def _most_common(values: list[int]) -> int | None:
    if not values:
        return None
    counts: dict[int, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return max(counts, key=lambda value: (counts[value], -values.index(value)))


def _normalize_sample(sample: list[dict]) -> list[dict]:
    """Defensively normalize and deduplicate one scan without retaining SSIDs."""
    normalized: dict[str, dict] = {}
    for candidate in sample:
        bssid = _normalize_bssid(str(candidate.get("bssid", "")))
        if _bssid_rejection_reason(bssid):
            continue
        try:
            signal_dbm = int(candidate["signal_dbm"])
        except (KeyError, TypeError, ValueError):
            continue
        if signal_dbm >= 0 or signal_dbm < MIN_RSSI_DBM:
            continue

        frequency_mhz = candidate.get("frequency_mhz")
        try:
            frequency_mhz = int(frequency_mhz) if frequency_mhz is not None else None
        except (TypeError, ValueError):
            frequency_mhz = None

        channel = candidate.get("channel")
        try:
            channel = int(channel) if channel is not None else None
        except (TypeError, ValueError):
            channel = None
        if channel is None and frequency_mhz is not None:
            channel = _frequency_to_channel(frequency_mhz)

        observation = {
            "bssid": bssid,
            "signal_dbm": signal_dbm,
            "locally_administered": _is_locally_administered_bssid(bssid),
        }
        if channel is not None:
            observation["channel"] = channel
        if frequency_mhz is not None:
            observation["frequency_mhz"] = frequency_mhz

        previous = normalized.get(bssid)
        if previous is None or signal_dbm > previous["signal_dbm"]:
            normalized[bssid] = observation

    return list(normalized.values())


def _aggregate_samples(samples: list[list[dict]], max_aps: int = 30) -> list[dict]:
    """Aggregate scans by BSSID using median RSSI and observation stability."""
    observations: dict[str, dict] = {}
    for sample in samples:
        for ap in _normalize_sample(sample):
            record = observations.setdefault(ap["bssid"], {
                "signals": [],
                "channels": [],
                "frequencies": [],
                "locally_administered": ap["locally_administered"],
            })
            record["signals"].append(ap["signal_dbm"])
            if "channel" in ap:
                record["channels"].append(ap["channel"])
            if "frequency_mhz" in ap:
                record["frequencies"].append(ap["frequency_mhz"])

    aggregated: list[dict] = []
    for bssid, record in observations.items():
        frequency_mhz = _most_common(record["frequencies"])
        channel = _most_common(record["channels"])
        if channel is None and frequency_mhz is not None:
            channel = _frequency_to_channel(frequency_mhz)
        entry = {
            "bssid": bssid,
            "signal_dbm": int(round(statistics.median(record["signals"]))),
            "observation_count": len(record["signals"]),
            "locally_administered": record["locally_administered"],
        }
        if channel is not None:
            entry["channel"] = channel
        if frequency_mhz is not None:
            entry["frequency_mhz"] = frequency_mhz
        aggregated.append(entry)

    # Locally administered BSSIDs remain available when the scan does not have
    # enough stable global infrastructure.  Once four global BSSIDs have been
    # seen in multiple samples, local BSSIDs are unnecessary lower-confidence
    # inputs and are excluded before the strict stability/RSSI ordering.
    stable_global = [
        ap for ap in aggregated
        if not ap["locally_administered"] and ap["observation_count"] >= 2
    ]
    if len(stable_global) >= MIN_QUALITY_BSSIDS:
        aggregated = [ap for ap in aggregated if not ap["locally_administered"]]

    aggregated.sort(
        key=lambda ap: (-ap["observation_count"], -ap["signal_dbm"])
    )
    return aggregated[:min(30, max(1, max_aps))]


def _scan_quality_sufficient(aps: list[dict], min_aps: int) -> bool:
    required_count = max(MIN_QUALITY_BSSIDS, min_aps)
    strong_count = sum(ap["signal_dbm"] >= STRONG_RSSI_DBM for ap in aps)
    return len(aps) >= required_count and strong_count >= MIN_STRONG_BSSIDS


def _adaptive_wifi_scan(min_aps: int, max_aps: int) -> tuple[list[dict], dict]:
    """Collect at most three samples inside one hard 15-second scan budget."""
    started = time.monotonic()
    deadline = started + SCAN_TOTAL_BUDGET_SECONDS
    samples: list[list[dict]] = []
    attempts = 0
    retry_reason = "insufficient_scan_quality"

    while attempts < MAX_SCAN_SAMPLES:
        if attempts:
            required = (
                SCAN_SAMPLE_DELAY_SECONDS
                + WIFI_SCAN_SOCKET_TIMEOUT_SECONDS
                + SCAN_AGGREGATION_RESERVE_SECONDS
            )
            if deadline - time.monotonic() < required:
                retry_reason = "scan_budget_exhausted"
                break
            time.sleep(SCAN_SAMPLE_DELAY_SECONDS)

        if deadline - time.monotonic() < (
            WIFI_SCAN_SOCKET_TIMEOUT_SECONDS + SCAN_AGGREGATION_RESERVE_SECONDS
        ):
            retry_reason = "scan_budget_exhausted"
            break

        attempts += 1
        try:
            sample = scan_wifi_aps()
        except WifiScanBusy:
            retry_reason = "wifi_scan_busy"
            break
        except WifiScanTimeout:
            retry_reason = "scan_timeout"
            break
        except WifiControlUnavailable:
            retry_reason = "wifi_control_unavailable"
            break

        samples.append(sample)
        aggregated = _aggregate_samples(samples, max_aps=30)
        if _scan_quality_sufficient(aggregated, min_aps):
            retry_reason = ""
            break

    aps = _aggregate_samples(samples, max_aps=max_aps)
    elapsed = time.monotonic() - started
    signals = [ap["signal_dbm"] for ap in aps]
    logger.info(
        "WiFi geolocation sampling: samples=%d valid_aps=%d "
        "signal_min=%s signal_max=%s retry_reason=%s elapsed_ms=%d",
        attempts,
        len(aps),
        min(signals) if signals else "none",
        max(signals) if signals else "none",
        retry_reason or "none",
        int(elapsed * 1000),
    )
    return aps, {
        "samples": attempts,
        "elapsed": elapsed,
        "retry_reason": retry_reason,
        "sufficient": _scan_quality_sufficient(aps, min_aps),
    }


def _payload_access_points(aps: list[dict]) -> list[dict]:
    """Strip all internal confidence fields from the stable v1.0 payload."""
    payload_aps = []
    for ap in aps:
        payload_ap = {
            "bssid": ap["bssid"],
            "signal_dbm": ap["signal_dbm"],
        }
        if "channel" in ap:
            payload_ap["channel"] = ap["channel"]
        payload_aps.append(payload_ap)
    return payload_aps


def _cooldown_seconds(state: dict, config: dict) -> int:
    long_cooldown = int(config.get("SIGIL_GEOLOCATION_COOLDOWN_SECONDS", 3600))
    short_cooldown = int(config.get(
        "SIGIL_GEOLOCATION_SHORT_COOLDOWN_SECONDS",
        DEFAULT_SHORT_COOLDOWN_SECONDS,
    ))
    short_cooldown = max(30, min(120, short_cooldown))
    return short_cooldown if state.get("last_retryable", False) else long_cooldown


def geolocate(server_url: str, api_key: str, device_id: str, config: dict) -> dict:
    min_aps = int(config.get("SIGIL_GEOLOCATION_MIN_APS", 2))
    max_aps = max(1, min(30, int(config.get("SIGIL_GEOLOCATION_MAX_APS", 30))))
    timeout_sec = int(config.get("SIGIL_GEOLOCATION_TIMEOUT_SECONDS", 10))

    aps, scan = _adaptive_wifi_scan(min_aps=min_aps, max_aps=max_aps)
    if not scan["sufficient"]:
        reason = scan["retry_reason"] or "insufficient_scan_quality"
        if reason == "wifi_scan_busy":
            logger.info("WiFi scan deferred: radio scan or transition is busy")
        return {
            "success": False,
            "error": reason,
            "retryable": True,
            "ap_count": len(aps),
        }

    payload_aps = _payload_access_points(aps[:max_aps])

    payload = json.dumps({
        "_schema_version": SCHEMA_VERSION,
        "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "wifi_access_points": payload_aps,
    }).encode("utf-8")

    url = f"{server_url.rstrip('/')}/api/devices/{device_id}/geolocate"

    last_error = None
    last_status = 0

    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=payload, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("x-api-key", api_key)

            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                data = json.loads(resp.read().decode("utf-8"))

            return {
                "success": True,
                "lat": data.get("lat", 0),
                "lng": data.get("lng", 0),
                "accuracy": data.get("accuracy", 0),
                "ap_count": len(payload_aps),
                "http_status": resp.status,
                "retryable": False,
            }

        except urllib.error.HTTPError as e:
            logger.error("HTTP %d from geolocation endpoint", e.code)
            last_error = f"http_{e.code}"
            last_status = e.code
            if 400 <= e.code < 500:
                break
            if attempt < 2:
                time.sleep(2 ** attempt)

        except urllib.error.URLError as e:
            logger.error("Network unavailable: %s", type(e.reason).__name__)
            last_error = "network_unavailable"
            if attempt < 2:
                time.sleep(2 ** attempt)

        except socket.timeout:
            logger.error("Timeout (%ds)", timeout_sec)
            last_error = "timeout"
            if attempt < 2:
                time.sleep(2 ** attempt)

        except Exception as e:
            logger.error("Unexpected error: %s", e)
            last_error = f"error:{e}"
            break

    return {
        "success": False,
        "error": last_error,
        "ap_count": len(payload_aps),
        "http_status": last_status,
        "retryable": last_error in {"network_unavailable", "timeout"},
    }


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    if not _acquire_lock():
        logger.info("Another instance is running, exiting")
        return 0

    config = _load_config(CONFIG_PATH)
    server_url = config.get("SERVER_URL", "")
    try:
        api_key = Path(API_KEY_PATH).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        api_key = ""
    device_id = _get_device_id()

    if not server_url or not api_key:
        logger.warning("Server URL or API key not configured")
        return 0

    state = _read_state()
    state["device_id"] = device_id

    cooldown = _cooldown_seconds(state, config)
    now = int(time.time())
    last_attempt = state.get("last_attempt_time", 0)
    if now - last_attempt < cooldown:
        logger.debug("Cooldown active (%ds remaining)", cooldown - (now - last_attempt))
        return 0

    result = geolocate(server_url, api_key, device_id, config)

    state["last_attempt_time"] = now
    state["last_ap_count"] = result.get("ap_count", 0)
    state["last_retryable"] = bool(result.get("retryable", False))

    if result.get("success"):
        state["last_success_time"] = now
        state["last_result"] = "success"
        state["last_http_status"] = result.get("http_status", 200)
    else:
        state["last_result"] = result.get("error", "unknown")
        state["last_http_status"] = result.get("http_status", 0)

    _write_state(state)

    if result.get("success"):
        logger.info(
            "Geolocation succeeded: accuracy=%dm APs=%d",
            result["accuracy"], result["ap_count"],
        )
    else:
        logger.warning(
            "Failed: %s (APs=%d)", result.get("error"), result.get("ap_count", 0),
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
