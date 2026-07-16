#!/usr/bin/env python3
"""Production-behavior tests for single-radio WiFi/Bluetooth coexistence."""
import fcntl
import logging
import os
import pathlib
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import MagicMock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "panel"))

import wifi
import geolocation


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
        root = pathlib.Path(self.temporary.name)
        self.original_transition = wifi.WIFI_TRANSITION_LOCK
        self.original_scan = wifi.WIFI_SCAN_LOCK
        wifi.WIFI_TRANSITION_LOCK = str(root / "wifi-transition.lock")
        wifi.WIFI_SCAN_LOCK = str(root / "wifi-scan.lock")

    def tearDown(self):
        wifi.WIFI_TRANSITION_LOCK = self.original_transition
        wifi.WIFI_SCAN_LOCK = self.original_scan
        self.temporary.cleanup()

    @staticmethod
    def successful_command(arguments, **_kwargs):
        if arguments[:4] == ["sudo", "iwlist", "wlan0", "scan"]:
            return Result(SCAN_OUTPUT)
        if "connection" in arguments and "show" in arguments:
            return Result("FactoryNet:802-11-wireless\n")
        return Result()

    def hold_lock(self, path):
        handle = open(path, "a+", encoding="utf-8")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(handle.close)
        return handle

    def test_panel_and_geolocation_scans_cannot_overlap(self):
        started = threading.Event()
        release = threading.Event()
        calls = []

        def slow_command(arguments, **_kwargs):
            calls.append(list(arguments))
            if arguments[:4] == ["sudo", "iwlist", "wlan0", "scan"]:
                started.set()
                self.assertTrue(release.wait(2))
                return Result(SCAN_OUTPUT)
            return Result()

        with patch.object(wifi.subprocess, "run", side_effect=slow_command):
            worker = threading.Thread(target=wifi.scan_wifi_networks)
            worker.start()
            self.assertTrue(started.wait(1))
            with self.assertRaises(wifi.WifiScanBusy):
                wifi.scan_wifi_aps()
            release.set()
            worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(
            sum(call[:4] == ["sudo", "iwlist", "wlan0", "scan"] for call in calls),
            1,
        )

    def test_scan_and_wifi_transition_cannot_overlap(self):
        self.hold_lock(wifi.WIFI_TRANSITION_LOCK)
        with patch.object(wifi.subprocess, "run") as command:
            with self.assertRaises(wifi.WifiScanBusy):
                wifi.scan_wifi_networks()
        command.assert_not_called()

    def test_busy_scan_returns_immediately_without_radio_mutation(self):
        self.hold_lock(wifi.WIFI_SCAN_LOCK)
        before = time.monotonic()
        with patch.object(wifi.subprocess, "run") as command:
            with self.assertRaises(wifi.WifiScanBusy):
                wifi.scan_wifi_networks()
        self.assertLess(time.monotonic() - before, 0.5)
        command.assert_not_called()

    def test_unused_stale_scan_lock_is_safe_and_cleanup_is_idempotent(self):
        pathlib.Path(wifi.WIFI_SCAN_LOCK).write_text("stale-pid=999999\n", encoding="utf-8")
        with patch.object(wifi.subprocess, "run", side_effect=self.successful_command):
            first = wifi.scan_wifi_networks()
            second = wifi.scan_wifi_networks()
        self.assertEqual(first[0]["ssid"], "FactoryNet")
        self.assertEqual(second[0]["ssid"], "FactoryNet")

    def test_scan_never_controls_bluetooth_or_audio(self):
        calls = []

        def record(arguments, **kwargs):
            calls.append(list(arguments))
            return self.successful_command(arguments, **kwargs)

        with patch.object(wifi.subprocess, "run", side_effect=record):
            wifi.scan_wifi_networks()
        flattened = "\n".join(" ".join(call) for call in calls)
        for forbidden in ("bluetoothctl", "pactl", "paplay", "systemctl", "bt-connect"):
            self.assertNotIn(forbidden, flattened)

    def test_scan_does_not_log_or_pass_credentials(self):
        secret = "coexistence-test-secret"
        calls = []
        stream = MagicMock()
        handler = logging.StreamHandler(stream)
        wifi.logger.addHandler(handler)
        try:
            with patch.object(
                wifi.subprocess,
                "run",
                side_effect=lambda arguments, **kwargs: (
                    calls.append(list(arguments)) or self.successful_command(arguments, **kwargs)
                ),
            ):
                wifi.scan_wifi_networks()
        finally:
            wifi.logger.removeHandler(handler)
        self.assertNotIn(secret, "\n".join(" ".join(call) for call in calls))
        self.assertNotIn(secret, "".join(str(call) for call in stream.mock_calls))

    def test_geolocation_defers_when_scan_or_transition_is_busy(self):
        with patch.object(
            geolocation, "scan_wifi_aps", side_effect=wifi.WifiScanBusy("busy")
        ):
            with patch.object(geolocation.urllib.request, "urlopen") as request:
                result = geolocation.geolocate("https://server.invalid", "secret", "dev", {})
        self.assertEqual(result["error"], "wifi_scan_busy")
        self.assertTrue(result["retryable"])
        request.assert_not_called()

    def test_only_one_active_scan_command_exists(self):
        source = (ROOT / "panel/wifi.py").read_text(encoding="utf-8")
        self.assertEqual(source.count("['sudo', 'iwlist', 'wlan0', 'scan']"), 1)
        self.assertIn("scan_output = _run_active_wifi_scan()", source)
        self.assertEqual(source.count("WIFI_SCAN_LOCK ="), 1)

    def test_scan_lock_is_provisioned_once_for_both_callers(self):
        tmpfiles = (ROOT / "conf/sigil-tmpfiles.conf").read_text(encoding="utf-8")
        self.assertEqual(tmpfiles.count("/run/sigil/wifi-scan.lock"), 1)
        self.assertIn("from wifi import WifiScanBusy, scan_wifi_aps", (
            ROOT / "panel/geolocation.py"
        ).read_text(encoding="utf-8"))

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
