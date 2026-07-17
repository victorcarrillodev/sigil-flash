"""Bluetooth discovery/status plus the panel-to-owner command contract."""
import fcntl
import subprocess
import re
import os
import time
import select
import json
import logging

from config import PREFERRED_BT_FILE, scan_lock

logger = logging.getLogger(__name__)
BT_OWNER_COMMAND = os.environ.get(
    "SIGIL_BT_OWNER_COMMAND", "/usr/local/bin/bt-connect.sh"
)
BT_TRANSITION_LOCK = os.environ.get(
    "SIGIL_BT_LOCK_FILE", "/run/sigil/bluetooth-transition.lock"
)
BT_OWNER_TIMEOUT_SECONDS = 75

# ── Utilidades ────────────────────────────────────────────────────────────────

def strip_ansi(text: str) -> str:
    """Elimina secuencias de escape ANSI de la salida de bluetoothctl."""
    return re.sub(r'\x1b\[[0-9;]*m', '', text)


def is_valid_mac(mac: str) -> bool:
    """Valida formato XX:XX:XX:XX:XX:XX."""
    return bool(re.match(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$', mac))


def _is_mac(s: str) -> bool:
    """True si el string parece una MAC (nombre inválido devuelto por bluetoothctl)."""
    return bool(re.match(r'^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$', s.strip()))


def _get_real_name(mac: str) -> str | None:
    """Consulta `bluetoothctl info` para obtener el nombre real del dispositivo."""
    try:
        info = subprocess.run(
            ['bluetoothctl', 'info', mac],
            capture_output=True, text=True, timeout=4
        )
        for line in strip_ansi(info.stdout).splitlines():
            m = re.match(r'\s+Name:\s+(.+)', line)
            if m:
                name = m.group(1).strip()
                if name and not _is_mac(name):
                    return name
    except Exception:
        pass
    return None


# ── Estado preferido ──────────────────────────────────────────────────────────

def get_preferred_device() -> str | None:
    """Read the owner-managed preferred MAC without following symlinks."""
    try:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(PREFERRED_BT_FILE, flags)
        with os.fdopen(fd, "r", encoding="ascii") as preferred_file:
            mac = preferred_file.read(18).strip().upper()
        return mac if is_valid_mac(mac) else None
    except (FileNotFoundError, OSError, UnicodeError):
        return None
    return None


# ── Estado de conexión REAL ───────────────────────────────────────────────────

def get_connected_devices() -> set[str]:
    """
    Devuelve el conjunto de MACs que BlueZ reporta como REALMENTE conectadas
    en este momento (bluetoothctl devices Connected).
    Esta es la fuente de verdad — no usar preferred_bt.txt para esto.
    """
    connected: set[str] = set()
    try:
        result = subprocess.run(
            ['bluetoothctl', 'devices', 'Connected'],
            capture_output=True, text=True, timeout=5
        )
        output = strip_ansi(result.stdout + result.stderr)
        for line in output.splitlines():
            m = re.search(r'Device ([0-9A-F:]{17})', line, re.IGNORECASE)
            if m:
                connected.add(m.group(1).upper())
    except Exception as e:
        logger.warning(f'Error get_connected_devices: {e}')
    return connected


def is_device_connected(mac: str) -> bool:
    """Verifica con bluetoothctl info si un MAC específico está conectado."""
    try:
        info = subprocess.run(
            ['bluetoothctl', 'info', mac],
            capture_output=True, text=True, timeout=4
        )
        return 'Connected: yes' in strip_ansi(info.stdout)
    except Exception:
        return False


# ── Dispositivos conocidos ────────────────────────────────────────────────────

def get_known_devices() -> list[dict]:
    """
    Devuelve lista de dispositivos BT emparejados conocidos por bluetoothctl.
    Incluye el campo 'connected' con el estado REAL de conexión de BlueZ,
    no basado en preferred_bt.txt.
    """
    try:
        result = subprocess.run(
            ['bluetoothctl', 'devices'],
            capture_output=True, text=True, timeout=5
        )
        output = strip_ansi(result.stdout + result.stderr)
        devices, seen = [], set()
        for line in output.splitlines():
            match = re.search(r'Device ([0-9A-F:]{17})\s+(.*)', line, re.IGNORECASE)
            if match:
                mac = match.group(1).upper()
                name = match.group(2).strip() or 'Desconocido'
                if mac not in seen:
                    seen.add(mac)
                    devices.append({'mac': mac, 'name': name})

        # Consultar estado de conexión real UNA sola vez para todos los dispositivos
        connected_macs = get_connected_devices()
        for d in devices:
            d['connected'] = d['mac'] in connected_macs

        return devices
    except Exception as e:
        logger.error(f'Error get_known_devices: {e}')
        return []


# ── SSE: Escaneo en tiempo real ───────────────────────────────────────────────

def _try_acquire_transition_lock():
    """Reserve the canonical BlueZ transition lock without blocking the UI."""
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

def stream_bluetooth_scan(preferred_mac: str | None, known_macs: set):
    """
    Generador SSE. Primero emite dispositivos ya conocidos al instante,
    luego abre un scan activo de 18 segundos emitiendo nuevos dispositivos.
    """
    seen = set()

    # Emitir conocidos al instante (con estado real de conexión)
    connected_macs = get_connected_devices()
    for d in get_known_devices():
        mac, name = d['mac'], d['name']
        if _is_mac(name):
            real = _get_real_name(mac)
            if real:
                name = real
        if mac not in seen:
            seen.add(mac)
            yield f'data: {json.dumps({"mac": mac, "name": name, "preferred": mac == preferred_mac, "connected": mac in connected_macs, "known": True})}\n\n'

    if scan_lock.locked():
        yield 'data: {"error": "Scan ya en progreso"}\n\n'
        return

    with scan_lock:
        transition_handle = _try_acquire_transition_lock()
        if transition_handle is None:
            yield 'data: {"error": "Bluetooth ocupado; reintenta en breve"}\n\n'
            return
        proc = None
        try:
            proc = subprocess.Popen(
                ['bluetoothctl'],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
            proc.stdin.write('scan on\n')
            proc.stdin.flush()

            deadline = time.time() + 18

            while time.time() < deadline:
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if not ready:
                    yield ': keep-alive\n\n'
                    continue

                line = proc.stdout.readline()
                if not line:
                    break

                line_clean = strip_ansi(line)
                match = re.search(
                    r'\[(NEW|CHG)\] Device ([0-9A-F:]{17})\s+(.*)',
                    line_clean, re.IGNORECASE
                )
                if not match:
                    continue

                event_type = match.group(1).upper()
                mac        = match.group(2).upper()
                raw_name   = match.group(3).strip()

                if not raw_name or _is_mac(raw_name):
                    real = _get_real_name(mac)
                    name = real if real else 'Desconocido'
                else:
                    name = raw_name

                is_connected = mac in connected_macs

                if event_type == 'NEW' and mac not in seen:
                    seen.add(mac)
                    yield f'data: {json.dumps({"mac": mac, "name": name, "preferred": mac == preferred_mac, "connected": is_connected, "known": mac in known_macs})}\n\n'
                elif event_type == 'CHG' and mac in seen:
                    if 'Name' in line_clean and not _is_mac(name):
                        yield f'data: {json.dumps({"mac": mac, "name": name, "preferred": mac == preferred_mac, "connected": is_connected, "known": mac in known_macs, "update": True})}\n\n'

            proc.stdin.write('scan off\nquit\n')
            proc.stdin.flush()
            proc.wait(timeout=3)

        except Exception as e:
            logger.error(f'Error BT stream scan: {e}')
        finally:
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
            _release_transition_lock(transition_handle)

    yield 'data: {"done": true}\n\n'


# ── Mutating operations (owned by bt-connect.sh) ──────────────────────────────

def _owner_request(operation: str, mac: str | None = None) -> tuple[bool, str]:
    """Run one bounded, structured request against the Bluetooth policy owner."""
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
        return False, "Timeout — la operación Bluetooth no terminó a tiempo"
    except OSError as exc:
        logger.error("No se pudo ejecutar el propietario Bluetooth: %s", exc)
        return False, "Servicio Bluetooth no disponible"

    try:
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        success = bool(payload.get("success")) and result.returncode == 0
        message = str(payload.get("message") or "Error Bluetooth")
        return success, message
    except (IndexError, TypeError, ValueError, json.JSONDecodeError):
        logger.error(
            "Respuesta inválida del propietario Bluetooth (rc=%s): %s",
            result.returncode,
            result.stderr.strip(),
        )
        return False, "Respuesta inválida del servicio Bluetooth"


def pair_device(mac: str) -> tuple[bool, str]:
    return _owner_request("pair", mac)


def connect_device(mac: str) -> tuple[bool, str]:
    return _owner_request("connect", mac)


def disconnect_device() -> tuple[bool, str]:
    return _owner_request("disconnect")


def remove_device(mac: str) -> tuple[bool, str]:
    return _owner_request("remove", mac)
