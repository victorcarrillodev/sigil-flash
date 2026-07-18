"""
wifi.py — Lógica completa de gestión WiFi para el panel Sigil.
Usa iwlist para escanear (compatible con modo AP activo) y un servicio
root privilegiado para transiciones AP↔cliente.
"""
import json
import logging
import os
import re
import socket
import subprocess
import time
import uuid

logger = logging.getLogger(__name__)

WIFI_INTERFACE = os.environ.get('SIGIL_WIFI_INTERFACE', 'wlan0')

WIFI_CONTROL_SOCKET = os.environ.get(
    'SIGIL_WIFI_CONTROL_SOCKET', '/run/sigil/wifi-control.sock'
)
WIFI_CONTROL_STATE = os.environ.get(
    'SIGIL_WIFI_CONTROL_STATE', '/run/sigil/wifi-control-state.json'
)
WIFI_SCAN_LOCK = os.environ.get(
    'SIGIL_WIFI_SCAN_LOCK', '/run/sigil/wifi-scan.lock'
)
WIFI_SCAN_TIMEOUT_SECONDS = int(
    os.environ.get('SIGIL_WIFI_SCAN_TIMEOUT_SECONDS', '12')
)
WIFI_FALLBACK_HELPER = os.environ.get(
    'SIGIL_WIFI_FALLBACK_HELPER', '/usr/local/bin/wifi-fallback.sh'
)
WIFI_CONNECT_STABILIZATION_SECONDS = int(
    os.environ.get('SIGIL_WIFI_CONNECT_STABILIZATION_SECONDS', '90')
)
WIFI_CONNECT_STABLE_CHECKS = int(
    os.environ.get('SIGIL_WIFI_CONNECT_STABLE_CHECKS', '2')
)
WIFI_CONNECT_CHECK_INTERVAL = float(
    os.environ.get('SIGIL_WIFI_CONNECT_CHECK_INTERVAL', '3')
)


class WifiCredentialError(ValueError):
    """A WiFi request is structurally invalid without exposing its secret."""


class WifiScanBusy(RuntimeError):
    """An active scan or WiFi ownership transition already has the radio."""


def validate_wifi_credentials(ssid: object, password: object) -> tuple[str, str]:
    """Validate WiFi input while preserving the exact SSID and passphrase."""
    if not isinstance(ssid, str) or not ssid or not ssid.strip():
        raise WifiCredentialError('SSID requerido')
    if any(character in ssid for character in ('\x00', '\r', '\n')):
        raise WifiCredentialError('El SSID contiene caracteres no permitidos')
    if len(ssid.encode('utf-8')) > 32:
        raise WifiCredentialError('El SSID supera 32 bytes')
    if not isinstance(password, str):
        raise WifiCredentialError('La contraseña WiFi debe ser texto')
    if any(character in password for character in ('\x00', '\r', '\n')):
        raise WifiCredentialError('La contraseña contiene caracteres no permitidos')
    if not password:
        return ssid, password
    encoded_length = len(password.encode('utf-8'))
    is_raw_psk = bool(re.fullmatch(r'[0-9A-Fa-f]{64}', password))
    if not (8 <= encoded_length <= 63 or is_raw_psk):
        raise WifiCredentialError(
            'La contraseña WPA/WPA2 debe tener entre 8 y 63 bytes, o ser una clave hexadecimal de 64 caracteres'
        )
    return ssid, password


# ---------------------------------------------------------------------------
# Socket client for sigil-wifi-control.service (root privileged daemon)
# ---------------------------------------------------------------------------

def _scan_via_socket() -> str:
    """Ask the root service to perform a WiFi scan and return raw iwlist output."""
    resp = _send_wifi_command('scan')
    if resp.get('error'):
        # Fallback: direct sudo call (the scan command is not yet in root service)
        logger.warning('Socket scan failed, falling back to direct sudo: %s', resp.get('error'))
        result = subprocess.run(
            ['sudo', WIFI_FALLBACK_HELPER, '--panel-scan'],
            capture_output=True, text=True, timeout=WIFI_SCAN_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            raise RuntimeError(f'WiFi scan exited with status {result.returncode}')
        return result.stdout
    scan_raw = resp.get('scan_data', '')
    if not scan_raw:
        raise RuntimeError('Empty scan result')
    return scan_raw

def _send_wifi_command(cmd: str, **kwargs) -> dict:
    """Send a JSON command to the root WiFi control socket and read reply."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(WIFI_CONTROL_SOCKET)
        payload = {'command': cmd}
        payload.update(kwargs)
        s.sendall(json.dumps(payload).encode('utf-8') + b'\n')
        data = s.recv(65536)
        s.close()
        return json.loads(data.decode('utf-8'))
    except socket.error as e:
        return {'error': f'socket error: {e}', 'accepted': False}
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        return {'error': f'protocol error: {e}', 'accepted': False}


def _read_control_state() -> dict | None:
    """Read the state file written by sigil-wifi-control.service."""
    try:
        with open(WIFI_CONTROL_STATE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def _client_link_stable() -> bool:
    state = subprocess.run(
        ['nmcli', '-t', '-f', 'GENERAL.STATE', 'device', 'show', WIFI_INTERFACE],
        capture_output=True, text=True, timeout=5
    )
    if state.returncode != 0 or not (
        ':100' in state.stdout or '(connected)' in state.stdout
    ):
        return False
    address = subprocess.run(
        ['ip', '-o', 'address', 'show', 'dev', WIFI_INTERFACE, 'scope', 'global'],
        capture_output=True, text=True, timeout=5
    )
    return address.returncode == 0 and bool(address.stdout.strip())


def _wait_for_client_stability() -> bool:
    deadline = time.monotonic() + WIFI_CONNECT_STABILIZATION_SECONDS
    consecutive = 0
    while time.monotonic() <= deadline:
        if _client_link_stable():
            consecutive += 1
            if consecutive >= WIFI_CONNECT_STABLE_CHECKS:
                return True
        else:
            consecutive = 0
        time.sleep(WIFI_CONNECT_CHECK_INTERVAL)
    return False


def scan_wifi_networks() -> list[dict]:
    """
    Escanea redes WiFi con iwlist — funciona aunque hostapd esté activo.
    Devuelve lista ordenada por señal descendente.
    """
    try:
        scan_output = _scan_via_socket()

        networks, seen = [], set()
        saved_profiles = _get_saved_profiles()

        current_ssid = ''
        current_sig  = 0
        current_sec  = ''

        for line in scan_output.splitlines():
            line = line.strip()
            if line.startswith('Cell '):
                if current_ssid and current_ssid not in seen:
                    seen.add(current_ssid)
                    networks.append({
                        'ssid':     current_ssid,
                        'signal':   str(current_sig),
                        'security': current_sec,
                        'saved':    current_ssid in saved_profiles,
                    })
                current_ssid = ''
                current_sig  = 0
                current_sec  = ''
            elif line.startswith('ESSID:'):
                m = re.match(r'ESSID:"(.*)"', line)
                if m:
                    current_ssid = m.group(1)
            elif line.startswith('Quality='):
                m = re.search(r'Quality=(\d+)/(\d+)', line)
                if m:
                    num, den = int(m.group(1)), int(m.group(2))
                    current_sig = int((num / den) * 100) if den else 0
            elif line.startswith('Encryption key:on'):
                current_sec = 'WPA'

        # Agregar la última red
        if current_ssid and current_ssid not in seen:
            networks.append({
                'ssid':     current_ssid,
                'signal':   str(current_sig),
                'security': current_sec,
                'saved':    current_ssid in saved_profiles,
            })

        # Filtrar SSIDs vacíos/nulos y ordenar por señal
        networks = [n for n in networks if n['ssid'] and not n['ssid'].startswith('\\x00')]
        networks.sort(key=lambda x: int(x['signal']), reverse=True)
        return networks

    except WifiScanBusy:
        raise
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        logger.error('Error WiFi iwlist scan: %s', type(error).__name__)
        return []


def _get_saved_profiles() -> set[str]:
    """Devuelve el conjunto de SSIDs con perfil guardado en NetworkManager."""
    try:
        sp = subprocess.run(
            ['nmcli', '-t', '-f', 'NAME,TYPE', 'connection', 'show'],
            capture_output=True, text=True, timeout=5
        )
        saved = set()
        for line in sp.stdout.splitlines():
            parts = line.split(':')
            if len(parts) >= 2 and 'wireless' in parts[1]:
                saved.add(parts[0].strip())
        return saved
    except Exception:
        return set()


def _wifi_profile_exists(ssid: str) -> bool:
    """True si ya hay un perfil guardado para este SSID en NetworkManager."""
    return ssid in _get_saved_profiles()


def connect_wifi(ssid: str, password: str) -> tuple[bool, str]:
    """
    Conecta a una red WiFi delegando la transición AP→cliente al servicio
    root sigil-wifi-control via Unix socket, y espera estabilidad local.

    El servicio root gestiona el inhibit, la reconversión de interfaz,
    el perfil NM, el secreto y la activación en segundo plano; el panel
    solo valida, envía el comando y monitorea el resultado.
    """
    try:
        ssid, password = validate_wifi_credentials(ssid, password)

        # 1. Enviar comando connect al servicio root
        resp = _send_wifi_command('connect', ssid=ssid, password=password)
        if resp.get('error'):
            return False, resp['error']
        if not resp.get('accepted'):
            return False, resp.get('message', 'Transición no aceptada')

        operation_id = resp.get('operation_id', '')
        logger.info('WiFi connect accepted (operation_id=%s)', operation_id)

        # 2. Esperar a que el servicio complete la transición (timeout ~120s)
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            state = _read_control_state()
            if state and state.get('operation_id') == operation_id:
                if state.get('phase') in ('connected', 'idle'):
                    success = state.get('success')
                    if success is True:
                        # 3. Verificación extra de estabilidad local
                        if _wait_for_client_stability():
                            return True, f'Conectado a {ssid}'
                        return False, 'La conexión no alcanzó estabilidad'
                    elif success is False:
                        msg = state.get('message', 'El servicio raíz falló la transición')
                        return False, msg
                    # phase idle but no success flag → still running
            time.sleep(2)

        return False, 'Timeout: el servicio raíz no completó la transición'

    except WifiCredentialError:
        raise
    except Exception as e:
        logger.error('WiFi connect error: %s', type(e).__name__)
        return False, 'Error interno al enviar comando WiFi'


def get_current_wifi() -> str | None:
    """Devuelve el SSID de la red WiFi actualmente conectada, o None."""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'ACTIVE,SSID', 'dev', 'wifi'],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            if line.startswith('yes:'):
                return line.split(':', 1)[1].strip()
    except Exception:
        pass
    return None


def _normalize_bssid(mac: str) -> str:
    mac = mac.upper().replace('-', ':')
    parts = mac.split(':')
    if len(parts) == 6:
        return ':'.join(parts)
    return mac


def scan_wifi_aps() -> list[dict]:
    """
    Escanea redes WiFi y devuelve lista de access points
    para geolocalización.
    Formato: [{'bssid': 'AA:BB:CC:DD:EE:FF', 'signal_dbm': -55, 'channel': 6}, ...]
    BSSIDs normalizados a mayúsculas con separador ':'. Sin SSIDs.
    Duplicados eliminados (se conserva el de mejor señal).
    Ordenado por señal descendente.
    """
    try:
        scan_output = _scan_via_socket()

        seen = {}

        for block in scan_output.split('Cell '):
            if not block.strip():
                continue

            mac = ''
            rssi = None
            channel = None
            quality_num = 0
            quality_den = 1

            for line in block.splitlines():
                line = line.strip()

                if 'Address:' in line:
                    mac = line.split('Address:')[1].strip()
                    continue

                if 'Channel:' in line:
                    ch = re.search(r'Channel:\s*(\d+)', line)
                    if ch:
                        channel = int(ch.group(1))
                    continue

                if 'Frequency:' in line:
                    fch = re.search(r'Channel\s*(\d+)', line)
                    if fch and channel is None:
                        channel = int(fch.group(1))
                    continue

                if line.startswith('Quality='):
                    qm = re.search(r'Quality=(\d+)/(\d+)', line)
                    if qm:
                        quality_num = int(qm.group(1))
                        quality_den = int(qm.group(2)) or 1
                    sm = re.search(r'Signal level=(-?\d+)\s*dBm', line)
                    if sm:
                        rssi = int(sm.group(1))

            if not mac:
                continue

            mac = _normalize_bssid(mac)

            if rssi is None and quality_den > 0:
                pct = quality_num / quality_den
                rssi = int(-100 + (pct * 70))

            if rssi is None or rssi >= 0:
                continue

            if mac not in seen or rssi > seen[mac]['signal_dbm']:
                entry = {'bssid': mac, 'signal_dbm': rssi}
                if channel is not None:
                    entry['channel'] = channel
                seen[mac] = entry

        aps = sorted(seen.values(), key=lambda x: x['signal_dbm'], reverse=True)
        return aps

    except WifiScanBusy:
        raise
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        logger.error(
            'Error escaneando WiFi para geolocalización: %s',
            type(error).__name__,
        )
        return []
