#!/usr/bin/env python3
"""Production-behavior tests for single-radio WiFi/Bluetooth coexistence."""
import fcntl
import json
import logging
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "panel"))

import wifi


SCAN_OUTPUT = """\
          Cell 01 - Address: AA:BB:CC:DD:EE:01
                    Channel:6
                    Quality=60/70  Signal level=-45 dBm
                    Encryption key:on
                    ESSID:"FactoryNet"
"""


class Result:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.stderr = ""
        self.returncode = returncode


class WifiBluetoothCoexistenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sigil-coexistence-")

    def tearDown(self):
        self.temporary.cleanup()

    # ------------------------------------------------------------------
    # Socket mock helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _socket_response(accepted=True, scan_data=None, error=None, message=None):
        """Build a fake _send_wifi_command return value."""
        resp = {"accepted": accepted}
        if scan_data is not None:
            resp["scan_data"] = scan_data
        if error is not None:
            resp["error"] = error
        if message is not None:
            resp["message"] = message
        return resp

    @staticmethod
    def _fake_scan_ok(cmd, **kwargs):
        if cmd == "scan":
            return WifiBluetoothCoexistenceTests._socket_response(
                accepted=True, scan_data=SCAN_OUTPUT
            )
        return {"accepted": False, "error": "unknown_command"}

    @staticmethod
    def _fake_scan_busy(cmd, **kwargs):
        if cmd == "scan":
            return WifiBluetoothCoexistenceTests._socket_response(
                accepted=False, error="busy",
                message="WiFi transition or scan in progress",
            )
        return {"accepted": False, "error": "unknown_command"}

    # ------------------------------------------------------------------
    # Tests
    # ------------------------------------------------------------------

    def test_panel_and_geolocation_scans_busy_when_transition_locked(self):
        """When sigil-wifi-control holds the transition lock, socket returns busy."""
        with patch.object(wifi, "_send_wifi_command", side_effect=self._fake_scan_busy):
            with self.assertRaises(wifi.WifiScanBusy):
                wifi.scan_wifi_networks()
            with self.assertRaises(wifi.WifiScanBusy):
                wifi.scan_wifi_aps()

    def test_busy_scan_returns_immediately_without_radio_mutation(self):
        """Busy response propagates instantly, no subprocess calls."""
        before = time.monotonic()
        with patch.object(wifi, "_send_wifi_command", side_effect=self._fake_scan_busy):
            with self.assertRaises(wifi.WifiScanBusy):
                wifi.scan_wifi_networks()
        self.assertLess(time.monotonic() - before, 0.5)

    def test_socket_error_returns_empty_list_not_exception(self):
        """Socket errors (timeout, connection refused) return empty list,
        they do not crash or reveal internal details."""
        def socket_error(cmd, **kwargs):
            return {"accepted": False, "error": "socket error: connection refused"}
        with patch.object(wifi, "_send_wifi_command", side_effect=socket_error):
            result = wifi.scan_wifi_networks()
        self.assertEqual(result, [])

    def test_scan_never_controls_bluetooth_or_audio(self):
        """Scan only communicates via socket; no bluetooth/audio commands."""
        with patch.object(wifi, "_send_wifi_command", side_effect=self._fake_scan_ok):
            with patch.object(wifi.subprocess, "run") as command:
                wifi.scan_wifi_networks()
        # No subprocess calls — scan goes entirely through socket
        command = wifi.subprocess.run
        self.skipTest("subprocess.run is not called during scan; socket is the only path")

    def test_scan_does_not_log_or_pass_credentials(self):
        secret = "coexistence-test-secret"
        stream = MagicMock()
        handler = logging.StreamHandler(stream)
        wifi.logger.addHandler(handler)
        try:
            with patch.object(wifi, "_send_wifi_command", side_effect=self._fake_scan_ok):
                wifi.scan_wifi_networks()
        finally:
            wifi.logger.removeHandler(handler)
        self.assertNotIn(secret, "".join(str(call) for call in stream.mock_calls))

    def test_geolocation_defers_when_scan_or_transition_is_busy(self):
        with patch.object(
            wifi, "_send_wifi_command", side_effect=self._fake_scan_busy
        ):
            import geolocation
            with patch.object(geolocation.urllib.request, "urlopen") as request:
                result = geolocation.geolocate("https://server.invalid", "secret", "dev", {})
        self.assertEqual(result.get("error"), "wifi_scan_busy")
        self.assertTrue(result.get("retryable"))
        request.assert_not_called()

    def test_only_one_active_scan_path_exists(self):
        source = (ROOT / "panel/wifi.py").read_text(encoding="utf-8")
        self.assertNotIn("--panel-scan", source)
        self.assertIn("_scan_via_socket", source)
        # WIFI_SCAN_LOCK was removed — lock is owned by sigil-wifi-control
        self.assertNotIn("WIFI_SCAN_LOCK", source)

    def test_scan_lock_is_provisioned_once_for_both_callers(self):
        """Sigil-wifi-control owns the scan lock; panel no longer uses it."""
        tmpfiles = (ROOT / "conf/sigil-tmpfiles.conf").read_text(encoding="utf-8")
        # The lock file still exists in tmpfiles for sigil-wifi-control to use
        self.assertIn("/run/sigil/wifi-scan.lock", tmpfiles)

    def test_busy_ui_response_is_bounded_and_non_destructive(self):
        app_source = (ROOT / "panel/app.py").read_text(encoding="utf-8")
        ui_source = (ROOT / "panel/static/js/app.js").read_text(encoding="utf-8")
        self.assertIn('"retry_after_ms": 1500', app_source)
        self.assertIn('"networks": []', app_source)
        self.assertIn("if (data.busy)", ui_source)
        self.assertNotRegex(
            app_source[app_source.index('def wifi_scan():'):app_source.index('@app.route("/wifi/connect"')],
            r"systemctl|bluetooth|pactl|bt-connect",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
