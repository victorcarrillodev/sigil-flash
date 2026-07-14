#!/usr/bin/env python3
"""
app.py — Punto de entrada del panel web de Sigil.
Solo contiene la inicialización de Flask, registro de rutas y el portal cautivo.
La lógica de negocio vive en bluetooth.py y wifi.py.

SECRETS: SIGIL_SECRET_KEY desde /etc/sigil/panel.env
         Sin fallbacks hardcodeados.
         Sin valores secretos en código fuente.
"""
import os
import json
import logging
import threading
import subprocess
import urllib.request
import urllib.error

from flask import Flask, render_template, jsonify, request, redirect, Response

import config
from device_identity import load_identity
from bluetooth import (
    get_known_devices, get_preferred_device, save_preferred_device,
    get_connected_devices, is_device_connected,
    is_valid_mac, _is_mac, _get_real_name,
    stream_bluetooth_scan, pair_device, connect_device, remove_device,
)
from wifi import scan_wifi_networks, connect_wifi, get_current_wifi


# ── Carga segura de secrets desde env file ────────────────────────────────

def _load_env(path: str) -> dict:
    """Carga variables de entorno desde archivo key=value.
    No es un parser completo de shell — solo key=value simple.
    Sin dependencia de python-dotenv.
    """
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, _, val = line.partition("=")
                    env[key.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return env


# Cargar env file; si falta SIGIL_SECRET_KEY, falla con error claro
_env = _load_env("/etc/sigil/panel.env")
_secret_key = _env.get("SIGIL_SECRET_KEY") or os.environ.get("SIGIL_SECRET_KEY")
if not _secret_key:
    raise RuntimeError(
        "SIGIL_SECRET_KEY no definido. "
        "Crear /etc/sigil/panel.env con SIGIL_SECRET_KEY=<valor>"
    )


# ── Inicialización ─────────────────────────────────────────────────────────────
app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = _secret_key
logging.basicConfig(level=logging.INFO)

# Device ID (para futuras integraciones), resolved by the canonical helper.
_DEVICE_ID = load_identity()["device_id"]


# ── Portal Cautivo ─────────────────────────────────────────────────────────────
# iOS, Android y Windows prueban estas URLs al conectarse a un AP.
# Si no responden como internet real, abren el portal cautivo automáticamente.
_CAPTIVE_URLS = [
    "/generate_204",
    "/gen_204",
    "/hotspot-detect.html",
    "/library/test/success.html",
    "/ncsi.txt",
    "/connecttest.txt",
    "/redirect",
    "/canonical.html",
]


def _captive_redirect():
    return redirect("/", code=302)


for _url in _CAPTIVE_URLS:
    app.add_url_rule(
        _url,
        f"captive_{_url.replace('/', '_').replace('.', '_')}",
        _captive_redirect,
    )


# ── API: Estado del sistema (solo uptime) ──────────────────────────────────

@app.route("/api/system-status")
def system_status():
    """Devuelve estado del sistema. Por ahora solo uptime."""
    uptime_seconds = 0
    try:
        with open("/proc/uptime") as f:
            uptime_seconds = float(f.read().split()[0])
    except Exception:
        pass
    return jsonify({
        "uptime_seconds": int(uptime_seconds),
    })


# ── Rutas principales ──────────────────────────────────────────────────────────

@app.route("/")
def index():
    preferred_bt = get_preferred_device()
    connected_macs = get_connected_devices()
    bt_devices = []
    for d in get_known_devices():
        d["preferred"] = d["mac"] == preferred_bt
        d["connected"] = d["mac"] in connected_macs
        if _is_mac(d["name"]):
            real = _get_real_name(d["mac"])
            d["name"] = real if real else f'Altavoz {d["mac"][-5:].replace(":", "")}'
        bt_devices.append(d)

    return render_template(
        "index.html",
        bt_devices=bt_devices,
        wifi_networks=[],
        current_wifi=get_current_wifi(),
        preferred_bt=preferred_bt,
    )


# ── Rutas Bluetooth ────────────────────────────────────────────────────────────

@app.route("/scan/stream")
def scan_stream():
    """SSE: emite dispositivos BT en tiempo real conforme se descubren."""
    preferred_bt = get_preferred_device()
    known_macs = {d["mac"] for d in get_known_devices()}
    return Response(
        stream_bluetooth_scan(preferred_bt, known_macs),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/scan/known")
def scan_known():
    """Devuelve dispositivos ya emparejados para la carga inicial (JSON)."""
    preferred_bt = get_preferred_device()
    connected_macs = get_connected_devices()
    devices = get_known_devices()
    for d in devices:
        if _is_mac(d["name"]):
            real = _get_real_name(d["mac"])
            if real:
                d["name"] = real
        d["preferred"] = d["mac"] == preferred_bt
        d["connected"] = d["mac"] in connected_macs
        d["known"] = True
    return jsonify({"devices": devices})


@app.route("/bt/status")
def bt_status():
    """Devuelve el estado REAL de conexión de todos los dispositivos conocidos."""
    preferred_bt = get_preferred_device()
    connected_macs = get_connected_devices()
    devices = get_known_devices()
    result = []
    for d in devices:
        if _is_mac(d["name"]):
            real = _get_real_name(d["mac"])
            if real:
                d["name"] = real
        result.append({
            "mac": d["mac"],
            "name": d["name"],
            "preferred": d["mac"] == preferred_bt,
            "connected": d["mac"] in connected_macs,
            "known": True,
        })
    return jsonify({
        "devices": result,
        "connected_macs": list(connected_macs),
    })


@app.route("/pair", methods=["POST"])
def pair():
    mac = request.form.get("mac", "")
    if not is_valid_mac(mac):
        return jsonify({"success": False, "message": "MAC inválida"}), 400
    subprocess.run(["bluetoothctl", "scan", "off"], timeout=5)
    success, msg = pair_device(mac)
    return jsonify({"success": success, "message": msg})


@app.route("/connect/<mac>")
def api_connect(mac):
    subprocess.run(["bluetoothctl", "scan", "off"], timeout=5)
    success, msg = connect_device(mac)
    return jsonify({"success": success, "message": msg})


@app.route("/disconnect_active")
def api_disconnect_active():
    mac = get_preferred_device()
    if mac:
        subprocess.run(["bluetoothctl", "disconnect", mac], timeout=5)
    try:
        os.remove(config.PREFERRED_BT_FILE)
    except Exception:
        pass
    subprocess.run(
        ["sudo", "systemctl", "reset-failed", "bt-connect", "radio-stream"], timeout=5
    )
    subprocess.run(["sudo", "systemctl", "start", "bt-connect"], timeout=5)
    subprocess.run(["sudo", "systemctl", "stop", "radio-stream"], timeout=5)
    return jsonify({"success": True, "message": "Bocina desconectada y deseleccionada"})


@app.route("/remove/<mac>")
def api_remove(mac):
    if not is_valid_mac(mac):
        return jsonify({"success": False, "message": "MAC inválida"}), 400
    success, msg = remove_device(mac)
    return jsonify({"success": success, "message": msg})


# ── Rutas WiFi ─────────────────────────────────────────────────────────────────

@app.route("/wifi/scan")
def wifi_scan():
    return jsonify({"networks": scan_wifi_networks()})


@app.route("/wifi/connect", methods=["POST"])
def wifi_connect_route():
    data = request.get_json()
    if not data or "ssid" not in data:
        return jsonify({"success": False, "message": "SSID requerido"}), 400
    ssid = data.get("ssid", "").strip()
    password = data.get("password", "").strip()
    if not ssid:
        return jsonify({"success": False, "message": "SSID vacío"}), 400

    if config.wifi_status["running"]:
        return jsonify({"success": False, "message": "Ya hay una conexión en progreso, espera…"}), 429

    config.wifi_status.update({
        "running": True,
        "success": None,
        "message": f"Conectando a {ssid}…",
    })

    def _do_wifi():
        try:
            success, msg = connect_wifi(ssid, password)
            config.wifi_status.update({"success": success, "message": msg})
        except Exception as e:
            app.logger.error(f"[WiFi] _do_wifi exception: {e}")
            config.wifi_status.update({"success": False, "message": "Error interno crítico"})
        finally:
            config.wifi_status["running"] = False

    threading.Thread(target=_do_wifi, daemon=True).start()
    return jsonify({"success": True, "message": f"Conectando a {ssid}… (espera 20-40 segundos)"})


@app.route("/wifi/status")
def wifi_status():
    return jsonify(config.wifi_status)


# ── Rutas de Música ────────────────────────────────────────────────────────────

@app.route("/music/status")
def music_status():
    """Devuelve el estado de reproducción actual."""
    track_name = "Sin reproducción"
    track_url = ""
    is_playing = False

    try:
        with open("/home/sigil/now_playing.txt", "r") as f:
            raw = f.read().strip()
            if raw:
                track_url = raw
                track_name = raw.split("/")[-1].split("?")[0]
                track_name = track_name.replace("%20", " ")
                if track_name.endswith(".mp3"):
                    track_name = track_name[:-4]
                is_playing = True
    except FileNotFoundError:
        pass
    except Exception as e:
        app.logger.warning(f"[Music] Error leyendo now_playing: {e}")

    preferred_mac = get_preferred_device()
    speaker_connected = is_device_connected(preferred_mac) if preferred_mac else False

    return jsonify({
        "is_playing": is_playing,
        "track_name": track_name,
        "track_url": track_url,
        "speaker_mac": preferred_mac or "",
        "speaker_connected": speaker_connected,
    })


@app.route("/music/next", methods=["POST"])
def music_next():
    """Salta a la siguiente pista matando mpg123."""
    try:
        subprocess.run(["pkill", "-9", "-f", "mpg123"], timeout=3)
        return jsonify({"success": True, "message": "Saltando a la siguiente pista…"})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)}), 500


# ── Entrypoint ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=False)
