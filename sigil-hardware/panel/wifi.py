"""
wifi.py — Lógica completa de gestión WiFi para el panel Sigil.
Usa iwlist para escanear (compatible con modo AP activo) y nmcli para conectar.
"""
import fcntl
import json
import logging
import os
import re
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager

logger = logging.getLogger(__name__)

WIFI_INTERFACE = os.environ.get('SIGIL_WIFI_INTERFACE', 'wlan0')

WIFI_INHIBIT_FILE = os.environ.get(
    'SIGIL_WIFI_INHIBIT_FILE', '/run/sigil/wifi-fallback-inhibit.json'
)
WIFI_TRANSITION_LOCK = os.environ.get(
    'SIGIL_WIFI_TRANSITION_LOCK', '/run/sigil/wifi-transition.lock'
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
WIFI_CONNECT_INHIBIT_SECONDS = int(
    os.environ.get('SIGIL_WIFI_CONNECT_INHIBIT_SECONDS', '150')
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


class WifiScanBusy(RuntimeError):
    """An active scan or WiFi ownership transition already has the radio."""


class WifiCredentialError(ValueError):
    """A WiFi request is structurally invalid without exposing its secret."""


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


@contextmanager
def _nonblocking_lock(path: str, busy_message: str):
    """Acquire a process-safe flock; an unused stale lock file is harmless."""
    directory = os.path.dirname(path) or '.'
    os.makedirs(directory, mode=0o770, exist_ok=True)
    flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_CLOEXEC', 0)
    flags |= getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags, 0o660)
    handle = os.fdopen(fd, 'r+', encoding='utf-8')
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise WifiScanBusy(busy_message) from error
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


@contextmanager
def _wifi_scan_guard():
    """Serialize scans and exclude AP/client ownership transitions.

    Lock order is always transition then scan. wifi-fallback and panel client
    transitions already use the first lock, so they cannot change wlan0 while
    iwlist is actively using the single onboard radio.
    """
    with _nonblocking_lock(
        WIFI_TRANSITION_LOCK, 'Transición WiFi en progreso; reintenta en breve'
    ):
        with _nonblocking_lock(
            WIFI_SCAN_LOCK, 'Otro escaneo WiFi está en progreso; reintenta en breve'
        ):
            yield


def _run_active_wifi_scan() -> str:
    """Run the only production active-scan command under canonical locks."""
    with _wifi_scan_guard():
        result = subprocess.run(
            ['sudo', WIFI_FALLBACK_HELPER, '--panel-scan'],
            capture_output=True,
            text=True,
            timeout=WIFI_SCAN_TIMEOUT_SECONDS,
        )
    if result.returncode != 0:
        raise RuntimeError(f'WiFi scan exited with status {result.returncode}')
    return result.stdout


def _process_start_time(pid: int) -> int:
    with open(f'/proc/{pid}/stat', encoding='utf-8') as handle:
        remainder = handle.read().rsplit(')', 1)[1].split()
    return int(remainder[19])


def _create_fallback_inhibit() -> str:
    directory = os.path.dirname(WIFI_INHIBIT_FILE)
    os.makedirs(directory, mode=0o770, exist_ok=True)
    operation_id = uuid.uuid4().hex
    document = {
        '_schema_version': '1.0',
        'operation_id': operation_id,
        'reason': 'panel_connect_wifi',
        'pid': os.getpid(),
        'process_start_time': _process_start_time(os.getpid()),
        'created_at': int(time.time()),
        'expires_at': int(time.time()) + WIFI_CONNECT_INHIBIT_SECONDS,
    }
    fd, temporary = tempfile.mkstemp(prefix='.wifi-inhibit.', dir=directory)
    try:
        os.fchmod(fd, 0o640)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            fd = -1
            json.dump(document, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, WIFI_INHIBIT_FILE)
        temporary = ''
        directory_fd = os.open(directory, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    return operation_id


def _remove_fallback_inhibit(operation_id: str) -> None:
    try:
        with open(WIFI_INHIBIT_FILE, encoding='utf-8') as handle:
            document = json.load(handle)
        if document.get('operation_id') == operation_id:
            os.unlink(WIFI_INHIBIT_FILE)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass


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


def _run_owner_action(action: str) -> bool:
    """Ask the canonical root helper to change or commit wlan0 ownership."""
    try:
        result = subprocess.run(
            ['sudo', WIFI_FALLBACK_HELPER, action],
            capture_output=True, timeout=20
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        logger.error(
            'Canonical WiFi ownership action could not run: %s (%s)',
            action,
            type(error).__name__,
        )
        return False
    if result.returncode != 0:
        logger.error('Canonical WiFi ownership action failed: %s', action)
        return False
    return True


def _prepare_client_ownership() -> bool:
    return _run_owner_action('--prepare-client')


def _restore_ap_ownership() -> bool:
    return _run_owner_action('--restore-ap')


def _record_client_handoff() -> bool:
    return _run_owner_action('--external-client-handoff')


def _disable_power_save() -> bool:
    return _run_owner_action('--disable-power-save')


def _persist_client_secret(profile: str, password_file: str) -> bool:
    """Persist a system-owned PSK without exposing it through process argv."""
    try:
        result = subprocess.run(
            [
                'sudo', WIFI_FALLBACK_HELPER, '--persist-client-secret',
                profile, password_file,
            ],
            capture_output=True, timeout=20
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        logger.error('WiFi secret persistence could not run: %s', type(error).__name__)
        return False
    if result.returncode != 0:
        logger.error('WiFi secret persistence failed')
        return False
    return True


@contextmanager
def _nmcli_password_file(password: str):
    directory = os.path.dirname(WIFI_INHIBIT_FILE)
    fd, path = tempfile.mkstemp(prefix='.nmcli-password.', dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            fd = -1
            handle.write(f'802-11-wireless-security.psk:{password}\n')
            handle.flush()
            os.fsync(handle.fileno())
        yield path
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def scan_wifi_networks() -> list[dict]:
    """
    Escanea redes WiFi con iwlist — funciona aunque hostapd esté activo.
    Devuelve lista ordenada por señal descendente.
    """
    try:
        scan_output = _run_active_wifi_scan()

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
            ['sudo', 'nmcli', '-t', '-f', 'NAME,TYPE', 'connection', 'show'],
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
    Conecta a una red WiFi bajo el lock/inhibit canónico de transición.

    Detiene el AP, devuelve wlan0 a NetworkManager y espera asociación/DHCP
    estable. wifi-fallback continúa ejecutándose, pero no puede activar el AP
    durante este intervalo acotado.
    """
    transition_handle = None
    operation_id = ''
    ownership_attempted = False
    client_handoff_complete = False
    profile_created = False
    try:
        ssid, password = validate_wifi_credentials(ssid, password)
        os.makedirs(os.path.dirname(WIFI_TRANSITION_LOCK), mode=0o770, exist_ok=True)
        transition_handle = open(WIFI_TRANSITION_LOCK, 'a+', encoding='utf-8')
        try:
            fcntl.flock(transition_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False, 'Otra transición WiFi está en progreso'

        operation_id = _create_fallback_inhibit()

        # wifi-fallback is the only component that changes AP/client ownership.
        # The panel retains the lock and bounded inhibit for the whole request.
        ownership_attempted = True
        if not _prepare_client_ownership():
            return False, 'No se pudo devolver wlan0 a NetworkManager'

        profile_exists = _wifi_profile_exists(ssid)

        if password:
            if not profile_exists:
                add = subprocess.run(
                    ['sudo', 'nmcli', 'con', 'add',
                     'con-name', ssid, 'type', 'wifi', 'ifname', WIFI_INTERFACE, 'ssid', ssid],
                    capture_output=True, text=True, timeout=10
                )
                if add.returncode != 0:
                    return False, 'Error al crear el perfil WiFi'
                profile_created = True
            modified = subprocess.run(
                ['sudo', 'nmcli', 'con', 'mod', ssid,
                 'wifi-sec.key-mgmt', 'wpa-psk',
                 'ipv4.method', 'auto', 'ipv6.method', 'auto'],
                capture_output=True, timeout=10
            )
            if modified.returncode != 0:
                return False, 'Error al configurar el perfil WiFi'
            with _nmcli_password_file(password) as password_file:
                if not _persist_client_secret(ssid, password_file):
                    return False, 'No se pudo guardar la clave WiFi de forma segura'
                up = subprocess.run(
                    ['sudo', 'nmcli', 'con', 'up', ssid],
                    capture_output=True, text=True, timeout=45
                )
            _disable_power_save()
            if up.returncode != 0:
                return False, 'NetworkManager no pudo activar la conexión'
            if not _wait_for_client_stability():
                return False, 'La conexión no alcanzó asociación y DHCP estables'
            if not _record_client_handoff():
                return False, 'No se pudo confirmar el estado WiFi cliente'
            client_handoff_complete = True
            return True, f'Conectado a {ssid}'

        elif profile_exists:
            up = subprocess.run(['sudo', 'nmcli', 'con', 'up', ssid], capture_output=True, text=True, timeout=45)
            _disable_power_save()
            if up.returncode != 0:
                return False, 'NetworkManager no pudo reactivar la conexión guardada'
            if not _wait_for_client_stability():
                return False, 'La conexión guardada no alcanzó asociación y DHCP estables'
            if not _record_client_handoff():
                return False, 'No se pudo confirmar el estado WiFi cliente'
            client_handoff_complete = True
            return True, f'Reconectado a {ssid}'

        else:
            result = subprocess.run(
                ['sudo', 'nmcli', 'dev', 'wifi', 'connect', ssid],
                capture_output=True, text=True, timeout=45
            )
            _disable_power_save()
            if result.returncode != 0:
                return False, 'NetworkManager no pudo establecer la conexión'
            if not _wait_for_client_stability():
                return False, 'La conexión no alcanzó asociación y DHCP estables'
            if not _record_client_handoff():
                return False, 'No se pudo confirmar el estado WiFi cliente'
            client_handoff_complete = True
            return True, f'Conectado a {ssid}'

    except subprocess.TimeoutExpired:
        return False, 'Timeout: el comando tardó demasiado'
    except Exception as e:
        logger.error('WiFi transition failed: %s', type(e).__name__)
        return False, 'Error interno durante la transición WiFi'
    finally:
        if profile_created and not client_handoff_complete:
            try:
                subprocess.run(
                    ['sudo', 'nmcli', 'connection', 'delete', ssid],
                    capture_output=True,
                    timeout=10,
                )
            except (OSError, subprocess.TimeoutExpired):
                logger.error('Could not remove the incomplete WiFi profile')
        if operation_id and ownership_attempted and not client_handoff_complete:
            if not _restore_ap_ownership():
                logger.error('Canonical WiFi AP rollback failed')
        if transition_handle is not None:
            try:
                fcntl.flock(transition_handle.fileno(), fcntl.LOCK_UN)
            finally:
                transition_handle.close()
        if operation_id:
            _remove_fallback_inhibit(operation_id)


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
        scan_output = _run_active_wifi_scan()

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
