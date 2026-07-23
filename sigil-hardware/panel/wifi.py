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
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

WIFI_INTERFACE = os.environ.get('SIGIL_WIFI_INTERFACE', 'wlan0')

WIFI_CONTROL_SOCKET = os.environ.get(
    'SIGIL_WIFI_CONTROL_SOCKET', '/run/sigil/wifi-control.sock'
)
WIFI_CONTROL_STATE = os.environ.get(
    'SIGIL_WIFI_CONTROL_STATE', '/run/sigil/wifi-control-state.json'
)
# Shared with sigil-wifi-control.py.  The daemon stops iwlist at this limit;
# the panel keeps a small local-socket margin so it never abandons a scan while
# the daemon can still hold TRANSITION_LOCK.
WIFI_SCAN_TIMEOUT_SECONDS = float(
    os.environ.get('SIGIL_WIFI_SCAN_TIMEOUT_SECONDS', '4.0')
)
WIFI_SCAN_SOCKET_MARGIN_SECONDS = 0.25
WIFI_SCAN_SOCKET_TIMEOUT_SECONDS = (
    WIFI_SCAN_TIMEOUT_SECONDS + WIFI_SCAN_SOCKET_MARGIN_SECONDS
)

MIN_GEOLOCATION_RSSI_DBM = -92
_BSSID_PATTERN = re.compile(r'^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$')


class WifiCredentialError(ValueError):
    """A WiFi request is structurally invalid without exposing its secret."""


class WifiScanBusy(RuntimeError):
    """An active scan or WiFi ownership transition already has the radio."""


class WifiScanTimeout(RuntimeError):
    """The privileged scan exceeded its bounded execution time."""


class WifiControlUnavailable(RuntimeError):
    """The canonical WiFi control socket is temporarily unavailable."""


def _log_wifi_event(event_id: str, phase: str, result: str,
                    operation_id: str = 'none', error_id: str = 'none',
                    **details: object) -> None:
    """Emit a credential-free structured panel event to journald."""
    record: dict[str, object] = {
        'event_id': event_id,
        'operation_id': operation_id or 'none',
        'phase': phase,
        'result': result,
        'error_id': error_id,
        'realtime_utc': datetime.now(timezone.utc).isoformat(timespec='milliseconds'),
        'monotonic_ms': int(time.monotonic() * 1000),
    }
    record.update(details)
    logger.info('SIGIL_EVENT %s', json.dumps(record, sort_keys=True))


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
    """Ask the root service to perform a WiFi scan and return raw iwlist output.

    This is the ONLY scan path.  No sudo fallback — all scans route through
    sigil-wifi-control.service which owns the TRANSITION_LOCK.
    """
    resp = _send_wifi_command('scan')
    if resp.get('error'):
        err = resp.get('error', '')
        msg = resp.get('message', '')
        if err == 'busy' or (msg and 'busy' in msg.lower()):
            raise WifiScanBusy(msg or 'WiFi escaneo ocupado')
        if err == 'scan_timeout':
            raise WifiScanTimeout(msg or 'WiFi scan timed out')
        if err == 'wifi_control_unavailable':
            raise WifiControlUnavailable(msg or 'WiFi control unavailable')
        raise RuntimeError(msg or f'WiFi scan failed: {err}')
    scan_raw = resp.get('scan_data', '')
    if not scan_raw:
        raise RuntimeError('Empty scan result')
    return scan_raw

def _send_wifi_command(cmd: str, **kwargs) -> dict:
    """Send a JSON command to the root WiFi control socket and read reply."""
    safe_command = cmd if cmd in {
        'scan', 'connect', 'ensure_ap', 'restore_ap', 'recover_client',
        'deactivate_profile', 'status', 'probe', 'ping',
    } else 'unknown'
    _log_wifi_event('PANEL_WIFI_REQUEST', 'panel_socket_request', 'started',
                    command=safe_command)
    command_timeout = (
        WIFI_SCAN_SOCKET_TIMEOUT_SECONDS if cmd == 'scan' else 10.0
    )
    deadline = time.monotonic() + command_timeout

    def set_remaining_timeout(channel: socket.socket) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise socket.timeout('WiFi control command timed out')
        channel.settimeout(remaining)

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
            set_remaining_timeout(channel)
            channel.connect(WIFI_CONTROL_SOCKET)
            payload = {'command': cmd}
            payload.update(kwargs)
            set_remaining_timeout(channel)
            channel.sendall(json.dumps(payload).encode('utf-8') + b'\n')
            set_remaining_timeout(channel)
            data = channel.recv(65536)
        response = json.loads(data.decode('utf-8'))
        _log_wifi_event(
            'PANEL_WIFI_RESPONSE', 'panel_socket_response', 'complete',
            operation_id=str(response.get('operation_id', 'none')),
            error_id=str(response.get('error') or 'none'),
            command=safe_command, accepted=bool(response.get('accepted')),
            final_state=response.get('state'),
        )
        return response
    except socket.timeout as error:
        error_id = 'scan_timeout' if cmd == 'scan' else 'wifi_control_unavailable'
        _log_wifi_event(
            'WIFI_CONTROL_TIMEOUT', 'panel_socket_request', 'failure',
            error_id=error_id.upper(), command=safe_command,
            exception=type(error).__name__,
        )
        return {
            'error': error_id, 'accepted': False,
            'message': 'El control WiFi excedió el tiempo permitido',
        }
    except socket.error as error:
        _log_wifi_event(
            'WIFI_CONTROL_UNAVAILABLE', 'panel_socket_request', 'failure',
            error_id='WIFI_CONTROL_UNAVAILABLE', command=safe_command,
            exception=type(error).__name__,
        )
        return {
            'error': 'wifi_control_unavailable', 'accepted': False,
            'message': 'El control WiFi no está disponible',
        }
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        _log_wifi_event(
            'WIFI_CONTROL_PROTOCOL_ERROR', 'panel_socket_response', 'failure',
            error_id='WIFI_CONTROL_PROTOCOL_ERROR', command=safe_command,
            exception=type(error).__name__,
        )
        return {
            'error': 'wifi_control_protocol_error', 'accepted': False,
            'message': 'Respuesta inválida del control WiFi',
        }


def _read_control_state() -> dict | None:
    """Read the state file written by sigil-wifi-control.service."""
    try:
        with open(WIFI_CONTROL_STATE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


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
            return False, resp.get('message', resp['error'])
        if not resp.get('accepted'):
            return False, resp.get('message', 'Transición no aceptada')

        operation_id = resp.get('operation_id', '')
        _log_wifi_event('PANEL_WIFI_TRANSITION_ACCEPTED', 'panel_wait',
                        'success', operation_id=operation_id)

        # 2. Esperar a que el servicio complete la transición (timeout ~150s)
        # sigil-wifi-control handles stability checks and connectivity probing;
        # the panel trusts the state file written by the root daemon.
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            state = _read_control_state()
            if state and state.get('operation_id') == operation_id:
                # A terminal failure can be published as failed, ap_active, or
                # AP_RESTORE_FAILED.  Do not keep polling solely because its
                # phase is not the successful connected/idle phase.
                if state.get('success') is False:
                    msg = state.get('message', 'El servicio raíz falló la transición')
                    _log_wifi_event(
                        'PANEL_WIFI_FINAL_STATE', 'panel_final_state',
                        'failure', operation_id=operation_id,
                        error_id=str(state.get('error_id') or 'WIFI_TRANSITION_FAILED'),
                        final_state=state.get('phase'),
                    )
                    return False, msg
                if state.get('phase') in ('connected', 'idle'):
                    success = state.get('success')
                    if success is True:
                        msg = state.get('message', f'Conectado a {ssid}')
                        _log_wifi_event(
                            'PANEL_WIFI_FINAL_STATE', 'panel_final_state',
                            'success', operation_id=operation_id,
                            final_state=state.get('connectivity', {}).get(
                                'network_state', 'IP_ACQUIRED'),
                        )
                        return True, msg
                    # phase idle but no success flag → still running
            time.sleep(2)

        _log_wifi_event(
            'PANEL_WIFI_FINAL_STATE', 'panel_final_state', 'failure',
            operation_id=operation_id, error_id='WIFI_TRANSITION_TIMEOUT',
            final_state='WIFI_CONTROL_UNAVAILABLE',
        )
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
    """Return a canonical lowercase, colon-separated BSSID candidate."""
    return mac.strip().lower().replace('-', ':')


def _bssid_rejection_reason(mac: str) -> str | None:
    if not _BSSID_PATTERN.fullmatch(mac):
        return 'malformed'
    raw = bytes(int(part, 16) for part in mac.split(':'))
    if raw == b'\x00' * 6:
        return 'zero'
    if raw == b'\xff' * 6:
        return 'broadcast'
    if raw[0] & 0x01:
        return 'multicast'
    return None


def _is_locally_administered_bssid(mac: str) -> bool:
    return bool(int(mac.split(':', 1)[0], 16) & 0x02)


def _quality_ratio_to_dbm(numerator: int, denominator: int) -> int | None:
    """Approximate dBm from iwlist Quality when actual dBm is unavailable.

    Wireless drivers use different quality scales, so this compatibility
    fallback is intentionally secondary to a reported Signal level in dBm.
    """
    if denominator <= 0:
        return None
    ratio = max(0.0, min(1.0, numerator / denominator))
    return int(-100 + (ratio * 70))


def _frequency_to_channel(frequency_mhz: int) -> int | None:
    """Convert common 2.4 GHz and 5 GHz center frequencies to channels."""
    if frequency_mhz == 2484:
        return 14
    if 2412 <= frequency_mhz <= 2472 and (frequency_mhz - 2407) % 5 == 0:
        return (frequency_mhz - 2407) // 5
    if 5000 <= frequency_mhz <= 5900 and (frequency_mhz - 5000) % 5 == 0:
        channel = (frequency_mhz - 5000) // 5
        return channel if 1 <= channel <= 196 else None
    return None


def _parse_frequency_mhz(line: str) -> int | None:
    match = re.search(
        r'Frequency[:=]\s*([0-9]+(?:\.[0-9]+)?)\s*(GHz|MHz)',
        line,
        re.IGNORECASE,
    )
    if not match:
        return None
    value = float(match.group(1))
    if match.group(2).lower() == 'ghz':
        value *= 1000
    return int(round(value))


def scan_wifi_aps() -> list[dict]:
    """
    Escanea redes WiFi y devuelve lista de access points
    para geolocalización.
    Formato: [{'bssid': 'aa:bb:cc:dd:ee:ff', 'signal_dbm': -55, 'channel': 6}, ...]
    BSSIDs normalizados a minúsculas con separador ':'. Sin SSIDs.
    Duplicados eliminados (se conserva el de mejor señal).
    Ordenado por señal descendente.
    """
    try:
        scan_output = _scan_via_socket()

        seen: dict[str, dict] = {}
        rejected = {
            'malformed': 0,
            'zero': 0,
            'broadcast': 0,
            'multicast': 0,
            'invalid_signal': 0,
            'weak_signal': 0,
        }

        for block in scan_output.split('Cell '):
            if not block.strip():
                continue

            mac = ''
            rssi = None
            channel = None
            frequency_mhz = None
            quality_num = None
            quality_den = None

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
                    frequency_mhz = _parse_frequency_mhz(line)
                    fch = re.search(r'Channel\s*(\d+)', line)
                    if fch and channel is None:
                        channel = int(fch.group(1))

                if line.startswith('Quality='):
                    qm = re.search(r'Quality=(\d+)/(\d+)', line)
                    if qm:
                        quality_num = int(qm.group(1))
                        quality_den = int(qm.group(2))

                # Some drivers place Signal level on a separate line.
                sm = re.search(r'Signal level[=:]\s*(-?\d+)\s*dBm', line)
                if sm:
                    rssi = int(sm.group(1))

            if not mac:
                continue

            mac = _normalize_bssid(mac)
            rejection_reason = _bssid_rejection_reason(mac)
            if rejection_reason:
                rejected[rejection_reason] += 1
                continue

            if rssi is None and quality_num is not None and quality_den is not None:
                rssi = _quality_ratio_to_dbm(quality_num, quality_den)

            if rssi is None or rssi >= 0:
                rejected['invalid_signal'] += 1
                continue
            if rssi < MIN_GEOLOCATION_RSSI_DBM:
                rejected['weak_signal'] += 1
                continue

            if channel is None and frequency_mhz is not None:
                channel = _frequency_to_channel(frequency_mhz)

            if mac not in seen or rssi > seen[mac]['signal_dbm']:
                previous = seen.get(mac, {})
                entry = {
                    'bssid': mac,
                    'signal_dbm': rssi,
                    'locally_administered': _is_locally_administered_bssid(mac),
                }
                if channel is not None:
                    entry['channel'] = channel
                elif 'channel' in previous:
                    entry['channel'] = previous['channel']
                if frequency_mhz is not None:
                    entry['frequency_mhz'] = frequency_mhz
                elif 'frequency_mhz' in previous:
                    entry['frequency_mhz'] = previous['frequency_mhz']
                seen[mac] = entry

        aps = sorted(
            seen.values(),
            key=lambda item: (
                item['locally_administered'],
                -item['signal_dbm'],
            ),
        )
        logger.info(
            'WiFi geolocation scan parsed: valid=%d rejected=%s',
            len(aps),
            ','.join(f'{key}:{value}' for key, value in rejected.items()),
        )
        return aps

    except (WifiScanBusy, WifiScanTimeout, WifiControlUnavailable):
        raise
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        logger.error(
            'Error escaneando WiFi para geolocalización: %s',
            type(error).__name__,
        )
        return []
