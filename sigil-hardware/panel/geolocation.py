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
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from wifi import WifiScanBusy, scan_wifi_aps
from device_identity import resolve_device_id

logger = logging.getLogger(__name__)

CONFIG_PATH = "/etc/sigil/audio.conf"
API_KEY_PATH = "/etc/sigil/secrets/device-api-key"
STATE_DIR = "/var/lib/sigil"
STATE_FILE = os.path.join(STATE_DIR, "geolocation_state.json")
LOCK_FILE = "/var/run/sigil/geolocate.lock"
SCHEMA_VERSION = "1.0"


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


def geolocate(server_url: str, api_key: str, device_id: str, config: dict) -> dict:
    min_aps = int(config.get("SIGIL_GEOLOCATION_MIN_APS", 2))
    max_aps = int(config.get("SIGIL_GEOLOCATION_MAX_APS", 30))
    timeout_sec = int(config.get("SIGIL_GEOLOCATION_TIMEOUT_SECONDS", 10))

    try:
        aps = scan_wifi_aps()
    except WifiScanBusy:
        logger.info("WiFi scan deferred: radio scan or transition is busy")
        return {
            "success": False,
            "error": "wifi_scan_busy",
            "retryable": True,
            "ap_count": 0,
        }

    if len(aps) < min_aps:
        return {
            "success": False,
            "error": f"not_enough_aps:{len(aps)}<{min_aps}",
            "ap_count": len(aps),
        }
    aps = aps[:max_aps]

    payload = json.dumps({
        "_schema_version": SCHEMA_VERSION,
        "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "wifi_access_points": aps,
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
                "ap_count": len(aps),
                "http_status": resp.status,
            }

        except urllib.error.HTTPError as e:
            e.read()
            logger.error("HTTP %d from geolocation endpoint", e.code)
            last_error = f"http_{e.code}"
            last_status = e.code
            if 400 <= e.code < 500:
                break
            time.sleep(2 ** attempt)

        except urllib.error.URLError as e:
            logger.error("URL error: %s", e.reason)
            last_error = f"network_error:{e.reason}"
            time.sleep(2 ** attempt)

        except socket.timeout:
            logger.error("Timeout (%ds)", timeout_sec)
            last_error = "timeout"
            time.sleep(2 ** attempt)

        except Exception as e:
            logger.error("Unexpected error: %s", e)
            last_error = f"error:{e}"
            break

    return {
        "success": False,
        "error": last_error,
        "ap_count": len(aps),
        "http_status": last_status,
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

    cooldown = int(config.get("SIGIL_GEOLOCATION_COOLDOWN_SECONDS", 3600))
    now = int(time.time())
    last_attempt = state.get("last_attempt_time", 0)
    if now - last_attempt < cooldown:
        logger.debug("Cooldown active (%ds remaining)", cooldown - (now - last_attempt))
        return 0

    result = geolocate(server_url, api_key, device_id, config)

    state["last_attempt_time"] = now
    state["last_ap_count"] = result.get("ap_count", 0)

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
            "OK: %.6f, %.6f (accuracy=%dm, APs=%d)",
            result["lat"], result["lng"], result["accuracy"], result["ap_count"],
        )
    else:
        logger.warning(
            "Failed: %s (APs=%d)", result.get("error"), result.get("ap_count", 0),
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
