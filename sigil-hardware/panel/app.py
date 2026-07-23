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
import ipaddress
import secrets
import stat
import subprocess
import threading
import time
import urllib.request
import urllib.error
import urllib.parse
from datetime import timedelta

from flask import Flask, render_template, jsonify, request, redirect, Response, session, url_for

import config
from device_identity import load_identity
from bluetooth import (
    get_known_devices, get_preferred_device,
    is_device_connected,
    is_valid_mac,
    stream_bluetooth_scan, pair_device, connect_device, disconnect_device,
    remove_device,
)
from wifi import (
    WifiCredentialError,
    WifiScanBusy,
    connect_wifi,
    get_current_wifi,
    scan_wifi_networks,
    validate_wifi_credentials,
)
from panel_auth import panel_hash_is_provisioned, read_panel_pin_length, verify_panel_pin_hash


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
    # systemd reads the root-only EnvironmentFile and exports its values to the
    # unprivileged panel process. A direct read is therefore optional.
    except (FileNotFoundError, PermissionError):
        pass
    return env


# Cargar env file; si falta SIGIL_SECRET_KEY, falla con error claro
_env = _load_env("/etc/sigil/panel.env")
_secret_key = os.environ.get("SIGIL_SECRET_KEY") or _env.get("SIGIL_SECRET_KEY")
if not _secret_key:
    raise RuntimeError(
        "SIGIL_SECRET_KEY no definido. "
        "Crear /etc/sigil/panel.env con SIGIL_SECRET_KEY=<valor>"
    )


# ── Inicialización ─────────────────────────────────────────────────────────────
app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = _secret_key
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Strict",
    SESSION_COOKIE_SECURE=(
        (_env.get("SIGIL_PANEL_HTTPS") or os.environ.get("SIGIL_PANEL_HTTPS", "0")) == "1"
    ),
    PERMANENT_SESSION_LIFETIME=timedelta(minutes=30),
    MAX_CONTENT_LENGTH=4096,
)
logging.basicConfig(level=logging.INFO)


@app.after_request
def disable_panel_caching(response):
    """Captive browsers must not reuse HTML or CSRF state across sessions."""
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response

# Device ID (para futuras integraciones), resolved by the canonical helper.
_DEVICE_ID = load_identity()["device_id"]

_PLAYBACK_STATE_FILE = "/var/lib/sigil/playback_state.json"
_AUDIO_MODE_FILE = "/var/lib/sigil/audio_mode.json"
_LEGACY_NOW_PLAYING_FILE = "/home/sigil/now_playing.txt"
_MAX_RUNTIME_STATE_BYTES = 64 * 1024
_PANEL_PIN_HASH_FILE = os.environ.get(
    "SIGIL_PANEL_PIN_HASH", "/etc/sigil/secrets/panel-pin.hash"
)
_PANEL_PIN_LENGTH_FILE = os.environ.get(
    "SIGIL_PANEL_PIN_LENGTH", "/etc/sigil/secrets/panel-pin.length"
)
_SESSION_MAX_IDLE_SECONDS = 30 * 60
_AUTH_ATTEMPT_WINDOW_SECONDS = 15 * 60
_AUTH_MAX_DELAY_SECONDS = 60
_AUTH_MAX_CLIENTS = 256
_AUTH_FAILURES: dict[str, dict[str, float | int]] = {}
_AUTH_FAILURES_LOCK = threading.Lock()
_BASE_STARTUP_SERVICES = (
    "bluetooth.service",
    "bt-connect.service",
)
_PANEL_STARTUP_SERVICES = (
    "bluetooth-panel.service",
    "radio-fetcher.service",
    "audio-manager.service",
    "audio-player.service",
)
_MUTATING_ENDPOINTS = {
    "pair",
    "api_connect",
    "api_disconnect_active",
    "api_remove",
    "wifi_connect_route",
    "wifi_connect_commit_route",
    "music_next",
}

_WIFI_ACCEPT_TTL_SECONDS = 30
_WIFI_PENDING_LOCK = threading.Lock()
_WIFI_PENDING: dict[str, dict[str, object]] = {}


def _expire_pending_wifi(now: float | None = None) -> None:
    """Expire a prepared handoff that the browser never acknowledged."""
    current = time.monotonic() if now is None else now
    with _WIFI_PENDING_LOCK:
        expired = [
            operation_id
            for operation_id, operation in _WIFI_PENDING.items()
            if current - float(operation["accepted_at"]) >= _WIFI_ACCEPT_TTL_SECONDS
        ]
        for operation_id in expired:
            _WIFI_PENDING.pop(operation_id, None)
        if expired and not _WIFI_PENDING and config.wifi_status.get("phase") == "awaiting_commit":
            config.wifi_status.update({
                "running": False,
                "success": False,
                "phase": "expired",
                "message": "La conexión no fue confirmada por el navegador; vuelve a intentarlo",
            })


def _request_host_is_allowed() -> bool:
    host = (urllib.parse.urlsplit(f"//{request.host}").hostname or "").lower()
    if not host or any(character in host for character in "\r\n/\\"):
        return False
    configured = {
        value.strip().lower()
        for value in (
            _env.get("SIGIL_PANEL_ALLOWED_HOSTS")
            or os.environ.get("SIGIL_PANEL_ALLOWED_HOSTS", "")
        ).split(",")
        if value.strip()
    }
    hostname = os.uname().nodename.lower()
    if host in configured or host in {"localhost", hostname, f"{hostname}.local", "sigil.local"}:
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_private or address.is_link_local or address.is_loopback


def _csrf_token() -> str:
    token = session.get("csrf_token")
    if not isinstance(token, str) or len(token) < 32:
        token = secrets.token_urlsafe(32)
        session["csrf_token"] = token
    return token


def _csrf_is_valid(provided: object) -> bool:
    expected = session.get("csrf_token")
    return (
        isinstance(expected, str)
        and isinstance(provided, str)
        and secrets.compare_digest(expected, provided)
    )


def _request_origin_is_same_host() -> bool:
    source = request.headers.get("Origin") or request.headers.get("Referer")
    if not source:
        return True
    parsed = urllib.parse.urlsplit(source)
    return bool(parsed.netloc) and parsed.netloc.lower() == request.host.lower()


def _authentication_delay(remote: str) -> int:
    now = time.monotonic()
    with _AUTH_FAILURES_LOCK:
        state = _AUTH_FAILURES.get(remote)
        if not state or now - float(state["last_failure"]) > _AUTH_ATTEMPT_WINDOW_SECONDS:
            _AUTH_FAILURES.pop(remote, None)
            return 0
        return max(0, int(float(state["blocked_until"]) - now + 0.999))


def _record_authentication_failure(remote: str) -> int:
    now = time.monotonic()
    with _AUTH_FAILURES_LOCK:
        expired = [
            key
            for key, value in _AUTH_FAILURES.items()
            if now - float(value["last_failure"]) > _AUTH_ATTEMPT_WINDOW_SECONDS
        ]
        for key in expired:
            _AUTH_FAILURES.pop(key, None)
        if remote not in _AUTH_FAILURES and len(_AUTH_FAILURES) >= _AUTH_MAX_CLIENTS:
            oldest = min(
                _AUTH_FAILURES,
                key=lambda key: float(_AUTH_FAILURES[key]["last_failure"]),
            )
            _AUTH_FAILURES.pop(oldest, None)
        state = _AUTH_FAILURES.get(remote)
        if not state or now - float(state["last_failure"]) > _AUTH_ATTEMPT_WINDOW_SECONDS:
            failures = 1
        else:
            failures = int(state["failures"]) + 1
        delay = min(_AUTH_MAX_DELAY_SECONDS, 2 ** max(0, failures - 3))
        _AUTH_FAILURES[remote] = {
            "failures": failures,
            "last_failure": now,
            "blocked_until": now + delay,
        }
        return delay


@app.before_request
def enforce_panel_security():
    endpoint = request.endpoint or ""
    # Captive probes commonly preserve the public probe Host header. They may
    # only reach the fixed relative login redirect and never a control route.
    if endpoint.startswith("captive_"):
        return None
    if not _request_host_is_allowed():
        return jsonify({"success": False, "message": "Solicitud no permitida"}), 400

    if endpoint in {"static", "login", "logout", "startup", "startup_status"}:
        return None

    authenticated_at = session.get("authenticated_at")
    now = int(time.time())
    if not session.get("panel_authenticated") or not isinstance(authenticated_at, int):
        if request.path == "/":
            return redirect(url_for("startup"))
        return jsonify({"success": False, "message": "Autenticación requerida"}), 401
    if now - authenticated_at > _SESSION_MAX_IDLE_SECONDS:
        session.clear()
        if request.path == "/":
            return redirect(url_for("login"))
        return jsonify({"success": False, "message": "Sesión expirada"}), 401
    session["authenticated_at"] = now

    if endpoint in _MUTATING_ENDPOINTS:
        if not _request_origin_is_same_host() or not _csrf_is_valid(
            request.headers.get("X-Sigil-CSRF")
        ):
            return jsonify({"success": False, "message": "Solicitud no permitida"}), 403
    return None


def _read_bounded_json(path: str) -> dict | None:
    """Read a small, regular, non-symlink runtime JSON document."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = None
    try:
        fd = os.open(path, flags)
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_size > _MAX_RUNTIME_STATE_BYTES:
            return None
        raw = os.read(fd, _MAX_RUNTIME_STATE_BYTES + 1)
        if len(raw) > _MAX_RUNTIME_STATE_BYTES:
            return None
        document = json.loads(raw.decode("utf-8"))
        return document if isinstance(document, dict) else None
    except (FileNotFoundError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    finally:
        if fd is not None:
            os.close(fd)


def _read_legacy_now_playing() -> str:
    """Read legacy display metadata only; this file never proves playback."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = None
    try:
        fd = os.open(_LEGACY_NOW_PLAYING_FILE, flags)
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_size > 4096:
            return ""
        return os.read(fd, 4097).decode("utf-8").strip()[:4096]
    except (FileNotFoundError, OSError, UnicodeDecodeError):
        return ""
    finally:
        if fd is not None:
            os.close(fd)


def _public_track_value(value: object) -> str:
    """Return display-safe track metadata without hosts, queries, or fragments."""
    if not isinstance(value, str) or not value:
        return ""
    parsed = urllib.parse.urlsplit(value)
    path = parsed.path if parsed.scheme or parsed.netloc else value.split("?", 1)[0].split("#", 1)[0]
    return urllib.parse.unquote(path.rsplit("/", 1)[-1])[:512]


def _panel_hash_available() -> bool:
    return panel_hash_is_provisioned(_PANEL_PIN_HASH_FILE)


def _panel_pin_length() -> int:
    # Older images have only the Argon2id hash, from which PIN length cannot be
    # recovered. Keep their existing 12-digit UI until they are reprovisioned.
    return read_panel_pin_length(_PANEL_PIN_LENGTH_FILE) or 12


def _preferred_a2dp_is_ready() -> bool:
    """Require a usable Bluetooth route, not merely a BlueZ connection."""
    preferred = get_preferred_device()
    if not preferred or not is_device_connected(preferred):
        return False
    playback_state = _read_bounded_json(_PLAYBACK_STATE_FILE)
    output = playback_state.get("output") if playback_state else None
    if not isinstance(output, dict):
        return False
    if output.get("available") is not True or output.get("type") != "bluetooth":
        return False
    device = output.get("device")
    return device in (None, "", preferred)


def _services_active(services: tuple[str, ...]) -> bool:
    """Check a fixed allowlist of local system services with a hard timeout."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "--quiet", *services],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _startup_state() -> dict[str, bool]:
    """Return independent boot, audio-route, media and playback readiness states."""
    base_services_ready = _services_active(_BASE_STARTUP_SERVICES)
    panel_workers_ready = _services_active(_PANEL_STARTUP_SERVICES)
    panel_ready = base_services_ready and panel_workers_ready
    playback_state = _read_bounded_json(_PLAYBACK_STATE_FILE)
    output = playback_state.get("output") if playback_state else None
    output_available = isinstance(output, dict) and output.get("available") is True
    preferred = get_preferred_device()
    no_preferred_speaker = not preferred
    # The file is created only after an explicit successful connection. An
    # absent file distinguishes a first installation from a later deselection.
    preferred_file = getattr(config, "PREFERRED_BT_FILE", "/home/sigil/preferred_bt.txt")
    first_install = no_preferred_speaker and not os.path.exists(preferred_file)
    a2dp_ready = _preferred_a2dp_is_ready()
    media_ready = _services_active(("radio-fetcher.service",))
    playback_active = bool(
        panel_ready
        and output_available
        and playback_state
        and playback_state.get("playing") is True
    )
    return {
        "BASE_SERVICES_READY": base_services_ready,
        "PANEL_READY": panel_ready,
        "FIRST_INSTALL": first_install,
        "NO_PREFERRED_SPEAKER": no_preferred_speaker,
        "AUDIO_OUTPUT_WAITING": panel_ready and not output_available,
        "A2DP_READY": a2dp_ready,
        # A running fetcher has started its job; a download completion is not
        # required before exposing the pairing/login panel.
        "MEDIA_READY": media_ready,
        "PLAYBACK_ACTIVE": playback_active,
    }


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return render_template(
            "login.html",
            csrf_token=_csrf_token(),
            setup_locked=not _panel_hash_available(),
            pin_length=_panel_pin_length(),
            error="",
        )

    if not _csrf_is_valid(request.form.get("csrf_token")) or not _request_origin_is_same_host():
        return render_template(
            "login.html",
            csrf_token=_csrf_token(),
            setup_locked=not _panel_hash_available(),
            pin_length=_panel_pin_length(),
            error="No se pudo iniciar sesión.",
        ), 403

    if not _panel_hash_available():
        return render_template(
            "login.html",
            csrf_token=_csrf_token(),
            setup_locked=True,
            pin_length=_panel_pin_length(),
            error="El acceso local aún no está configurado.",
        ), 503

    remote = request.remote_addr or "local"
    delay = _authentication_delay(remote)
    if delay:
        response = render_template(
            "login.html",
            csrf_token=_csrf_token(),
            setup_locked=False,
            pin_length=_panel_pin_length(),
            error="No se pudo iniciar sesión. Inténtalo de nuevo más tarde.",
        )
        return response, 429, {"Retry-After": str(delay)}

    pin = request.form.get("panel_pin", "")
    if not verify_panel_pin_hash(_PANEL_PIN_HASH_FILE, pin):
        delay = _record_authentication_failure(remote)
        app.logger.warning("Panel login rejected")
        response = render_template(
            "login.html",
            csrf_token=_csrf_token(),
            setup_locked=False,
            pin_length=_panel_pin_length(),
            error="No se pudo iniciar sesión. Verifica las credenciales.",
        )
        return response, 401, {"Retry-After": str(delay)}

    with _AUTH_FAILURES_LOCK:
        _AUTH_FAILURES.pop(remote, None)
    next_path = request.args.get("next", "/")
    if not next_path.startswith("/") or next_path.startswith("//"):
        next_path = "/"
    session.clear()
    session.permanent = True
    session["panel_authenticated"] = True
    session["authenticated_at"] = int(time.time())
    _csrf_token()
    return redirect(next_path)


@app.route("/logout", methods=["POST"])
def logout():
    if not _csrf_is_valid(request.form.get("csrf_token")) or not _request_origin_is_same_host():
        return jsonify({"success": False, "message": "Solicitud no permitida"}), 403
    session.clear()
    return redirect(url_for("login"))


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
_CAPTIVE_LOGIN_URL = "http://192.168.4.1/login"


def _captive_redirect():
    # Captive-network probes arrive with public Host headers. A relative
    # redirect would preserve that untrusted host and the security filter would
    # correctly reject /login. Always move the browser to the fixed AP origin.
    return redirect(_CAPTIVE_LOGIN_URL, code=302)


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


@app.route("/startup")
def startup():
    """Calm, public first-session wait screen for the saved Bluetooth speaker."""
    if _startup_state()["PANEL_READY"]:
        return redirect(url_for("login"))
    return render_template("startup.html")


@app.route("/api/startup-status")
def startup_status():
    """Expose only readiness, never device identity or audio metadata."""
    return jsonify({"states": _startup_state()})


# ── Rutas principales ──────────────────────────────────────────────────────────

@app.route("/")
def index():
    preferred_bt = get_preferred_device()
    bt_devices = get_known_devices()
    for d in bt_devices:
        d["preferred"] = d["mac"] == preferred_bt

    return render_template(
        "index.html",
        bt_devices=bt_devices,
        wifi_networks=[],
        current_wifi=get_current_wifi(),
        preferred_bt=preferred_bt,
        csrf_token=_csrf_token(),
    )


@app.route("/api/csrf-token")
def api_csrf_token():
    """Return the token bound to the currently authenticated session."""
    return jsonify({"success": True, "csrf_token": _csrf_token()})


# ── Rutas Bluetooth ────────────────────────────────────────────────────────────

@app.route("/scan/stream")
def scan_stream():
    """SSE: emite dispositivos BT en tiempo real conforme se descubren."""
    preferred_bt = get_preferred_device()
    return Response(
        stream_bluetooth_scan(preferred_bt),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/scan/known")
def scan_known():
    """Devuelve dispositivos ya emparejados para la carga inicial (JSON)."""
    preferred_bt = get_preferred_device()
    devices = get_known_devices()
    for d in devices:
        d["preferred"] = d["mac"] == preferred_bt
        d["known"] = True
    return jsonify({"devices": devices})


@app.route("/bt/status")
def bt_status():
    """Devuelve el estado REAL de conexión de todos los dispositivos conocidos."""
    preferred_bt = get_preferred_device()
    devices = get_known_devices()
    result = []
    for d in devices:
        result.append({
            "mac": d["mac"],
            "name": d["name"],
            "preferred": d["mac"] == preferred_bt,
            "connected": bool(d.get("connected")),
            "known": True,
        })
    return jsonify({
        "devices": result,
        "connected_macs": [d["mac"] for d in result if d["connected"]],
    })


@app.route("/pair", methods=["POST"])
def pair():
    if request.is_json:
        mac = request.json.get("mac", "")
    else:
        mac = request.form.get("mac", "")
    if not is_valid_mac(mac):
        return jsonify({"success": False, "message": "MAC inválida"}), 400
    success, msg = pair_device(mac)
    return jsonify({"success": success, "message": msg})


@app.route("/connect/<mac>", methods=["POST"])
def api_connect(mac):
    success, msg = connect_device(mac)
    return jsonify({"success": success, "message": msg})


@app.route("/disconnect_active", methods=["POST"])
def api_disconnect_active():
    success, msg = disconnect_device()
    return jsonify({"success": success, "message": msg})


@app.route("/remove/<mac>", methods=["POST"])
def api_remove(mac):
    if not is_valid_mac(mac):
        return jsonify({"success": False, "message": "MAC inválida"}), 400
    success, msg = remove_device(mac)
    return jsonify({"success": success, "message": msg})


# ── Rutas WiFi ─────────────────────────────────────────────────────────────────

@app.route("/wifi/scan")
def wifi_scan():
    try:
        return jsonify({"success": True, "busy": False, "networks": scan_wifi_networks()})
    except WifiScanBusy as error:
        return jsonify({
            "success": False,
            "busy": True,
            "retry_after_ms": 1500,
            "message": str(error),
            "networks": [],
        }), 409


@app.route("/wifi/connect", methods=["POST"])
def wifi_connect_route():
    _expire_pending_wifi()
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"success": False, "message": "Solicitud WiFi inválida"}), 400
    try:
        ssid, password = validate_wifi_credentials(
            data.get("ssid"), data.get("password", "")
        )
    except WifiCredentialError as error:
        return jsonify({"success": False, "message": str(error)}), 422

    with _WIFI_PENDING_LOCK:
        if config.wifi_status.get("running") or _WIFI_PENDING:
            return jsonify({
                "success": False,
                "message": "Ya hay una conexión en progreso, espera…",
            }), 429
        operation_id = secrets.token_urlsafe(18)
        _WIFI_PENDING[operation_id] = {
            "ssid": ssid,
            "password": password,
            "accepted_at": time.monotonic(),
        }
        config.wifi_status.update({
            "running": True,
            "success": None,
            "phase": "awaiting_commit",
            "started_at": int(time.time()),
            "message": "Conexión preparada; esperando confirmación del navegador",
        })
        expiry_timer = threading.Timer(_WIFI_ACCEPT_TTL_SECONDS, _expire_pending_wifi)
        expiry_timer.daemon = True
        expiry_timer.start()

    message = (
        "Conexión iniciada. La red SIGIL puede desaparecer mientras el dispositivo "
        "se conecta a tu WiFi."
    )
    return jsonify({
        "success": True,
        "accepted": True,
        "operation_id": operation_id,
        "commit_url": url_for("wifi_connect_commit_route", operation_id=operation_id),
        "message": message,
    }), 202


@app.route("/wifi/connect/<operation_id>/commit", methods=["POST"])
def wifi_connect_commit_route(operation_id: str):
    """Start radio ownership only after the browser confirms the 202 response."""
    _expire_pending_wifi()
    with _WIFI_PENDING_LOCK:
        operation = _WIFI_PENDING.pop(operation_id, None)
        if operation is None:
            return jsonify({
                "success": False,
                "message": "La solicitud WiFi expiró o ya fue confirmada",
            }), 409
        config.wifi_status.update({
            "phase": "transitioning",
            "message": "Cambiando de la red SIGIL al WiFi seleccionado…",
        })

    ssid = str(operation["ssid"])
    password = str(operation["password"])

    def _do_wifi():
        try:
            success, message = connect_wifi(ssid, password)
            config.wifi_status.update({
                "success": success,
                "phase": "complete" if success else "failed",
                "message": message,
            })
        except BaseException as error:
            app.logger.error("[WiFi] transition failed: %s", type(error).__name__)
            config.wifi_status.update({
                "success": False,
                "phase": "failed",
                "message": "Error interno durante la transición WiFi",
            })
        finally:
            config.wifi_status["running"] = False

    worker = threading.Thread(target=_do_wifi, daemon=True, name="sigil-wifi-connect")
    try:
        worker.start()
    except RuntimeError:
        app.logger.error("[WiFi] transition worker could not start")
        config.wifi_status.update({
            "running": False,
            "success": False,
            "phase": "failed",
            "message": "No se pudo iniciar la transición WiFi",
        })
        return jsonify({
            "success": False,
            "message": "No se pudo iniciar la transición WiFi",
        }), 503
    return jsonify({"success": True, "accepted": True}), 202


@app.route("/wifi/status")
def wifi_status():
    _expire_pending_wifi()
    return jsonify(config.wifi_status)


# ── Rutas de Música ────────────────────────────────────────────────────────────

@app.route("/music/status")
def music_status():
    """Devuelve telemetría de reproducción sin controlar el runtime."""
    track_name = "Sin reproducción"
    track_url = ""
    playback_state = _read_bounded_json(_PLAYBACK_STATE_FILE)
    audio_mode = _read_bounded_json(_AUDIO_MODE_FILE)

    # Only the canonical runtime state can assert liveness.  now_playing.txt is
    # retained solely as rollback-era display metadata and may be stale.
    is_playing = bool(playback_state and playback_state.get("playing") is True)
    canonical_track = ""
    if playback_state:
        current_track = playback_state.get("current_track")
        if isinstance(current_track, dict):
            canonical_track = current_track.get("title") or current_track.get("url") or ""
        if not canonical_track:
            local_state = playback_state.get("local")
            if isinstance(local_state, dict):
                canonical_track = local_state.get("current_track_url") or ""

    public_track = _public_track_value(canonical_track)
    if not public_track:
        public_track = _public_track_value(_read_legacy_now_playing())
    if public_track:
        track_url = public_track
        track_name = public_track[:-4] if public_track.lower().endswith(".mp3") else public_track

    output = playback_state.get("output") if playback_state else None
    if not isinstance(output, dict):
        output = {}
    route = output.get("type") if isinstance(output.get("type"), str) else ""
    output_sink = output.get("sink") if isinstance(output.get("sink"), str) else ""
    runtime_state = audio_mode.get("mode") if audio_mode and isinstance(audio_mode.get("mode"), str) else ""
    runtime_error = audio_mode.get("last_error") if audio_mode and isinstance(audio_mode.get("last_error"), str) else ""

    preferred_mac = get_preferred_device()
    speaker_connected = is_device_connected(preferred_mac) if preferred_mac else False

    return jsonify({
        "is_playing": is_playing,
        "track_name": track_name,
        "track_url": track_url,
        "speaker_mac": preferred_mac or "",
        "speaker_connected": speaker_connected,
        "route": route,
        "output": output_sink,
        "runtime_state": runtime_state,
        "error": runtime_error,
    })


@app.route("/music/next", methods=["POST"])
def music_next():
    """Compatibility endpoint: autonomous playback has no track controls."""
    return jsonify({
        "success": False,
        "message": "Operación no disponible en reproducción autónoma",
    }), 409


# ── Entrypoint ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.environ.get("SIGIL_PANEL_PORT", "80"))
    app.run(host="0.0.0.0", port=port, debug=False)
