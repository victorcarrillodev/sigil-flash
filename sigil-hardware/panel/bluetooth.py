"""Bluetooth discovery/status plus the panel-to-owner command contract."""
import fcntl
import json
import logging
import os
import re
import select
import subprocess
import time

from config import PREFERRED_BT_FILE, scan_lock

logger = logging.getLogger(__name__)
BT_OWNER_COMMAND = os.environ.get(
    "SIGIL_BT_OWNER_COMMAND", "/usr/local/bin/bt-connect.sh"
)
BT_TRANSITION_LOCK = os.environ.get(
    "SIGIL_BT_LOCK_FILE", "/run/sigil/bluetooth-transition.lock"
)
BT_OWNER_TIMEOUT_SECONDS = 100
BT_SCAN_SECONDS = 18

_MAC_PATTERN = re.compile(r"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
_DEVICE_LINE = re.compile(
    r"Device ([0-9A-F:]{17})(?:\s+(.*))?$", re.IGNORECASE
)
_SCAN_EVENT = re.compile(
    r"\[(NEW|CHG)\]\s+Device\s+([0-9A-F:]{17})(?:\s+(.*))?$",
    re.IGNORECASE,
)
_ANSI_ESCAPE = re.compile(
    r"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))"
)


def strip_ansi(text: str) -> str:
    """Remove ANSI/CSI terminal control sequences from bluetoothctl output."""
    return _ANSI_ESCAPE.sub("", text).replace("\r", "\n")


def is_valid_mac(mac: str) -> bool:
    return isinstance(mac, str) and bool(_MAC_PATTERN.fullmatch(mac))


def _is_mac(value: str) -> bool:
    return isinstance(value, str) and bool(_MAC_PATTERN.fullmatch(value.strip()))


def _run_bluetoothctl(arguments: list[str], timeout: int = 5) -> str:
    result = subprocess.run(
        ["bluetoothctl", *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        return ""
    return strip_ansi(result.stdout + result.stderr)


def _parse_info(text: str) -> dict[str, object]:
    properties: dict[str, object] = {
        "name": "",
        "connected": False,
        "paired": False,
        "trusted": False,
        "icon": "",
        "class": None,
        "uuids": [],
    }
    uuids: list[str] = []
    for raw_line in strip_ansi(text).splitlines():
        line = raw_line.strip()
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        lowered = key.lower()
        if lowered in {"name", "alias"} and value and not properties["name"]:
            properties["name"] = value
        elif lowered == "connected":
            properties["connected"] = value.lower() == "yes"
        elif lowered == "paired":
            properties["paired"] = value.lower() == "yes"
        elif lowered == "trusted":
            properties["trusted"] = value.lower() == "yes"
        elif lowered == "icon":
            properties["icon"] = value
        elif lowered == "class":
            try:
                properties["class"] = int(value, 16)
            except ValueError:
                pass
        elif lowered == "uuid":
            uuids.append(value)
    properties["uuids"] = uuids
    return properties


def _is_audio_properties(properties: dict[str, object]) -> bool:
    icon = str(properties.get("icon") or "").lower()
    if any(word in icon for word in ("audio", "headset", "headphone")):
        return True
    uuids = " ".join(str(value) for value in properties.get("uuids", [])).lower()
    if any(word in uuids for word in ("audio sink", "advanced audio", "0000110b", "0000110d")):
        return True
    device_class = properties.get("class")
    return isinstance(device_class, int) and ((device_class >> 8) & 0x1F) == 4


def _device_info(mac: str, timeout: int = 4) -> dict[str, object]:
    return _parse_info(_run_bluetoothctl(["info", mac], timeout=timeout))


def _get_real_name(mac: str) -> str | None:
    name = str(_device_info(mac).get("name") or "").strip()
    return name if name and not _is_mac(name) else None


def get_preferred_device() -> str | None:
    """Read the owner-managed preferred MAC without following symlinks."""
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(PREFERRED_BT_FILE, flags)
        with os.fdopen(fd, "r", encoding="ascii") as preferred_file:
            mac = preferred_file.read(18).strip().upper()
        return mac if is_valid_mac(mac) else None
    except (FileNotFoundError, OSError, UnicodeError):
        return None


def get_connected_devices() -> set[str]:
    connected: set[str] = set()
    output = _run_bluetoothctl(["devices", "Connected"])
    for line in output.splitlines():
        match = _DEVICE_LINE.search(line)
        if match:
            connected.add(match.group(1).upper())
    return connected


def is_device_connected(mac: str) -> bool:
    return bool(_device_info(mac).get("connected"))


def get_known_devices() -> list[dict]:
    """Build one bounded BlueZ snapshot with at most one info call per MAC."""
    output = _run_bluetoothctl(["devices"])
    devices: list[dict] = []
    seen: set[str] = set()
    for line in output.splitlines():
        match = _DEVICE_LINE.search(line)
        if not match:
            continue
        mac = match.group(1).upper()
        if mac in seen:
            continue
        seen.add(mac)
        listed_name = (match.group(2) or "").strip()
        properties = _device_info(mac)
        if not _is_audio_properties(properties):
            continue
        name = str(properties.get("name") or listed_name or "Desconocido").strip()
        if _is_mac(name):
            name = "Desconocido"
        devices.append({
            "mac": mac,
            "name": name,
            "connected": bool(properties.get("connected")),
            "known": True,
        })
    return devices


def _try_acquire_transition_lock():
    try:
        directory = os.path.dirname(BT_TRANSITION_LOCK) or "."
        os.makedirs(directory, mode=0o770, exist_ok=True)
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(BT_TRANSITION_LOCK, flags, 0o660)
        handle = os.fdopen(fd, "r+", encoding="ascii")
    except OSError:
        return None
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError):
        handle.close()
        return None
    return handle


def _release_transition_lock(handle) -> None:
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def _event_name(raw_value: str, properties: dict[str, object]) -> str:
    value = raw_value.strip()
    if value.lower().startswith(("name:", "alias:")):
        value = value.split(":", 1)[1].strip()
    if not value or ":" in value and value.split(":", 1)[0].lower() in {
        "connected", "paired", "trusted", "rssi", "txpower", "servicesresolved"
    }:
        value = str(properties.get("name") or "")
    if _is_mac(value):
        value = str(properties.get("name") or "")
    return value if value and not _is_mac(value) else "Desconocido"


def stream_bluetooth_scan(preferred_mac: str | None):
    """Emit one snapshot and one serialized 18-second active discovery window."""
    if not scan_lock.acquire(blocking=False):
        yield 'data: {"error": "Scan ya en progreso"}\n\n'
        return
    transition_handle = None
    proc = None
    try:
        transition_handle = _try_acquire_transition_lock()
        if transition_handle is None:
            yield 'data: {"error": "Bluetooth ocupado; reintenta en breve"}\n\n'
            return

        seen: set[str] = set()
        for device in get_known_devices():
            mac = device["mac"]
            seen.add(mac)
            device["preferred"] = mac == preferred_mac
            yield f"data: {json.dumps(device, ensure_ascii=False)}\n\n"

        proc = subprocess.Popen(
            ["bluetoothctl"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if proc.stdin is None or proc.stdout is None:
            raise OSError("bluetoothctl pipes unavailable")
        proc.stdin.write("scan on\n")
        proc.stdin.flush()
        deadline = time.monotonic() + BT_SCAN_SECONDS
        info_cache: dict[str, dict[str, object]] = {}
        retry_unknown: set[str] = set()

        while time.monotonic() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 1.0)
            if not ready:
                yield ": keep-alive\n\n"
                continue
            line = proc.stdout.readline()
            if not line:
                break
            match = _SCAN_EVENT.search(strip_ansi(line))
            if not match:
                continue
            event_type = match.group(1).upper()
            mac = match.group(2).upper()
            raw_value = match.group(3) or ""
            properties = info_cache.get(mac)
            if properties is None or (mac in retry_unknown and event_type == "CHG"):
                properties = _device_info(mac, timeout=3)
                info_cache[mac] = properties
            if not _is_audio_properties(properties):
                retry_unknown.add(mac)
                continue
            retry_unknown.discard(mac)
            name = _event_name(raw_value, properties)
            if name == "Desconocido":
                continue
            event = {
                "mac": mac,
                "name": name,
                "preferred": mac == preferred_mac,
                "connected": bool(properties.get("connected")),
                "known": bool(properties.get("paired")) or mac in seen,
                "update": mac in seen,
            }
            seen.add(mac)
            yield f"data: {json.dumps(event, ensure_ascii=False)}\n\n"
    except (OSError, subprocess.SubprocessError) as error:
        logger.error("Bluetooth scan failed: %s", type(error).__name__)
        yield 'data: {"error": "El escaneo Bluetooth no pudo completarse"}\n\n'
    finally:
        if proc is not None:
            try:
                if proc.stdin is not None and proc.poll() is None:
                    proc.stdin.write("scan off\nquit\n")
                    proc.stdin.flush()
                    proc.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                proc.kill()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
        if transition_handle is not None:
            _release_transition_lock(transition_handle)
        scan_lock.release()
    yield 'data: {"done": true}\n\n'


def _owner_request(operation: str, mac: str | None = None) -> tuple[bool, str]:
    command = [BT_OWNER_COMMAND, "request", operation]
    if mac is not None:
        command.append(mac.upper())
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=BT_OWNER_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, "La operación Bluetooth agotó su tiempo de espera"
    except OSError as error:
        logger.error("Bluetooth owner unavailable: %s", type(error).__name__)
        return False, "Servicio Bluetooth no disponible"
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        logger.error("Invalid Bluetooth owner response (rc=%s)", result.returncode)
        return False, "Respuesta inválida del servicio Bluetooth"
    try:
        payload = json.loads(lines[0])
    except (TypeError, ValueError, json.JSONDecodeError):
        return False, "Respuesta inválida del servicio Bluetooth"
    success = bool(payload.get("success")) and result.returncode == 0
    return success, str(payload.get("message") or "Error Bluetooth")


def pair_device(mac: str) -> tuple[bool, str]:
    return _owner_request("pair", mac)


def connect_device(mac: str) -> tuple[bool, str]:
    return _owner_request("connect", mac)


def disconnect_device() -> tuple[bool, str]:
    return _owner_request("disconnect")


def remove_device(mac: str) -> tuple[bool, str]:
    return _owner_request("remove", mac)
