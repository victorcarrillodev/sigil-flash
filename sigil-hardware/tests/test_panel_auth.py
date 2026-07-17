#!/usr/bin/env python3
"""Production-behavior tests for local panel PIN authentication."""

from __future__ import annotations

import importlib.util
import io
import logging
import os
import re
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from jinja2 import FileSystemLoader


ROOT = Path(__file__).resolve().parents[1]
PANEL = ROOT / "panel"
SYNTHETIC_PIN = "80427159"

sys.path.insert(0, str(PANEL))
import panel_auth  # noqa: E402


class CredentialProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sigil-panel-auth-")
        self.root = Path(self.temporary.name)
        self.input = self.root / "sigil_secrets.json"
        self.output_dir = self.root / "secrets"
        self.output_dir.mkdir(mode=0o750)
        self.output = self.output_dir / "panel-pin.hash"

    def tearDown(self):
        self.temporary.cleanup()

    def write_secret(self, body: str) -> None:
        self.input.write_text(body, encoding="utf-8")
        self.input.chmod(0o600)

    def provision(self) -> str:
        return panel_auth.consume_manufacturing_secret(
            str(self.input),
            str(self.output),
            owner_uid=os.getuid(),
            owner_gid=os.getgid(),
        )

    def test_argon2id_hash_verifies_and_plaintext_is_removed(self):
        self.write_secret(
            '{"_schema_version":"1.0","panel_pin":"' + SYNTHETIC_PIN + '"}'
        )
        self.assertEqual(self.provision(), "configured")
        self.assertFalse(self.input.exists())
        encoded = self.output.read_text(encoding="ascii").strip()
        self.assertTrue(encoded.startswith("$argon2id$v=19$"))
        self.assertTrue(
            panel_auth.verify_panel_pin_hash(
                str(self.output), SYNTHETIC_PIN, os.getuid(), os.getgid()
            )
        )
        self.assertFalse(
            panel_auth.verify_panel_pin_hash(
                str(self.output), "80527149", os.getuid(), os.getgid()
            )
        )
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o640)

    def test_schema_unknown_fields_and_trivial_pins_are_rejected(self):
        for document in (
            '{"_schema_version":"1.0","panel_pin":"000000"}',
            '{"_schema_version":"1.0","panel_pin":"123456"}',
            '{"_schema_version":"1.0","panel_pin":"80427159","api_key":"fake"}',
            '{"_schema_version":"1.0","panel_pin":"80 27159"}',
        ):
            self.write_secret(document)
            with self.assertRaises(panel_auth.PanelCredentialError):
                self.provision()
            self.assertTrue(self.input.exists())

    def test_missing_hash_and_input_fails_closed(self):
        self.assertEqual(self.provision(), "setup-locked")


def load_panel_app(hash_path: Path):
    os.environ["SIGIL_SECRET_KEY"] = "synthetic-session-key-for-tests"
    os.environ["SIGIL_PANEL_PIN_HASH"] = str(hash_path)

    config = types.ModuleType("config")
    config.wifi_status = {"running": False, "success": None, "message": ""}
    sys.modules["config"] = config

    identity = types.ModuleType("device_identity")
    identity.load_identity = lambda: {"device_id": "SYNTHETIC-DEVICE"}
    sys.modules["device_identity"] = identity

    bluetooth = types.ModuleType("bluetooth")
    bluetooth.get_known_devices = lambda: []
    bluetooth.get_preferred_device = lambda: ""
    bluetooth.get_connected_devices = lambda: set()
    bluetooth.is_device_connected = lambda _mac: False
    bluetooth.is_valid_mac = lambda _mac: True
    bluetooth._is_mac = lambda _value: False
    bluetooth._get_real_name = lambda _mac: ""
    bluetooth.stream_bluetooth_scan = lambda *_args: iter(())
    bluetooth.pair_device = lambda _mac: (True, "ok")
    bluetooth.connect_device = lambda _mac: (True, "ok")
    bluetooth.disconnect_device = lambda: (True, "ok")
    bluetooth.remove_device = lambda _mac: (True, "ok")
    sys.modules["bluetooth"] = bluetooth

    wifi = types.ModuleType("wifi")
    wifi.WifiCredentialError = type("WifiCredentialError", (ValueError,), {})
    wifi.WifiScanBusy = type("WifiScanBusy", (RuntimeError,), {})
    wifi.scan_wifi_networks = lambda: []
    wifi.connect_wifi = lambda _ssid, _password: (True, "ok")
    wifi.get_current_wifi = lambda: ""
    wifi.validate_wifi_credentials = lambda ssid, password: (ssid, password)
    sys.modules["wifi"] = wifi

    name = f"sigil_panel_auth_test_{os.getpid()}_{id(hash_path)}"
    spec = importlib.util.spec_from_file_location(name, PANEL / "app.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    module.app.config.update(TESTING=True)
    module.app.jinja_loader = FileSystemLoader(str(PANEL / "templates"))
    module.verify_panel_pin_hash = lambda path, pin: panel_auth.verify_panel_pin_hash(
        path, pin, os.getuid(), os.getgid()
    )
    module.panel_hash_is_provisioned = lambda path: panel_auth.panel_hash_is_provisioned(
        path, os.getuid(), os.getgid()
    )
    module._AUTH_FAILURES.clear()
    return module


class FlaskAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sigil-flask-auth-")
        root = Path(self.temporary.name)
        root.chmod(0o750)
        secret = root / "input.json"
        secret.write_text(
            '{"_schema_version":"1.0","panel_pin":"' + SYNTHETIC_PIN + '"}',
            encoding="utf-8",
        )
        secret.chmod(0o600)
        self.hash_path = root / "panel-pin.hash"
        panel_auth.consume_manufacturing_secret(
            str(secret), str(self.hash_path), os.getuid(), os.getgid()
        )
        self.module = load_panel_app(self.hash_path)
        self.client = self.module.app.test_client()

    def tearDown(self):
        self.temporary.cleanup()

    def csrf_from_login(self) -> str:
        page = self.client.get("/login")
        self.assertEqual(page.status_code, 200)
        match = re.search(rb'name="csrf_token" value="([^"]+)"', page.data)
        self.assertIsNotNone(match)
        return match.group(1).decode("ascii")

    def authenticate(self):
        token = self.csrf_from_login()
        response = self.client.post(
            "/login",
            data={"csrf_token": token, "panel_pin": SYNTHETIC_PIN},
        )
        self.assertEqual(response.status_code, 302)
        return response

    def test_routes_reject_unauthenticated_access_and_captive_redirects(self):
        paths = [
            "/api/system-status", "/scan/known", "/bt/status", "/wifi/scan",
            "/wifi/status", "/music/status", "/api/csrf-token",
            "/connect/02:00:00:00:00:01",
            "/disconnect_active", "/remove/02:00:00:00:00:01",
        ]
        for path in paths:
            self.assertEqual(self.client.get(path).status_code, 401, path)
        for path in ("/pair", "/wifi/connect", "/music/next"):
            self.assertEqual(self.client.post(path).status_code, 401, path)
        self.assertEqual(self.client.get("/").status_code, 302)
        captive = self.client.get("/generate_204")
        self.assertEqual(captive.status_code, 302)
        self.assertEqual(captive.headers["Location"], "http://192.168.4.1/login")
        external_host = self.client.get("/generate_204", headers={"Host": "connectivity-check.invalid"})
        self.assertEqual(external_host.status_code, 302)
        self.assertEqual(
            external_host.headers["Location"], "http://192.168.4.1/login"
        )

    def test_correct_pin_creates_session_csrf_protects_mutation_and_logout_clears_it(self):
        response = self.authenticate()
        cookie = response.headers.get("Set-Cookie", "")
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertEqual(self.client.get("/api/system-status").status_code, 200)
        token_response = self.client.get("/api/csrf-token")
        self.assertEqual(token_response.status_code, 200)
        self.assertIn("no-store", token_response.headers["Cache-Control"])
        with self.client.session_transaction() as current:
            self.assertEqual(token_response.get_json()["csrf_token"], current["csrf_token"])
        self.assertEqual(
            self.client.post("/connect/02:00:00:00:00:01").status_code, 403
        )
        with self.client.session_transaction() as current:
            csrf = current["csrf_token"]
        allowed = self.client.post(
            "/connect/02:00:00:00:00:01", headers={"X-Sigil-CSRF": csrf}
        )
        self.assertEqual(allowed.status_code, 200)
        logged_out = self.client.post("/logout", data={"csrf_token": csrf})
        self.assertEqual(logged_out.status_code, 302)
        self.assertEqual(self.client.get("/api/system-status").status_code, 401)

    def test_https_configuration_marks_session_cookie_secure(self):
        self.module.app.config["SESSION_COOKIE_SECURE"] = True
        page = self.client.get("/login", base_url="https://localhost")
        token = re.search(rb'name="csrf_token" value="([^"]+)"', page.data).group(1).decode("ascii")
        response = self.client.post(
            "/login",
            data={"csrf_token": token, "panel_pin": SYNTHETIC_PIN},
            base_url="https://localhost",
        )
        self.assertIn("Secure", response.headers.get("Set-Cookie", ""))

    def test_busy_wifi_scan_returns_bounded_retry_without_side_effects(self):
        self.authenticate()

        def busy_scan():
            raise self.module.WifiScanBusy("Radio ocupado")

        self.module.scan_wifi_networks = busy_scan
        response = self.client.get("/wifi/scan")
        self.assertEqual(response.status_code, 409)
        document = response.get_json()
        self.assertFalse(document["success"])
        self.assertTrue(document["busy"])
        self.assertEqual(document["networks"], [])
        self.assertGreater(document["retry_after_ms"], 0)
        self.assertLessEqual(document["retry_after_ms"], 5000)

    def test_failed_attempts_have_bounded_backoff_and_logs_do_not_contain_pin(self):
        token = self.csrf_from_login()
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        self.module.app.logger.addHandler(handler)
        try:
            first = self.client.post(
                "/login", data={"csrf_token": token, "panel_pin": "80527149"}
            )
            second = self.client.post(
                "/login", data={"csrf_token": token, "panel_pin": "80527149"}
            )
        finally:
            self.module.app.logger.removeHandler(handler)
        self.assertEqual(first.status_code, 401)
        self.assertEqual(second.status_code, 429)
        self.assertLessEqual(int(second.headers["Retry-After"]), 60)
        self.assertNotIn("80527149", stream.getvalue())

    def test_existing_device_without_hash_is_setup_locked(self):
        self.hash_path.unlink()
        page = self.client.get("/login")
        self.assertEqual(page.status_code, 200)
        self.assertIn(b"bloqueado", page.data)
        self.assertEqual(self.client.get("/api/system-status").status_code, 401)


if __name__ == "__main__":
    unittest.main(verbosity=2)
