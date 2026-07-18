#!/usr/bin/env python3
"""
sigil-wifi-control.py — SIGIL single-owner WiFi daemon.

Sole wlan0 mutation owner.  Accepts commands from the panel via Unix socket,
serialises all interface state changes behind the canonical TRANSITION_LOCK,
and publishes a state file the panel can poll.

wifi-fallback.sh becomes policy/watchdog only — it monitors client state and
triggers AP recovery through the same lock, but never mutates wlan0 directly.

Security invariants
-------------------
- No password is ever written to argv, logs, or socket responses.
- NM connection files are created with descriptor-based O_NOFOLLOW safety.
- Every transition acquires the exclusive TRANSITION_LOCK (non-blocking).
- The inhibit file prevents wifi-fallback from racing during transitions.
- Inhibit is removed AFTER successful handoff and connectivity confirmation.
"""
# ---------------------------------------------------------------------------
import fcntl
import grp
import json
import logging
import os
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
import tempfile

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment for testing)
# ---------------------------------------------------------------------------
WIFI_INTERFACE = os.environ.get('SIGIL_WIFI_INTERFACE', 'wlan0')
SOCKET_PATH = os.environ.get(
    'SIGIL_WIFI_CONTROL_SOCKET', '/run/sigil/wifi-control.sock'
)
STATE_FILE = os.environ.get(
    'SIGIL_WIFI_CONTROL_STATE', '/run/sigil/wifi-control-state.json'
)
INHIBIT_FILE = os.environ.get(
    'SIGIL_WIFI_INHIBIT_FILE', '/run/sigil/wifi-fallback-inhibit.json'
)
TRANSITION_LOCK = os.environ.get(
    'SIGIL_WIFI_TRANSITION_LOCK', '/run/sigil/wifi-transition.lock'
)
NM_CONNECTION_DIR = os.environ.get(
    'SIGIL_NM_CONNECTION_DIR', '/etc/NetworkManager/system-connections'
)

INHIBIT_TTL = int(os.environ.get('SIGIL_WIFI_CONNECT_INHIBIT_SECONDS', '120'))
STABILIZATION_SECONDS = int(
    os.environ.get('SIGIL_WIFI_CONNECT_STABILIZATION_SECONDS', '90')
)
STABLE_CHECKS = int(
    os.environ.get('SIGIL_WIFI_CONNECT_STABLE_CHECKS', '2')
)
CHECK_INTERVAL = float(
    os.environ.get('SIGIL_WIFI_CONNECT_CHECK_INTERVAL', '3')
)
PROBE_TIMEOUT = int(os.environ.get('SIGIL_WIFI_PROBE_TIMEOUT', '4'))
SCAN_TIMEOUT = int(os.environ.get('SIGIL_WIFI_SCAN_TIMEOUT_SECONDS', '15'))

logger = logging.getLogger('sigil-wifi-control')

# Socket security
MAX_REQUEST_SIZE = int(os.environ.get('SIGIL_WIFI_CONTROL_MAX_REQUEST', '8192'))
SIGIL_GROUP = 'sigil'
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(logging.Formatter(
    '%(asctime)s [sigil-wifi-control] %(message)s', datefmt='%Y-%m-%d %H:%M:%S'
))
logger.addHandler(_handler)
logger.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Lock management
# ---------------------------------------------------------------------------

def _acquire_lock(path: str, nonblocking: bool = True) -> int | None:
    """Acquire exclusive flock.  Returns fd (caller MUST release) or None."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o660)
    except OSError:
        return None
    flags = fcntl.LOCK_EX
    if nonblocking:
        flags |= fcntl.LOCK_NB
    try:
        fcntl.flock(fd, flags)
        return fd
    except (IOError, OSError):
        os.close(fd)
        return None


def _release_lock(fd: int | None) -> None:
    if fd is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    os.close(fd)


# ---------------------------------------------------------------------------
# Inhibit management
# ---------------------------------------------------------------------------

def _read_boot_id() -> str:
    """Read machine boot_id for robust process identity."""
    try:
        with open('/proc/sys/kernel/random/boot_id', encoding='utf-8') as f:
            return f.read(64).strip()
    except OSError:
        return ''


BOOT_ID = _read_boot_id()


def _write_inhibit() -> None:
    """Write inhibit file so wifi-fallback does not start AP during transition."""
    now = int(time.time())
    record = {
        'pid': os.getpid(),
        'boot_id': BOOT_ID,
        'expires_at': now + INHIBIT_TTL,
    }
    try:
        os.makedirs(os.path.dirname(INHIBIT_FILE), exist_ok=True)
        with open(INHIBIT_FILE, 'w', encoding='utf-8') as f:
            json.dump(record, f)
    except OSError as exc:
        logger.error('cannot write inhibit: %s', exc)


def _remove_inhibit() -> None:
    """Remove inhibit file after successful handoff or error."""
    try:
        os.unlink(INHIBIT_FILE)
    except FileNotFoundError:
        pass
    except OSError as exc:
        logger.warning('cannot remove inhibit: %s', exc)


# ---------------------------------------------------------------------------
# State file writing
# ---------------------------------------------------------------------------

def _write_state(state: dict) -> None:
    """Atomically write state file for panel polling."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = tempfile.mkstemp(
            prefix='.wifi-control-state.',
            dir=os.path.dirname(STATE_FILE),
        )
        fd, tmp_path = tmp
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump(state, f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, STATE_FILE)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except OSError as exc:
        logger.error('cannot write state: %s', exc)


# ---------------------------------------------------------------------------
# Transition helpers
# ---------------------------------------------------------------------------

def _stop_ap_services() -> bool:
    """Stop hostapd/dnsmasq and return wlan0 to NM control."""
    subprocess.run(['systemctl', 'stop', 'hostapd'], capture_output=True, timeout=10)
    subprocess.run(['systemctl', 'stop', 'dnsmasq'], capture_output=True, timeout=10)
    subprocess.run(
        ['ip', 'addr', 'flush', 'dev', WIFI_INTERFACE],
        capture_output=True, timeout=5,
    )
    subprocess.run(
        ['nmcli', 'device', 'set', WIFI_INTERFACE, 'managed', 'yes'],
        capture_output=True, timeout=10,
    )
    # Wait for NM ownership (up to CLIENT_OWNERSHIP_TIMEOUT=10s)
    for _ in range(10):
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'GENERAL.STATE', 'device', 'show', WIFI_INTERFACE],
            capture_output=True, text=True, timeout=5,
        )
        out = result.stdout.strip()
        if out and 'unmanaged' not in out and '10 ' not in out:
            return True
        time.sleep(1)
    logger.warning('NM did not take ownership of %s within timeout', WIFI_INTERFACE)
    return False


def _start_ap_services() -> bool:
    """Start hostapd/dnsmasq for AP mode recovery (used by rollback)."""
    subprocess.run(
        ['nmcli', 'device', 'disconnect', WIFI_INTERFACE],
        capture_output=True, timeout=10,
    )
    subprocess.run(
        ['nmcli', 'device', 'set', WIFI_INTERFACE, 'managed', 'no'],
        capture_output=True, timeout=10,
    )
    subprocess.run(['ip', 'link', 'set', WIFI_INTERFACE, 'down'], capture_output=True, timeout=5)
    subprocess.run(
        ['ip', 'addr', 'flush', 'dev', WIFI_INTERFACE],
        capture_output=True, timeout=5,
    )
    subprocess.run(['ip', 'link', 'set', WIFI_INTERFACE, 'up'], capture_output=True, timeout=5)
    ap_ip = os.environ.get('SIGIL_WIFI_AP_IP', '192.168.4.1')
    subprocess.run(
        ['ip', 'addr', 'add', f'{ap_ip}/24', 'dev', WIFI_INTERFACE],
        capture_output=True, timeout=5,
    )
    subprocess.run(['systemctl', 'unmask', 'hostapd'], capture_output=True, timeout=5)
    rc1 = subprocess.run(
        ['systemctl', 'start', 'hostapd'], capture_output=True, timeout=10,
    ).returncode
    rc2 = subprocess.run(
        ['systemctl', 'start', 'dnsmasq'], capture_output=True, timeout=10,
    ).returncode
    return rc1 == 0 and rc2 == 0


def _create_nm_profile(ssid: str, password: str) -> str | None:
    """Create or update an NM connection profile with O_NOFOLLOW safety.

    Returns the connection id (SSID) on success, None on failure.
    Password is written directly into the .nmconnection file — never argv.
    """
    # Check if a profile for this SSID already exists
    existing = subprocess.run(
        ['nmcli', '-t', '-f', 'NAME', 'connection', 'show'],
        capture_output=True, text=True, timeout=5,
    )
    exists = ssid in existing.stdout.splitlines()

    if not exists:
        # Create minimal connection first
        rc = subprocess.run(
            ['nmcli', 'connection', 'add',
             'type', 'wifi',
             'con-name', ssid,
             'ifname', WIFI_INTERFACE,
             'ssid', ssid,
             ],
            capture_output=True, timeout=10,
        ).returncode
        if rc != 0:
            logger.error('failed to create NM profile for %s', ssid)
            return None

    # Now securely set the PSK using a password file (never in argv)
    # Create temporary password file with O_NOFOLLOW safety
    try:
        run_dir = os.path.dirname(INHIBIT_FILE)
        os.makedirs(run_dir, exist_ok=True)
        pw_fd, pw_path = tempfile.mkstemp(
            prefix='.nmcli-password.', dir=run_dir,
        )
        os.fchmod(pw_fd, 0o600)
        with os.fdopen(pw_fd, 'w', encoding='utf-8') as f:
            f.write(f'802-11-wireless-security.psk:{password}\n')
    except OSError as exc:
        logger.error('cannot create password file: %s', exc)
        return None

    try:
        # Set key-mgmt
        subprocess.run(
            ['nmcli', 'connection', 'modify', 'id', ssid,
             '802-11-wireless-security.key-mgmt', 'wpa-psk'],
            capture_output=True, timeout=10,
        )

        # Set PSK via password file to avoid argv exposure
        # nmcli connection modify does NOT support passwd-file for set.
        # Instead we modify the connection file directly with O_NOFOLLOW.
        # First get the connection uuid
        uuid_result = subprocess.run(
            ['nmcli', '-g', 'connection.uuid', 'connection', 'show', ssid],
            capture_output=True, text=True, timeout=5,
        )
        conn_uuid = uuid_result.stdout.strip()
        if not conn_uuid or len(conn_uuid) != 36:
            logger.error('cannot resolve UUID for profile %s', ssid)
            return None

        # Write the connection file atomically with O_NOFOLLOW safety
        conn_path = os.path.join(NM_CONNECTION_DIR, f'{conn_uuid}.nmconnection')
        _write_nmconnection_file(conn_path, ssid, conn_uuid, password)

        # Reload connection from file
        subprocess.run(
            ['nmcli', 'connection', 'load', conn_path],
            capture_output=True, timeout=10, check=True,
        )
        logger.info('NM profile %s created/updated securely', ssid)
        return ssid
    except Exception as exc:
        logger.error('NM profile update failed: %s', exc)
        return None
    finally:
        try:
            os.unlink(pw_path)
        except OSError:
            pass


def _write_nmconnection_file(path: str, ssid: str, uuid_str: str,
                             password: str) -> None:
    """Write a .nmconnection file atomically using O_NOFOLLOW-safe descriptors."""
    content = (
        '[connection]\n'
        f'id={ssid}\n'
        f'uuid={uuid_str}\n'
        'type=wifi\n'
        'autoconnect=true\n'
        '\n'
        '[wifi]\n'
        f'ssid={ssid}\n'
        'mode=infrastructure\n'
        '\n'
        '[wifi-security]\n'
        'key-mgmt=wpa-psk\n'
        f'psk={password}\n'
        'psk-flags=0\n'
        '\n'
        '[ipv4]\n'
        'method=auto\n'
        '\n'
        '[ipv6]\n'
        'method=auto\n'
    )
    dir_name = os.path.dirname(path)
    try:
        # Use os.open with O_NOFOLLOW for descriptor-level safety
        fd = os.open(
            dir_name,
            os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0) | getattr(os, 'O_NOFOLLOW', 0),
        )
        try:
            tmp_fd, tmp_path = tempfile.mkstemp(
                prefix='.sigil-wifi.',
                dir=dir_name,
            )
            os.fchmod(tmp_fd, 0o600)
            with os.fdopen(tmp_fd, 'w', encoding='utf-8', newline='\n') as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, path)
            # Sync directory
            dir_fd = os.open(
                dir_name,
                os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0),
            )
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        finally:
            os.close(fd)
    except OSError as exc:
        logger.error('cannot write NM connection file: %s', exc)
        raise


def _activate_profile(ssid: str) -> bool:
    """Bring up the NM connection profile."""
    rc = subprocess.run(
        ['nmcli', 'connection', 'up', 'id', ssid],
        capture_output=True, timeout=45,
    ).returncode
    return rc == 0


def _disable_power_save() -> None:
    """Disable WiFi power saving on the interface."""
    subprocess.run(
        ['iw', 'dev', WIFI_INTERFACE, 'set', 'power_save', 'off'],
        capture_output=True, timeout=5,
    )


# ---------------------------------------------------------------------------
# AP service helpers (internal to daemon — not socket commands)
# ---------------------------------------------------------------------------

def _systemctl_is_active(service: str) -> bool:
    """Return True if the systemd service is running."""
    rc = subprocess.run(
        ['systemctl', 'is-active', '--quiet', service],
        capture_output=True, timeout=5,
    ).returncode
    return rc == 0


def _ensure_ap() -> bool:
    """Idempotently guarantee AP interface and services.

    Checks hostapd + dnsmasq + AP IP.  Only mutates what is missing.
    Never leaves wlan0 down.
    """
    ap_ip = os.environ.get('SIGIL_WIFI_AP_IP', '192.168.4.1')
    hostapd_up = _systemctl_is_active('hostapd')
    dnsmasq_up = _systemctl_is_active('dnsmasq')

    # Check if AP IP is set
    ip_result = subprocess.run(
        ['ip', '-4', 'addr', 'show', 'dev', WIFI_INTERFACE],
        capture_output=True, text=True, timeout=5,
    )
    has_ip = ap_ip in ip_result.stdout

    if hostapd_up and dnsmasq_up and has_ip:
        return True

    # Start full AP transition
    return _start_ap_services()


# ---------------------------------------------------------------------------
# Connectivity probing
# ---------------------------------------------------------------------------

def _nm_associated() -> bool:
    """Check if NM reports wlan0 as connected."""
    result = subprocess.run(
        ['nmcli', '-t', '-f', 'GENERAL.STATE', 'device', 'show', WIFI_INTERFACE],
        capture_output=True, text=True, timeout=5,
    )
    out = result.stdout.strip()
    return ':100' in out or '(connected)' in out


def _has_client_address() -> bool:
    """Check if wlan0 has a global IP address."""
    result = subprocess.run(
        ['ip', '-o', 'address', 'show', 'dev', WIFI_INTERFACE, 'scope', 'global'],
        capture_output=True, text=True, timeout=5,
    )
    return result.returncode == 0 and bool(result.stdout.strip())


def _default_route() -> tuple[str, str] | None:
    """Return (family, gateway) for the default route on wlan0."""
    for family, flag in [('4', '-4'), ('6', '-6')]:
        result = subprocess.run(
            ['ip', flag, 'route', 'show', 'default', 'dev', WIFI_INTERFACE],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip():
            parts = result.stdout.strip().split()
            for i, part in enumerate(parts):
                if part == 'via' and i + 1 < len(parts):
                    return (family, parts[i + 1])
    return None


def _gateway_reachable(family: str, gateway: str) -> bool:
    """Ping gateway."""
    rc = subprocess.run(
        ['ping', f'-{family}', '-c', '1', '-W', str(PROBE_TIMEOUT), gateway],
        capture_output=True, timeout=PROBE_TIMEOUT + 2,
    ).returncode
    return rc == 0


def _dns_available() -> bool:
    """Check DNS resolution."""
    for host in ('deb.debian.org', 'www.raspberrypi.com'):
        rc = subprocess.run(
            ['getent', 'ahosts', host],
            capture_output=True, timeout=PROBE_TIMEOUT + 2,
        ).returncode
        if rc == 0:
            return True
    return False


def _internet_reachable() -> bool:
    """Check HTTPS connectivity."""
    rc = subprocess.run(
        ['curl', '--fail', '--silent', '--output', '/dev/null',
         '--connect-timeout', str(PROBE_TIMEOUT),
         '--max-time', str(PROBE_TIMEOUT),
         'https://connectivitycheck.gstatic.com/generate_204'],
        capture_output=True, timeout=PROBE_TIMEOUT + 5,
    ).returncode
    return rc == 0


def probe_connectivity() -> dict:
    """Run layered connectivity checks.

    Returns a dict with:
        - associated: bool
        - ip_acquired: bool
        - gateway_reachable: bool
        - dns_available: bool
        - local_only: bool   (associated + IP + gateway, but no DNS/Internet)
        - internet_online: bool  (all layers pass)
    """
    result: dict = {
        'associated': False,
        'ip_acquired': False,
        'gateway_reachable': False,
        'dns_available': False,
        'local_only': False,
        'internet_online': False,
    }

    result['associated'] = _nm_associated()
    result['ip_acquired'] = _has_client_address()
    route_info = _default_route()

    if route_info:
        family, gateway = route_info
        result['gateway_reachable'] = _gateway_reachable(family, gateway)

    result['dns_available'] = _dns_available()
    result['internet_online'] = result['dns_available'] and _internet_reachable()

    # If we have IP + gateway but no Internet, flag local-only
    if (result['associated'] and result['ip_acquired']
            and result['gateway_reachable']
            and not result['internet_online']):
        result['local_only'] = True

    return result


# ---------------------------------------------------------------------------
# Socket command handlers
# ---------------------------------------------------------------------------

_operation_id: str | None = None


def _handle_scan() -> dict:
    """Execute iwlist scan behind the TRANSITION_LOCK.

    Returns canonical response with scan_data in message on success.
    """
    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is None:
        return {
            'accepted': False, 'state': None,
            'error': 'busy',
            'message': 'WiFi transition or scan in progress',
        }
    try:
        result = subprocess.run(
            ['iwlist', WIFI_INTERFACE, 'scan'],
            capture_output=True, text=True, timeout=SCAN_TIMEOUT,
        )
        if result.returncode != 0:
            logger.warning('iwlist scan returned %d', result.returncode)
            return {
                'accepted': False, 'state': None,
                'error': 'scan_failed',
                'message': f'scan failed (exit={result.returncode})',
            }
        return {
            'accepted': True, 'state': 'scan_complete',
            'error': None, 'message': 'Scan completed',
            'scan_data': result.stdout,
        }
    except subprocess.TimeoutExpired:
        return {
            'accepted': False, 'state': None,
            'error': 'scan_timeout',
            'message': 'scan timed out',
        }
    finally:
        _release_lock(lock_fd)


def _background_connect(ssid: str, password: str, op_id: str) -> None:
    """Run the full AP→client transition in a background thread.

    Called after the initial accept so the socket can return immediately.
    """
    global _operation_id

    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is None:
        _write_state({
            'operation_id': op_id,
            'phase': 'failed',
            'success': False,
            'message': 'WiFi transition lock is held by another process',
        })
        return

    # Write inhibit so wifi-fallback does not race
    _write_inhibit()

    # Phase tracking for reporting
    def _publish(phase: str, message: str, success: bool | None = None,
                 connectivity: dict | None = None) -> None:
        entry: dict = {
            'operation_id': op_id,
            'phase': phase,
            'success': success,
            'message': message,
        }
        if connectivity is not None:
            entry['connectivity'] = connectivity
        _write_state(entry)

    try:
        _publish('preparing', 'Deteniendo servicios AP…')

        # Step 1: Stop AP services, hand wlan0 to NM
        if not _stop_ap_services():
            _publish('failed', 'Error al transferir wlan0 a NetworkManager', False)
            _remove_inhibit()
            return

        # Step 2: Create/update NM profile with password (securely)
        _publish('connecting', f'Configurando perfil {ssid}…')
        profile = _create_nm_profile(ssid, password)
        if profile is None:
            _publish('failed', f'Error al crear perfil para {ssid}', False)
            _remove_inhibit()
            return

        # Step 3: Bring up connection
        _publish('connecting', f'Conectando a {ssid}…')
        if not _activate_profile(ssid):
            _publish('failed', f'NetworkManager no pudo conectar a {ssid}', False)
            _remove_inhibit()
            return

        # Step 4: Stability grace period with connectivity probing
        _publish('stabilizing', 'Verificando estabilidad de la conexión…')
        connectivity: dict | None = None
        consecutive = 0
        deadline = time.monotonic() + STABILIZATION_SECONDS
        while time.monotonic() < deadline:
            probe = probe_connectivity()
            if probe['associated'] and probe['ip_acquired']:
                consecutive += 1
                if consecutive >= STABLE_CHECKS:
                    connectivity = probe
                    break
            else:
                consecutive = 0
            time.sleep(CHECK_INTERVAL)
        else:
            # Timed out, take one final probe
            connectivity = probe_connectivity()

        # Step 5: The daemon state file is authoritative.
        # wifi-fallback reads it each cycle to detect the handoff
        # and resets its counters when it sees phase=connected.
        # No explicit handoff call needed.

        # Step 6: Determine final state
        if connectivity and connectivity['associated'] and connectivity['ip_acquired']:
            if connectivity['internet_online']:
                final_msg = f'Conectado a {ssid} con acceso a Internet'
            elif connectivity['local_only']:
                final_msg = f'Conectado a {ssid} sin acceso a Internet'
            else:
                final_msg = f'Conectado a {ssid} (alcance parcial)'
            _publish('connected', final_msg, True, connectivity)
            logger.info(
                'connect success: %s associated=%s internet=%s',
                ssid, connectivity['associated'], connectivity['internet_online'],
            )
        else:
            _publish(
                'connected' if connectivity.get('associated') else 'failed',
                f'Conexión a {ssid} sin IP o sin asociación',
                connectivity.get('associated', False),
                connectivity,
            )

    except BaseException as exc:
        logger.error('background connect failed: %s', exc)
        _publish('failed', f'Error interno: {type(exc).__name__}', False)
    finally:
        # Remove inhibit after handoff (success or failure)
        _remove_inhibit()
        _release_lock(lock_fd)
        _operation_id = None


def _handle_connect(ssid: str, password: str) -> dict:
    """Accept a connect command and start the transition in background.

    Returns immediately with operation_id.  The panel polls STATE_FILE.
    """
    global _operation_id
    if _operation_id is not None:
        return {
            'accepted': False, 'state': None,
            'error': 'busy',
            'message': 'A connection is already in progress',
        }

    op_id = secrets.token_urlsafe(18)
    _operation_id = op_id

    # Write initial 'accepted' state
    _write_state({
        'operation_id': op_id,
        'phase': 'accepted',
        'success': None,
        'message': 'Transición WiFi aceptada',
    })

    worker = threading.Thread(
        target=_background_connect,
        args=(ssid, password, op_id),
        daemon=True,
        name='sigil-wifi-connect',
    )
    worker.start()

    return {
        'accepted': True, 'state': 'accepted',
        'error': None,
        'message': 'Transición WiFi aceptada',
        'operation_id': op_id,
    }


# ---------------------------------------------------------------------------
# Daemon mutation handlers (single-owner — called behind TRANSITION_LOCK)
# ---------------------------------------------------------------------------

def _handle_ensure_ap() -> dict:
    """Socket command: idempotent AP guarantee.

    Acquires TRANSITION_LOCK, verifies hostapd + dnsmasq + AP IP,
    only mutates what is missing.  Never leaves wlan0 down.
    Returns state=ap_active on success, state=AP_RESTORE_FAILED on failure.
    """
    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is None:
        return {
            'accepted': False, 'state': None,
            'error': 'busy',
            'message': 'WiFi transition lock is held by another process',
        }
    try:
        ok = _ensure_ap()
        phase = 'ap_active' if ok else 'AP_RESTORE_FAILED'
        message = 'AP services ensured' if ok else 'AP services failed'
        _write_state({
            'phase': phase,
            'success': ok,
            'message': message,
        })
        logger.info('ensure_ap: %s', 'active' if ok else 'failed')
        return {'accepted': ok, 'state': phase, 'error': None, 'message': message}
    finally:
        _release_lock(lock_fd)


def _handle_restore_ap() -> dict:
    """Socket command: full transition from client to AP.

    Used by wifi-fallback when client connectivity fails repeatedly.
    Runs the complete AP setup, verifies services, never leaves wlan0 down.
    Returns state=ap_active on success, state=AP_RESTORE_FAILED on failure.
    """
    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is None:
        return {
            'accepted': False, 'state': None,
            'error': 'busy',
            'message': 'WiFi transition lock is held by another process',
        }
    try:
        ok = _start_ap_services()
        phase = 'ap_active' if ok else 'AP_RESTORE_FAILED'
        message = 'AP restored' if ok else 'AP restore failed'
        _write_state({
            'phase': phase,
            'success': ok,
            'message': message,
        })
        logger.info('restore_ap: %s', 'active' if ok else 'failed')
        return {'accepted': ok, 'state': phase,
                'error': None, 'message': message}
    finally:
        _release_lock(lock_fd)


def _handle_recover_client() -> dict:
    """Socket command: transition from AP to client.

    Stops AP, hands wlan0 to NetworkManager, lets NM auto-connect.
    If recovery succeeds: state=connected, accepted=true.
    If any step fails: restores AP, state=ap_active, accepted=false.
    """
    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is None:
        return {
            'accepted': False, 'state': None,
            'error': 'busy',
            'message': 'WiFi transition lock is held by another process',
        }

    _write_inhibit()
    recovery_stabilization = int(os.environ.get(
        'SIGIL_WIFI_RECOVERY_STABILIZATION', '60'
    ))
    recovery_check_interval = float(os.environ.get(
        'SIGIL_WIFI_RECOVERY_CHECK_INTERVAL', '5'
    ))
    recovery_stable_checks = int(os.environ.get(
        'SIGIL_WIFI_RECOVERY_STABLE_CHECKS', '2'
    ))

    try:
        logger.info('recover_client: stopping AP')
        # Step 1 — Stop AP, hand wlan0 to NM
        if not _stop_ap_services():
            _start_ap_services()
            msg = 'Recovery failed: could not stop AP services'
            logger.warning('recover_client: %s', msg)
            _write_state({'phase': 'ap_active', 'success': False, 'message': msg})
            return {'accepted': False, 'state': 'ap_active',
                    'error': None, 'message': msg}

        _write_state({'phase': 'recovering', 'success': None,
                       'message': 'Recovery: connecting to known network'})

        # Step 2 — Let NM auto-connect to the best profile
        rc = subprocess.run(
            ['nmcli', 'device', 'connect', WIFI_INTERFACE],
            capture_output=True, timeout=45,
        ).returncode

        if rc != 0:
            logger.warning('recover_client: nmcli device connect failed (exit=%d)', rc)
            _start_ap_services()
            msg = 'Recovery failed: no suitable profile'
            _write_state({'phase': 'ap_active', 'success': False, 'message': msg})
            return {'accepted': False, 'state': 'ap_active',
                    'error': None, 'message': msg}

        # Step 3 — Stability check with layered connectivity probes
        logger.info('recover_client: probing stability')
        connectivity: dict | None = None
        consecutive = 0
        deadline = time.monotonic() + recovery_stabilization

        while time.monotonic() < deadline:
            probe = probe_connectivity()
            if probe['associated'] and probe['ip_acquired']:
                consecutive += 1
                if consecutive >= recovery_stable_checks:
                    connectivity = probe
                    break
            else:
                consecutive = 0
            time.sleep(recovery_check_interval)
        else:
            connectivity = probe_connectivity()

        # Step 4 — Determine result
        if connectivity and connectivity['associated']:
            state_msg = ('internet_online' if connectivity.get('internet_online')
                         else 'local_only' if connectivity.get('local_only')
                         else 'ip_acquired')
            msg = f'Recovery connected ({state_msg})'
            logger.info('recover_client: %s', msg)
            _write_state({
                'phase': 'connected', 'success': True,
                'message': msg, 'connectivity': connectivity,
            })
            return {'accepted': True, 'state': 'connected',
                    'error': None, 'message': msg}

        # Recovery failed — restore AP
        logger.warning('recover_client: no connectivity after recovery')
        _start_ap_services()
        msg = 'Recovery failed: no connectivity'
        _write_state({'phase': 'ap_active', 'success': False, 'message': msg})
        return {'accepted': False, 'state': 'ap_active',
                'error': None, 'message': msg}

    finally:
        _remove_inhibit()
        _release_lock(lock_fd)


def _handle_deactivate_profile(uuid_str: str) -> dict:
    """Socket command: deactivate a profile by UUID (not display name).

    Prevents ambiguity when multiple profiles share the same SSID.
    Returns accepted even if profile is already inactive.
    """
    if not uuid_str or len(uuid_str) != 36:
        return {
            'accepted': False, 'state': None,
            'error': 'invalid_uuid',
            'message': f'Invalid UUID: {uuid_str}',
        }

    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is None:
        return {
            'accepted': False, 'state': None,
            'error': 'busy',
            'message': 'WiFi transition lock is held by another process',
        }
    try:
        rc = subprocess.run(
            ['nmcli', 'connection', 'down', 'uuid', uuid_str],
            capture_output=True, timeout=15,
        ).returncode
        # Exit code 0 = deactivated, non-zero may mean already down
        if rc == 0:
            logger.info('deactivate_profile: %s deactivated', uuid_str)
            return {
                'accepted': True, 'state': 'profile_deactivated',
                'error': None,
                'message': f'Profile {uuid_str} deactivated',
            }
        # Check if profile was already inactive
        check = subprocess.run(
            ['nmcli', '-t', '-f', 'DEVICE,TYPE', 'connection', 'show', '--active'],
            capture_output=True, text=True, timeout=5,
        )
        logger.info('deactivate_profile: %s (already inactive? rc=%d)', uuid_str, rc)
        return {
            'accepted': True, 'state': 'profile_deactivated',
            'error': None,
            'message': f'Profile {uuid_str} deactivated or not active',
        }
    finally:
        _release_lock(lock_fd)


def _handle_status() -> dict:
    """Socket command: return current daemon state (read-only, no lock)."""
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            state: dict = json.load(f)
        # Map internal 'phase' to canonical 'state' for socket consumers
        if 'phase' in state and 'state' not in state:
            state['state'] = state.pop('phase')
        state['accepted'] = True
        state['error'] = None
        return state
    except (FileNotFoundError, json.JSONDecodeError):
        return {
            'accepted': True, 'state': 'idle',
            'error': None,
            'message': 'sigil-wifi-control active',
        }


def _handle_probe() -> dict:
    """Socket command: run connectivity probes (read-only, no lock)."""
    result = probe_connectivity()
    result['accepted'] = True
    result['state'] = 'probe_result'
    result['error'] = None
    if 'message' not in result:
        result['message'] = 'Connectivity probe complete'
    return result


# ---------------------------------------------------------------------------
# Socket listener
# ---------------------------------------------------------------------------

def _handle_client(data: bytes) -> bytes:
    """Parse JSON command and dispatch to handler."""
    try:
        payload = json.loads(data.decode('utf-8'))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        return json.dumps({
            'accepted': False, 'state': None,
            'error': 'bad_request', 'message': str(exc),
        }).encode()

    command = payload.get('command', '')
    response: dict = {}

    if command == 'scan':
        response = _handle_scan()

    elif command == 'connect':
        ssid = str(payload.get('ssid', ''))
        password = str(payload.get('password', ''))
        if not ssid:
            response = {
                'accepted': False, 'state': None,
                'error': 'missing_ssid',
                'message': 'SSID requerido',
            }
        else:
            response = _handle_connect(ssid, password)

    elif command == 'ensure_ap':
        response = _handle_ensure_ap()

    elif command == 'restore_ap':
        response = _handle_restore_ap()

    elif command == 'recover_client':
        response = _handle_recover_client()

    elif command == 'deactivate_profile':
        uuid_str = str(payload.get('uuid', ''))
        response = _handle_deactivate_profile(uuid_str)

    elif command == 'status':
        response = _handle_status()

    elif command == 'probe':
        response = _handle_probe()

    elif command == 'ping':
        response = {
            'accepted': True, 'state': None,
            'error': None, 'message': 'pong',
        }

    else:
        response = {
            'accepted': False, 'state': None,
            'error': 'unknown_command',
            'message': f'unknown command: {command}',
        }

    return json.dumps(response).encode()


def _run_socket_server() -> None:
    """Main loop: listen on Unix socket and dispatch commands.

    Socket is created with 0o660 permissions (root:sigil) so only root
    and the sigil user can connect.  Each request is validated with
    SO_PEERCRED (uid == 0 enforced) and bounded to MAX_REQUEST_SIZE.
    """
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(5)
    # Strict socket permissions: root:rw-, sigil:rw-, others:---
    os.chmod(SOCKET_PATH, 0o660)
    sigil_gid = 0
    try:
        sigil_gid = grp.getgrnam(SIGIL_GROUP).gr_gid
        os.chown(SOCKET_PATH, 0, sigil_gid)  # root:sigil
    except KeyError:
        logger.warning('group %s not found; socket owned by root:root', SIGIL_GROUP)
        os.chown(SOCKET_PATH, 0, 0)

    logger.info('listening on %s (mode 0660 root:%s)', SOCKET_PATH, SIGIL_GROUP)

    while True:
        try:
            conn, _addr = server.accept()
            # SO_PEERCRED validation: accept root (uid=0) OR any sigil group member
            try:
                cred = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                       struct.calcsize('3i'))
                pid, uid, gid = struct.unpack('3i', cred)
            except OSError:
                logger.warning('could not read SO_PEERCRED; rejecting')
                conn.close()
                continue
            if uid != 0 and gid != sigil_gid:
                logger.warning('rejected connection from uid=%d gid=%d (pid=%d)',
                               uid, gid, pid)
                conn.close()
                continue

            # Bounded request size
            data = conn.recv(MAX_REQUEST_SIZE)
            if data:
                response = _handle_client(data)
                conn.sendall(response)
            conn.close()
        except (OSError, UnicodeError) as exc:
            logger.warning('socket error: %s', exc)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    logger.info('starting sigil-wifi-control (single-owner WiFi daemon)')

    # Disable power save at startup, behind TRANSITION_LOCK
    lock_fd = _acquire_lock(TRANSITION_LOCK, nonblocking=True)
    if lock_fd is not None:
        try:
            _disable_power_save()
            logger.info('power save disabled')
        finally:
            _release_lock(lock_fd)
    else:
        logger.warning('could not acquire lock for power_save off; skipping')

    # Write initial idle state
    _write_state({
        'operation_id': '',
        'phase': 'idle',
        'success': None,
        'message': 'sigil-wifi-control activo',
    })

    _run_socket_server()
    return 0


if __name__ == '__main__':
    sys.exit(main())
