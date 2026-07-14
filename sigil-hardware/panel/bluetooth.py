"""
bluetooth.py — Lógica completa de gestión Bluetooth para el panel Sigil.
Maneja escaneo SSE, emparejamiento, conexión exclusiva y perfil A2DP.
"""
import subprocess
import re
import os
import time
import select
import json
import logging
import pwd

from config import (
    PREFERRED_BT_FILE, BT_SWITCH_LOCK,
    scan_lock, pair_lock
)

logger = logging.getLogger(__name__)

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

def save_preferred_device(mac: str) -> None:
    try:
        with open(PREFERRED_BT_FILE, 'w') as f:
            f.write(mac)
    except Exception as e:
        logger.error(f'Error guardando preferido: {e}')


def get_preferred_device() -> str | None:
    try:
        if os.path.exists(PREFERRED_BT_FILE):
            with open(PREFERRED_BT_FILE, 'r') as f:
                return f.read().strip() or None
    except Exception:
        pass
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


# ── PulseAudio A2DP ───────────────────────────────────────────────────────────

def _sigil_pactl_command(*args: str) -> list[str]:
    """Build a pactl command bound to the sigil user's PulseAudio session."""
    try:
        account = pwd.getpwnam('sigil')
        sigil_uid = account.pw_uid
        sigil_home = account.pw_dir
    except KeyError:
        sigil_uid = 1000
        sigil_home = '/home/sigil'

    runtime_dir = f'/run/user/{sigil_uid}'
    return [
        'sudo', '-H', '-u', 'sigil', '--',
        'env',
        f'HOME={sigil_home}',
        f'XDG_RUNTIME_DIR={runtime_dir}',
        f'PULSE_SERVER=unix:{runtime_dir}/pulse/native',
        f'PULSE_RUNTIME_PATH={runtime_dir}/pulse',
        'pactl', *args,
    ]


def set_a2dp_profile() -> None:
    """Aplica el perfil A2DP al sink Bluetooth activo."""
    try:
        result = subprocess.run(
            _sigil_pactl_command('list', 'cards', 'short'),
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            if 'bluez_card' in line:
                card = line.split()[1]
                subprocess.run(
                    _sigil_pactl_command(
                        'set-card-profile', card, 'a2dp_sink'
                    ),
                    capture_output=True, timeout=5
                )
                logger.info(f'Perfil A2DP aplicado a {card}')
                break
    except Exception as e:
        logger.error(f'Error A2DP: {e}')


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

    yield 'data: {"done": true}\n\n'


# ── Acciones de dispositivo ───────────────────────────────────────────────────

def _disconnect_all_except(keep_mac: str | None = None) -> None:
    """
    Desconecta y bloquea todos los dispositivos BT conectados excepto keep_mac.
    Espera confirmación real de que desconectaron.
    """
    try:
        result = subprocess.run(
            ['bluetoothctl', 'devices', 'Connected'],
            capture_output=True, text=True, timeout=5
        )
        to_disconnect = []
        for line in strip_ansi(result.stdout).splitlines():
            m = re.search(r'Device ([0-9A-F:]{17})', line, re.IGNORECASE)
            if m and m.group(1) != keep_mac:
                to_disconnect.append(m.group(1))

        for dev in to_disconnect:
            logger.info(f'Bloqueando y desconectando: {dev}')
            subprocess.run(['bluetoothctl', 'block',      dev], timeout=3, capture_output=True)
            subprocess.run(['bluetoothctl', 'untrust',    dev], timeout=3, capture_output=True)
            subprocess.run(['bluetoothctl', 'disconnect', dev], timeout=6, capture_output=True)
            # Esperar hasta 4 s a que realmente desconecte
            for _ in range(8):
                time.sleep(0.5)
                chk = subprocess.run(['bluetoothctl', 'info', dev], capture_output=True, text=True, timeout=3)
                if 'Connected: no' in strip_ansi(chk.stdout):
                    logger.info(f'Confirmado desconectado: {dev}')
                    break
            else:
                logger.warning(f'No confirmó desconexión de {dev}, continuando')

        if to_disconnect:
            time.sleep(1)
    except Exception as e:
        logger.warning(f'Error _disconnect_all_except: {e}')


def _wait_scan_released(timeout_s: float = 8.0) -> None:
    """
    Espera a que el lock del scan SSE se libere antes de intentar conectar.
    Si bluetoothctl está ocupado con un scan activo, la conexión fallará.
    """
    deadline = time.time() + timeout_s
    while scan_lock.locked() and time.time() < deadline:
        logger.info('Scan SSE activo — esperando para conectar...')
        time.sleep(1)


def pair_device(mac: str) -> tuple[bool, str]:
    """Empareja, confía y conecta una bocina nueva desde el panel web."""
    with pair_lock:
        try:
            open(BT_SWITCH_LOCK, 'w').close()
            subprocess.run(['sudo', 'systemctl', 'stop', 'bt-connect'], timeout=5)
            _wait_scan_released(timeout_s=8)

            old_mac = get_preferred_device()
            if old_mac and old_mac != mac:
                subprocess.run(['bluetoothctl', 'block',      old_mac], timeout=3, capture_output=True)
                subprocess.run(['bluetoothctl', 'untrust',    old_mac], timeout=3, capture_output=True)
                subprocess.run(['bluetoothctl', 'disconnect', old_mac], timeout=5, capture_output=True)
                time.sleep(2)

            subprocess.run(['bluetoothctl', 'power', 'on'], timeout=3, capture_output=True)
            time.sleep(1)
            subprocess.run(['bluetoothctl', 'pair',    mac], timeout=15, capture_output=True)
            subprocess.run(['bluetoothctl', 'unblock', mac], timeout=3,  capture_output=True)
            subprocess.run(['bluetoothctl', 'trust',   mac], timeout=3,  capture_output=True)
            save_preferred_device(mac)

            subprocess.run(['bluetoothctl', 'connect', mac], timeout=12, capture_output=True)
            time.sleep(4)

            if is_device_connected(mac):
                set_a2dp_profile()
                time.sleep(2)
                subprocess.run(['sudo', 'systemctl', 'restart', 'bt-connect'], timeout=5)
                return True, 'Bocina emparejada y conectada exitosamente'
            else:
                # Segundo intento de conexión
                logger.info(f'Primer intento de conexión falló para {mac}, reintentando...')
                subprocess.run(['bluetoothctl', 'connect', mac], timeout=12, capture_output=True)
                time.sleep(5)
                if is_device_connected(mac):
                    set_a2dp_profile()
                    time.sleep(2)
                    subprocess.run(['sudo', 'systemctl', 'restart', 'bt-connect'], timeout=5)
                    return True, 'Bocina emparejada y conectada exitosamente'
                subprocess.run(['sudo', 'systemctl', 'restart', 'bt-connect'], timeout=5)
                return False, 'Se emparejó pero no conectó. Asegúrate de que la bocina esté encendida e intenta conectar manualmente.'

        except subprocess.TimeoutExpired:
            subprocess.run(['sudo', 'systemctl', 'restart', 'bt-connect'], timeout=5)
            return False, 'Timeout — asegúrate de que la bocina esté en modo emparejamiento'
        except Exception as e:
            subprocess.run(['sudo', 'systemctl', 'restart', 'bt-connect'], timeout=5)
            logger.error(f'Error pair_device: {e}')
            return False, str(e)
        finally:
            try:
                os.remove(BT_SWITCH_LOCK)
            except Exception:
                pass


def connect_device(mac: str) -> tuple[bool, str]:
    """Conecta a una bocina ya emparejada (modo exclusivo)."""
    try:
        open(BT_SWITCH_LOCK, 'w').close()
        subprocess.run(['sudo', 'systemctl', 'stop', 'bt-connect'], timeout=5)

        # Esperar a que el scan SSE libere bluetoothctl antes de conectar
        _wait_scan_released(timeout_s=8)

        save_preferred_device(mac)
        subprocess.run(['bluetoothctl', 'unblock', mac], timeout=3, capture_output=True)
        subprocess.run(['bluetoothctl', 'trust',   mac], timeout=5, capture_output=True)
        _disconnect_all_except(keep_mac=mac)
        time.sleep(1)

        # Primer intento
        result = subprocess.run(['bluetoothctl', 'connect', mac], timeout=12, capture_output=True, text=True)
        time.sleep(4)

        if is_device_connected(mac):
            set_a2dp_profile()
            time.sleep(2)
            subprocess.run(['sudo', 'systemctl', 'reset-failed', 'bt-connect', 'radio-stream'], timeout=5)
            subprocess.run(['sudo', 'systemctl', 'start', 'bt-connect'], timeout=5)
            return True, 'Conectado exitosamente'

        # Segundo intento (la bocina puede necesitar más tiempo para responder)
        logger.info(f'Primer intento de conexión falló para {mac}, reintentando...')
        subprocess.run(['bluetoothctl', 'connect', mac], timeout=12, capture_output=True, text=True)
        time.sleep(5)

        if is_device_connected(mac):
            set_a2dp_profile()
            time.sleep(2)
            subprocess.run(['sudo', 'systemctl', 'reset-failed', 'bt-connect', 'radio-stream'], timeout=5)
            subprocess.run(['sudo', 'systemctl', 'start', 'bt-connect'], timeout=5)
            return True, 'Conectado exitosamente'

        connect_output = strip_ansi(result.stdout + result.stderr)
        logger.warning(f'connect_device falló para {mac}: {connect_output}')
        subprocess.run(['sudo', 'systemctl', 'reset-failed', 'bt-connect'], timeout=5)
        subprocess.run(['sudo', 'systemctl', 'start',        'bt-connect'], timeout=5)
        return False, 'No se pudo conectar. Verifica que la bocina esté encendida y cerca.'

    except subprocess.TimeoutExpired:
        subprocess.run(['sudo', 'systemctl', 'reset-failed', 'bt-connect'], timeout=5)
        subprocess.run(['sudo', 'systemctl', 'start',        'bt-connect'], timeout=5)
        return False, 'Timeout — la bocina no respondió a tiempo'
    except Exception as e:
        subprocess.run(['sudo', 'systemctl', 'reset-failed', 'bt-connect'], timeout=5)
        subprocess.run(['sudo', 'systemctl', 'start',        'bt-connect'], timeout=5)
        return False, str(e)
    finally:
        try:
            os.remove(BT_SWITCH_LOCK)
        except Exception:
            pass


def remove_device(mac: str) -> tuple[bool, str]:
    """Elimina el emparejamiento de una bocina."""
    try:
        subprocess.run(['bluetoothctl', 'disconnect', mac], timeout=5, capture_output=True)
        subprocess.run(['bluetoothctl', 'remove',     mac], timeout=5, capture_output=True)
        if get_preferred_device() == mac:
            try:
                os.remove(PREFERRED_BT_FILE)
            except Exception:
                pass
        return True, 'Bocina eliminada'
    except Exception as e:
        return False, str(e)
