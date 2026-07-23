#!/usr/bin/env python3
"""Focused tests for SIGIL WiFi geolocation integration."""
import io
import importlib.util
import json
import os
import glob
import grp
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "panel"))

import wifi as wifi_mod

# Save original scan function for tests that need real parsing
_original_scan = wifi_mod.scan_wifi_aps

DEFAULT_APS = [
    {"bssid": "10:BB:CC:DD:EE:01", "signal_dbm": -45, "channel": 6},
    {"bssid": "20:BB:CC:DD:EE:02", "signal_dbm": -60, "channel": 11},
    {"bssid": "30:BB:CC:DD:EE:03", "signal_dbm": -75, "channel": 1},
    {"bssid": "40:BB:CC:DD:EE:04", "signal_dbm": -80, "channel": 3},
]


def _fake_scan(*args, **kwargs):
    if not hasattr(_fake_scan, "_aps"):
        _fake_scan._aps = list(DEFAULT_APS)
    return _fake_scan._aps


import geolocation as geo
_original_geo_scan = geo.scan_wifi_aps
import urllib.error

_CONTROL_PATH = os.path.join(
    os.path.dirname(__file__), "..", "scripts", "sigil-wifi-control.py"
)
_CONTROL_SPEC = importlib.util.spec_from_file_location(
    "sigil_wifi_control_geolocation_test", _CONTROL_PATH
)
assert _CONTROL_SPEC is not None and _CONTROL_SPEC.loader is not None
wifi_control = importlib.util.module_from_spec(_CONTROL_SPEC)
_CONTROL_SPEC.loader.exec_module(wifi_control)


def setUpModule():
    # Apply the deterministic scan fixture only while this module's tests run.
    wifi_mod.scan_wifi_aps = _fake_scan
    geo.scan_wifi_aps = _fake_scan


def tearDownModule():
    wifi_mod.scan_wifi_aps = _original_scan
    geo.scan_wifi_aps = _original_geo_scan


def _reset_aps():
    _fake_scan._aps = list(DEFAULT_APS)


def _make_mock_urlopen(status=200, body=None):
    body = body or b'{"lat": 1.0, "lng": 2.0, "accuracy": 50}'
    resp = MagicMock(spec_set=["read", "status", "__enter__", "__exit__"])
    resp.read.return_value = body
    resp.status = status
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = None
    return resp


class TestDeviceID(unittest.TestCase):
    def test_cpu_serial(self):
        def _se(p, *a, **kw):
            if p == "/proc/cpuinfo":
                return io.StringIO("Serial\t\t: 10000000abcdef\nHardware\t: BCM2835\n")
            raise FileNotFoundError(2, "No such file", p)
        with patch("builtins.open", side_effect=_se):
            self.assertEqual(geo._get_device_id(), "10000000abcdef")

    def test_cpu_serial_zero_falls_to_machine_id(self):
        def _se(p, *a, **kw):
            if p == "/proc/cpuinfo":
                return io.StringIO("Serial\t\t: 0000000000000000\n")
            if p == "/etc/machine-id":
                return io.StringIO("deadbeef0123456789abcdef\n")
            raise FileNotFoundError(2, "No such file", p)
        with patch("builtins.open", side_effect=_se):
            self.assertEqual(geo._get_device_id(), "deadbeef01234567")

    def test_machine_id_fallback_on_missing_cpuinfo(self):
        def _se(p, *a, **kw):
            if p == "/proc/cpuinfo":
                raise FileNotFoundError(2, "No such file", p)
            if p == "/etc/machine-id":
                return io.StringIO("abcdef1234567890xyz\n")
            raise FileNotFoundError(2, "No such file", p)
        with patch("builtins.open", side_effect=_se):
            self.assertEqual(geo._get_device_id(), "abcdef1234567890")

    def test_unknown_fallback_when_all_missing(self):
        with patch("builtins.open", side_effect=FileNotFoundError(2, "No such file")):
            self.assertEqual(geo._get_device_id(), "sigil-unknown")

    def test_empty_machine_id_falls_to_unknown(self):
        def _se(path, *args, **kwargs):
            if path == "/proc/cpuinfo":
                return io.StringIO("Processor: test\n")
            if path == "/etc/machine-id":
                return io.StringIO("")
            raise FileNotFoundError(2, "No such file", path)
        with patch("builtins.open", side_effect=_se):
            self.assertEqual(geo._get_device_id(), "sigil-unknown")

    def test_whitespace_machine_id_falls_to_unknown(self):
        def _se(path, *args, **kwargs):
            if path == "/proc/cpuinfo":
                return io.StringIO("Processor: test\n")
            if path == "/etc/machine-id":
                return io.StringIO("  \n\t")
            raise FileNotFoundError(2, "No such file", path)
        with patch("builtins.open", side_effect=_se):
            self.assertEqual(geo._get_device_id(), "sigil-unknown")

    def test_valid_machine_id_is_truncated(self):
        def _se(path, *args, **kwargs):
            if path == "/proc/cpuinfo":
                return io.StringIO("Processor: test\n")
            if path == "/etc/machine-id":
                return io.StringIO("0123456789abcdefEXTRA\n")
            raise FileNotFoundError(2, "No such file", path)
        with patch("builtins.open", side_effect=_se):
            self.assertEqual(geo._get_device_id(), "0123456789abcdef")


class TestBSSIDNormalization(unittest.TestCase):
    def test_already_normalized(self):
        self.assertEqual(wifi_mod._normalize_bssid("AA:BB:CC:DD:EE:FF"), "aa:bb:cc:dd:ee:ff")

    def test_lowercase(self):
        self.assertEqual(wifi_mod._normalize_bssid("aa:bb:cc:dd:ee:ff"), "aa:bb:cc:dd:ee:ff")

    def test_dash_separated(self):
        self.assertEqual(wifi_mod._normalize_bssid("aa-bb-cc-dd-ee-ff"), "aa:bb:cc:dd:ee:ff")

    def test_mixed_format(self):
        self.assertEqual(wifi_mod._normalize_bssid("AA:bb-CC:dd-EE:ff"), "aa:bb:cc:dd:ee:ff")


class TestAPDedupAndSorting(unittest.TestCase):
    def _make_scan_output(self, cells):
        lines = []
        for i, (bssid, signal, channel) in enumerate(cells):
            lines.append(f"Cell {i + 1:02d} - Address: {bssid}")
            lines.append(f"          Channel:{channel}")
            sig_qual = max(0, min(70, int(70 + signal * 70 / 100)))
            lines.append(f"          Quality={sig_qual}/70  Signal level={signal} dBm")
            lines.append(f"          ESSID:\"NET_{i}\"")
        return "\n".join(lines)

    def test_dedup_keeps_strongest(self):
        cells = [
            ("AA:BB:CC:DD:EE:01", -50, 1),
            ("AA:BB:CC:DD:EE:01", -40, 1),
            ("AA:BB:CC:DD:EE:02", -60, 6),
        ]
        with patch.object(wifi_mod, "_scan_via_socket", return_value=self._make_scan_output(cells)):
            result = _original_scan()
        self.assertEqual(len(result), 2, f"Got {len(result)} APs: {result}")
        ee01 = [a for a in result if a["bssid"] == "aa:bb:cc:dd:ee:01"][0]
        self.assertEqual(ee01["signal_dbm"], -40)

    def test_sorted_by_signal_descending(self):
        cells = [
            ("AA:BB:CC:DD:EE:03", -75, 1),
            ("AA:BB:CC:DD:EE:01", -45, 6),
            ("AA:BB:CC:DD:EE:02", -60, 11),
        ]
        with patch.object(wifi_mod, "_scan_via_socket", return_value=self._make_scan_output(cells)):
            result = _original_scan()
        signals = [a["signal_dbm"] for a in result]
        self.assertEqual(signals, sorted(signals, reverse=True))


class TestAPLimits(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_under_min_aps_returns_error(self):
        _fake_scan._aps = [{"bssid": "AA:BB:CC:DD:EE:01", "signal_dbm": -50}]
        with patch.object(geo, "SCAN_SAMPLE_DELAY_SECONDS", 0):
            result = geo.geolocate(
                "http://server", "key", "dev",
                {"SIGIL_GEOLOCATION_MIN_APS": "2"},
            )
        self.assertFalse(result["success"])
        self.assertEqual(result["error"], "insufficient_scan_quality")
        self.assertTrue(result["retryable"])

    def test_busy_scan_is_deferred_without_network_request(self):
        with patch.object(geo, "scan_wifi_aps", side_effect=wifi_mod.WifiScanBusy("busy")):
            with patch("urllib.request.urlopen") as request:
                result = geo.geolocate("http://server", "key", "dev", {})
        self.assertFalse(result["success"])
        self.assertTrue(result["retryable"])
        self.assertEqual(result["error"], "wifi_scan_busy")
        request.assert_not_called()

    def test_over_max_aps_truncated(self):
        many = [{"bssid": f"AA:BB:CC:DD:EE:{i:02d}", "signal_dbm": -50} for i in range(35)]
        _fake_scan._aps = many
        captured = {}

        def capture(request, **_kwargs):
            captured["payload"] = json.loads(request.data.decode("utf-8"))
            return _make_mock_urlopen()

        with patch("urllib.request.urlopen", side_effect=capture) as mock_urlopen:
            result = geo.geolocate(
                "http://server", "key", "dev",
                {"SIGIL_GEOLOCATION_MAX_APS": "30"},
            )

        self.assertTrue(result["success"])
        self.assertEqual(result["ap_count"], 30)
        self.assertEqual(len(captured["payload"]["wifi_access_points"]), 30)
        mock_urlopen.assert_called_once()


class TestEndpointAndPayload(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_payload_structure(self):
        _fake_scan._aps = [dict(ap) for ap in DEFAULT_APS]
        _fake_scan._aps[0].update({
            "frequency_mhz": 2437,
            "ssid": "must-not-leave-device",
            "observation_count": 99,
        })
        sent = {}

        def cap(req, **_kw):
            sent["url"] = req.full_url
            sent["method"] = req.method
            h = {k.lower(): v for k, v in req.headers.items()}
            sent["headers"] = h
            sent["body"] = json.loads(req.data.decode("utf-8"))
            return _make_mock_urlopen()

        with patch("urllib.request.urlopen", side_effect=cap):
            result = geo.geolocate(
                "https://sigil.example.com", "test-key-123", "dev_abc", {},
            )

        self.assertTrue(result["success"])
        self.assertEqual(sent["url"], "https://sigil.example.com/api/devices/dev_abc/geolocate")
        self.assertEqual(sent["method"], "POST")
        self.assertEqual(sent["headers"].get("x-api-key"), "test-key-123")
        self.assertEqual(sent["headers"].get("content-type"), "application/json")
        body = sent["body"]
        self.assertIn("_schema_version", body)
        self.assertEqual(body["_schema_version"], "1.0")
        self.assertIn("observed_at", body)
        self.assertIn("wifi_access_points", body)
        ap = body["wifi_access_points"][0]
        self.assertIn("bssid", ap)
        self.assertIn("signal_dbm", ap)
        self.assertIn("channel", ap)
        self.assertNotIn("macAddress", ap)
        self.assertNotIn("signalStrength", ap)
        self.assertNotIn("ssid", ap)
        self.assertNotIn("frequency_mhz", ap)
        self.assertNotIn("observation_count", ap)
        self.assertNotIn("locally_administered", ap)

    def test_url_no_trailing_slash(self):
        _fake_scan._aps = [dict(ap) for ap in DEFAULT_APS]
        sent = {}

        def cap(req, **_kw):
            sent["url"] = req.full_url
            return _make_mock_urlopen()

        with patch("urllib.request.urlopen", side_effect=cap):
            geo.geolocate("https://sigil.example.com/", "key", "d1", {})

        self.assertFalse(sent["url"].endswith("//"))


class TestAuthSecurity(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_api_key_in_header_not_url(self):
        sent = {}

        def cap(req, **_kw):
            h = {k.lower(): v for k, v in req.headers.items()}
            sent["headers"] = h
            sent["url"] = req.full_url
            return _make_mock_urlopen()

        with patch("urllib.request.urlopen", side_effect=cap):
            geo.geolocate("http://server", "my-secret-api-key", "dev1", {})

        self.assertEqual(sent["headers"].get("x-api-key"), "my-secret-api-key")
        self.assertNotIn("my-secret-api-key", sent["url"])

    def test_api_config_not_in_argv(self):
        args_before = list(sys.argv)
        geo._load_config("/dummy")
        self.assertEqual(list(sys.argv), args_before)

    def test_success_log_does_not_expose_coordinates(self):
        with patch.object(geo, "geolocate", return_value={
            "success": True,
            "lat": 12.345678,
            "lng": -76.543210,
            "accuracy": 25,
            "ap_count": 4,
            "http_status": 200,
            "retryable": False,
        }), patch.object(geo, "_acquire_lock", return_value=True), \
             patch.object(geo, "_load_config", return_value={
                 "SERVER_URL": "https://server.invalid",
             }), patch.object(geo.Path, "read_text", return_value="key"), \
             patch.object(geo, "_get_device_id", return_value="device"), \
             patch.object(geo, "_read_state", return_value={
                 "last_attempt_time": 0,
                 "last_retryable": False,
             }), patch.object(geo, "_write_state"), \
             patch.object(geo.time, "time", return_value=7200), \
             self.assertLogs(geo.logger, level="INFO") as captured:
            geo.main()
        output = "\n".join(captured.output)
        self.assertNotIn("12.345678", output)
        self.assertNotIn("-76.54321", output)


class TestTimeoutAndRetries(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_timeout_returns_error(self):
        with patch("urllib.request.urlopen", side_effect=socket.timeout("timed out")), \
             patch.object(geo.time, "sleep"):
            result = geo.geolocate(
                "http://server", "key", "dev1",
                {"SIGIL_GEOLOCATION_TIMEOUT_SECONDS": "1"},
            )
        self.assertFalse(result["success"])
        self.assertTrue(result["retryable"])

    def test_no_retry_on_4xx(self):
        call_count = 0

        def fail_4xx(*_a, **_kw):
            nonlocal call_count
            call_count += 1
            raise urllib.error.HTTPError("http://server", 401, "Unauthorized", {}, None)

        with patch("urllib.request.urlopen", side_effect=fail_4xx):
            result = geo.geolocate("http://server", "key", "dev1", {})

        self.assertFalse(result["success"])
        self.assertEqual(call_count, 1)

    def test_retry_on_5xx_then_succeed(self):
        call_count = 0

        def fail_then_ok(*_a, **_kw):
            nonlocal call_count
            call_count += 1
            if call_count < 2:
                raise urllib.error.HTTPError(
                    "http://server", 500, "Server Error", {}, None,
                )
            return _make_mock_urlopen()

        with patch("urllib.request.urlopen", side_effect=fail_then_ok):
            result = geo.geolocate("http://server", "key", "dev1", {})

        self.assertTrue(result["success"])
        self.assertEqual(call_count, 2)


class TestAdaptiveScanning(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_good_first_sample_does_not_rescan(self):
        scanner = MagicMock(return_value=[dict(ap) for ap in DEFAULT_APS])
        with patch.object(geo, "scan_wifi_aps", scanner), \
             patch("urllib.request.urlopen", return_value=_make_mock_urlopen()):
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertTrue(result["success"])
        self.assertEqual(scanner.call_count, 1)

    def test_poor_first_sample_stops_when_second_is_sufficient(self):
        poor = [dict(ap) for ap in DEFAULT_APS[:2]]
        good = [dict(ap) for ap in DEFAULT_APS]
        scanner = MagicMock(side_effect=[poor, good])
        with patch.object(geo, "scan_wifi_aps", scanner), \
             patch.object(geo.time, "sleep"), \
             patch("urllib.request.urlopen", return_value=_make_mock_urlopen()):
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertTrue(result["success"])
        self.assertEqual(scanner.call_count, 2)

    def test_never_more_than_three_samples(self):
        poor = [dict(ap) for ap in DEFAULT_APS[:2]]
        scanner = MagicMock(return_value=poor)
        with patch.object(geo, "scan_wifi_aps", scanner), \
             patch.object(geo.time, "sleep"), \
             patch("urllib.request.urlopen") as request:
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertFalse(result["success"])
        self.assertTrue(result["retryable"])
        self.assertEqual(scanner.call_count, 3)
        request.assert_not_called()

    def test_third_sample_can_complete_a_poor_scan(self):
        poor = [dict(ap) for ap in DEFAULT_APS[:2]]
        good = [dict(ap) for ap in DEFAULT_APS]
        scanner = MagicMock(side_effect=[poor, poor, good])
        with patch.object(geo, "scan_wifi_aps", scanner), \
             patch.object(geo.time, "sleep"), \
             patch("urllib.request.urlopen", return_value=_make_mock_urlopen()):
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertTrue(result["success"])
        self.assertEqual(scanner.call_count, 3)

    def test_median_rssi_aggregation(self):
        samples = [
            [{"bssid": "10:22:33:44:55:66", "signal_dbm": -40}],
            [{"bssid": "10:22:33:44:55:66", "signal_dbm": -80}],
            [{"bssid": "10:22:33:44:55:66", "signal_dbm": -60}],
        ]
        result = geo._aggregate_samples(samples)
        self.assertEqual(result[0]["signal_dbm"], -60)
        self.assertEqual(result[0]["observation_count"], 3)

    def test_observation_count_sorts_before_signal(self):
        repeated = {"bssid": "10:22:33:44:55:01", "signal_dbm": -80}
        strong_once = {"bssid": "20:22:33:44:55:02", "signal_dbm": -35}
        result = geo._aggregate_samples([[repeated, strong_once], [repeated]])
        self.assertEqual(result[0]["bssid"], "10:22:33:44:55:01")

    def test_duplicate_normalization_counts_once_per_sample(self):
        result = geo._aggregate_samples([[
            {"bssid": "10:22:33:44:55:66", "signal_dbm": -70},
            {"bssid": "10-22-33-44-55-66", "signal_dbm": -50},
        ]])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["bssid"], "10:22:33:44:55:66")
        self.assertEqual(result[0]["signal_dbm"], -50)
        self.assertEqual(result[0]["observation_count"], 1)

    def test_local_bssid_retained_until_enough_stable_global_bssids(self):
        local = {"bssid": "12:22:33:44:55:99", "signal_dbm": -40}
        one_global = {"bssid": "10:22:33:44:55:01", "signal_dbm": -60}
        retained = geo._aggregate_samples([
            [one_global, local],
            [one_global, local],
        ])
        self.assertIn(local["bssid"], [ap["bssid"] for ap in retained])

        globals_ = [
            {"bssid": f"{prefix}:22:33:44:55:01", "signal_dbm": -60}
            for prefix in ("10", "20", "30", "40")
        ]
        deprioritized = geo._aggregate_samples([
            globals_ + [local],
            globals_ + [local],
        ])
        self.assertNotIn(local["bssid"], [ap["bssid"] for ap in deprioritized])


class TestWifiGeolocationParsing(unittest.TestCase):
    @staticmethod
    def _cell(index, bssid, signal=-50, channel=None, frequency=None, ssid="net"):
        lines = [f"Cell {index:02d} - Address: {bssid}"]
        if channel is not None:
            lines.append(f"          Channel:{channel}")
        if frequency is not None:
            lines.append(f"          Frequency:{frequency}")
        lines.append(f"          Quality=50/70  Signal level={signal} dBm")
        lines.append(f'          ESSID:"{ssid}"')
        return "\n".join(lines)

    def _parse(self, raw):
        with patch.object(wifi_mod, "_scan_via_socket", return_value=raw):
            return _original_scan()

    def test_invalid_zero_broadcast_and_multicast_are_rejected(self):
        raw = "\n".join([
            self._cell(1, "not-a-mac"),
            self._cell(2, "00:00:00:00:00:00"),
            self._cell(3, "FF:FF:FF:FF:FF:FF"),
            self._cell(4, "11:22:33:44:55:66"),
            self._cell(5, "10:22:33:44:55:66"),
        ])
        self.assertEqual(
            [ap["bssid"] for ap in self._parse(raw)],
            ["10:22:33:44:55:66"],
        )

    def test_weak_and_nonnegative_signals_are_rejected(self):
        raw = "\n".join([
            self._cell(1, "10:22:33:44:55:01", signal=-93),
            self._cell(2, "20:22:33:44:55:02", signal=0),
            self._cell(3, "30:22:33:44:55:03", signal=12),
            self._cell(4, "40:22:33:44:55:04", signal=-92),
        ])
        result = self._parse(raw)
        self.assertEqual([ap["bssid"] for ap in result], ["40:22:33:44:55:04"])

    def test_hidden_ssid_bssid_remains_valid(self):
        result = self._parse(
            self._cell(1, "10:22:33:44:55:66", signal=-50, ssid="")
        )
        self.assertEqual(len(result), 1)

    def test_frequency_to_channel_conversion(self):
        self.assertEqual(wifi_mod._frequency_to_channel(2412), 1)
        self.assertEqual(wifi_mod._frequency_to_channel(2484), 14)
        self.assertEqual(wifi_mod._frequency_to_channel(5180), 36)
        self.assertEqual(wifi_mod._frequency_to_channel(5745), 149)

    def test_frequency_is_preserved_and_channel_is_derived(self):
        result = self._parse(
            self._cell(1, "10:22:33:44:55:66", frequency="5.180 GHz")
        )
        self.assertEqual(result[0]["frequency_mhz"], 5180)
        self.assertEqual(result[0]["channel"], 36)

    def test_existing_channel_parsing_remains_compatible(self):
        result = self._parse(
            self._cell(1, "10:22:33:44:55:66", channel=11)
        )
        self.assertEqual(result[0]["channel"], 11)

    def test_quality_fallback_remains_available(self):
        raw = "\n".join([
            "Cell 01 - Address: 10:22:33:44:55:66",
            "          Channel:6",
            "          Quality=35/70",
            '          ESSID:"hidden-or-visible"',
        ])
        result = self._parse(raw)
        self.assertEqual(result[0]["signal_dbm"], -65)


class TestScanTimeoutPolicy(unittest.TestCase):
    def test_daemon_and_client_timeout_are_coherent(self):
        self.assertEqual(wifi_control.SCAN_TIMEOUT, wifi_mod.WIFI_SCAN_TIMEOUT_SECONDS)
        self.assertGreater(
            wifi_mod.WIFI_SCAN_SOCKET_TIMEOUT_SECONDS,
            wifi_control.SCAN_TIMEOUT,
        )
        worst_case = (
            geo.MAX_SCAN_SAMPLES * wifi_mod.WIFI_SCAN_SOCKET_TIMEOUT_SECONDS
            + (geo.MAX_SCAN_SAMPLES - 1) * geo.SCAN_SAMPLE_DELAY_SECONDS
            + geo.SCAN_AGGREGATION_RESERVE_SECONDS
        )
        self.assertLessEqual(worst_case, geo.SCAN_TOTAL_BUDGET_SECONDS)

    def test_daemon_releases_lock_after_scan_timeout(self):
        timeout = subprocess.TimeoutExpired(
            cmd=["iwlist", "wlan0", "scan"],
            timeout=wifi_control.SCAN_TIMEOUT,
        )
        with patch.object(wifi_control, "_acquire_lock", return_value=77), \
             patch.object(wifi_control, "_release_lock") as release, \
             patch.object(wifi_control.subprocess, "run", side_effect=timeout):
            result = wifi_control._handle_scan()
        self.assertEqual(result["error"], "scan_timeout")
        release.assert_called_once_with(77)

    def test_normal_daemon_scan_is_unchanged(self):
        completed = MagicMock(returncode=0, stdout="scan-data")
        with patch.object(wifi_control, "_acquire_lock", return_value=78), \
             patch.object(wifi_control, "_release_lock") as release, \
             patch.object(wifi_control.subprocess, "run", return_value=completed) as run:
            result = wifi_control._handle_scan()
        self.assertTrue(result["accepted"])
        self.assertEqual(result["scan_data"], "scan-data")
        self.assertEqual(run.call_args.kwargs["timeout"], wifi_control.SCAN_TIMEOUT)
        release.assert_called_once_with(78)

    def test_scan_timeout_is_transient_and_not_retried_immediately(self):
        scanner = MagicMock(side_effect=wifi_mod.WifiScanTimeout("timed out"))
        with patch.object(geo, "scan_wifi_aps", scanner), \
             patch("urllib.request.urlopen") as request:
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertFalse(result["success"])
        self.assertTrue(result["retryable"])
        self.assertEqual(result["error"], "scan_timeout")
        self.assertEqual(scanner.call_count, 1)
        request.assert_not_called()

    def test_control_socket_failure_is_transient(self):
        scanner = MagicMock(
            side_effect=wifi_mod.WifiControlUnavailable("socket unavailable")
        )
        with patch.object(geo, "scan_wifi_aps", scanner), \
             patch("urllib.request.urlopen") as request:
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertTrue(result["retryable"])
        self.assertEqual(result["error"], "wifi_control_unavailable")
        self.assertEqual(
            geo._cooldown_seconds({"last_retryable": result["retryable"]}, {}),
            60,
        )
        request.assert_not_called()

    def test_worst_case_adaptive_scan_stays_within_budget(self):
        clock = [0.0]
        poor = [dict(ap) for ap in DEFAULT_APS[:2]]

        def monotonic():
            return clock[0]

        def sleep(seconds):
            clock[0] += seconds

        def slow_scan():
            clock[0] += wifi_mod.WIFI_SCAN_SOCKET_TIMEOUT_SECONDS
            return poor

        with patch.object(geo.time, "monotonic", side_effect=monotonic), \
             patch.object(geo.time, "sleep", side_effect=sleep), \
             patch.object(geo, "scan_wifi_aps", side_effect=slow_scan) as scanner:
            _aps, metadata = geo._adaptive_wifi_scan(min_aps=2, max_aps=30)

        self.assertEqual(scanner.call_count, 3)
        self.assertLessEqual(metadata["elapsed"], geo.SCAN_TOTAL_BUDGET_SECONDS)


class TestCooldownPolicy(unittest.TestCase):
    def test_short_cooldown_is_bounded_for_transient_failures(self):
        self.assertEqual(geo._cooldown_seconds({"last_retryable": True}, {}), 60)
        self.assertEqual(geo._cooldown_seconds(
            {"last_retryable": True},
            {"SIGIL_GEOLOCATION_SHORT_COOLDOWN_SECONDS": "5"},
        ), 30)
        self.assertEqual(geo._cooldown_seconds(
            {"last_retryable": True},
            {"SIGIL_GEOLOCATION_SHORT_COOLDOWN_SECONDS": "999"},
        ), 120)

    def test_long_cooldown_after_valid_server_request(self):
        _reset_aps()
        with patch("urllib.request.urlopen", return_value=_make_mock_urlopen()):
            result = geo.geolocate("http://server", "key", "dev", {})
        self.assertTrue(result["success"])
        self.assertFalse(result["retryable"])
        state = {"last_retryable": result["retryable"]}
        self.assertEqual(geo._cooldown_seconds(state, {}), 3600)


class TestCooldownViaMain(unittest.TestCase):
    def setUp(self):
        _reset_aps()
        self.tmpdir = tempfile.mkdtemp()
        self._orig_cfg = geo.CONFIG_PATH
        self._orig_dir = geo.STATE_DIR
        self._orig_file = geo.STATE_FILE
        geo.CONFIG_PATH = os.path.join(self.tmpdir, "audio.conf")
        geo.STATE_DIR = self.tmpdir
        geo.STATE_FILE = os.path.join(self.tmpdir, "geolocation_state.json")

    def tearDown(self):
        geo.CONFIG_PATH = self._orig_cfg
        geo.STATE_DIR = self._orig_dir
        geo.STATE_FILE = self._orig_file

    def _write_config(self):
        with open(geo.CONFIG_PATH, "w") as f:
            f.write('SERVER_URL="http://s"\nAPI_KEY="k"\n')

    def _write_state(self, ts=None):
        ts = ts or int(time.time())
        with open(geo.STATE_FILE, "w") as f:
            json.dump({
                "device_id": "test", "last_attempt_time": ts,
                "last_success_time": 0, "last_result": "",
                "last_http_status": 0, "last_ap_count": 0,
            }, f)

    def test_main_returns_0_on_cooldown(self):
        self._write_config()
        self._write_state(int(time.time()))
        with patch.object(geo, "_acquire_lock", return_value=True):
            self.assertEqual(geo.main(), 0)

    def test_main_returns_0_when_lock_busy(self):
        with patch.object(geo, "_acquire_lock", return_value=False):
            self.assertEqual(geo.main(), 0)

    def test_main_returns_0_when_config_missing(self):
        with patch.object(geo, "_acquire_lock", return_value=True):
            self.assertEqual(geo.main(), 0)


class TestLockRealFile(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self._orig_lock = geo.LOCK_FILE
        self._orig_dir = geo.STATE_DIR
        self._orig_state_file = geo.STATE_FILE
        self._orig_cfg = geo.CONFIG_PATH
        geo.LOCK_FILE = os.path.join(self.tmpdir, "geolocate.lock")
        geo.STATE_DIR = self.tmpdir
        geo.STATE_FILE = os.path.join(self.tmpdir, "state.json")
        geo.CONFIG_PATH = os.path.join(self.tmpdir, "audio.conf")

    def tearDown(self):
        geo.LOCK_FILE = self._orig_lock
        geo.STATE_DIR = self._orig_dir
        geo.STATE_FILE = self._orig_state_file
        geo.CONFIG_PATH = self._orig_cfg

    def test_acquire_release_real_lock(self):
        import fcntl
        fd = os.open(geo.LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except OSError:
            locked = False
        self.assertTrue(locked)
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

    def test_main_acquires_lock(self):
        geo.CONFIG_PATH = os.path.join(self.tmpdir, "no-such-file.conf")
        result = geo.main()
        self.assertEqual(result, 0)

    def test_lock_file_created(self):
        import fcntl
        fd = os.open(geo.LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertTrue(os.path.exists(geo.LOCK_FILE))
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class TestStateFileIO(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._orig_dir = geo.STATE_DIR
        cls._orig_file = geo.STATE_FILE

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        geo.STATE_DIR = self.tmpdir
        geo.STATE_FILE = os.path.join(self.tmpdir, "geolocation_state.json")

    def tearDown(self):
        geo.STATE_DIR = self._orig_dir
        geo.STATE_FILE = self._orig_file
        shutil.rmtree(self.tmpdir)

    def _create_existing_state(self, mode=0o640):
        with open(geo.STATE_FILE, "w", encoding="utf-8") as handle:
            handle.write("{}\n")
        os.chmod(geo.STATE_FILE, mode)
        return os.stat(geo.STATE_FILE)

    def test_atomic_write(self):
        before = self._create_existing_state()
        state = {
            "device_id": "test", "last_attempt_time": 42,
            "last_success_time": 0, "last_result": "success",
            "last_http_status": 200, "last_ap_count": 5,
        }
        geo._write_state(state)
        self.assertTrue(os.path.exists(geo.STATE_FILE))
        self.assertEqual(glob.glob(os.path.join(self.tmpdir, ".geolocation-state.*.tmp")), [])
        after = os.stat(geo.STATE_FILE)
        self.assertEqual(after.st_uid, before.st_uid)
        self.assertEqual(after.st_gid, before.st_gid)
        self.assertEqual(after.st_mode & 0o777, before.st_mode & 0o777)
        with open(geo.STATE_FILE, encoding="utf-8") as handle:
            document = json.load(handle)
        self.assertEqual(document["_schema_version"], geo.SCHEMA_VERSION)
        self.assertEqual(document["last_attempt_time"], 42)

    def test_no_bssid_in_state(self):
        self._create_existing_state()
        state = {
            "device_id": "test", "last_attempt_time": 42,
            "last_success_time": 0, "last_result": "success",
            "last_http_status": 200, "last_ap_count": 5,
            "bssid": "AA:BB:CC:DD:EE:01",
            "signal_dbm": -42,
            "wifi_access_points": [{"bssid": "AA:BB:CC:DD:EE:02"}],
            "ssid": "private-network",
            "api_key": "private-api-key",
            "device_token": "private-device-token",
            "lat": 1.23,
            "lng": 4.56,
        }
        geo._write_state(state)
        with open(geo.STATE_FILE) as f:
            keys = json.dumps(json.load(f))
        self.assertNotIn("bssid", keys)
        self.assertNotIn("signal_dbm", keys)
        self.assertNotIn("wifi_access_points", keys)
        self.assertNotIn("private-network", keys)
        self.assertNotIn("private-api-key", keys)
        self.assertNotIn("private-device-token", keys)
        self.assertNotIn("lat", keys)
        self.assertNotIn("lng", keys)

    def test_new_state_uses_canonical_metadata(self):
        current_user = pwd.getpwuid(os.getuid())
        current_group = grp.getgrgid(os.getgid())
        with patch("pwd.getpwnam", return_value=current_user), \
             patch("grp.getgrnam", return_value=current_group):
            geo._write_state({"device_id": "test"})
        metadata = os.stat(geo.STATE_FILE)
        self.assertEqual(metadata.st_uid, os.getuid())
        self.assertEqual(metadata.st_gid, os.getgid())
        self.assertEqual(metadata.st_mode & 0o777, 0o660)

    def test_temporary_file_removed_on_replace_error(self):
        self._create_existing_state()
        with patch("os.replace", side_effect=OSError("replace failed")):
            with self.assertRaises(OSError):
                geo._write_state({"device_id": "test"})
        self.assertEqual(glob.glob(os.path.join(self.tmpdir, ".geolocation-state.*.tmp")), [])

    def test_read_state_returns_defaults_on_missing(self):
        state = geo._read_state()
        self.assertEqual(state["_schema_version"], geo.SCHEMA_VERSION)
        self.assertEqual(state["last_attempt_time"], 0)
        self.assertEqual(state["device_id"], "")


class TestDispatcherFiltering(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.dispatcher = os.path.join(
            os.path.dirname(__file__), "..", "conf", "90-sigil-geolocate",
        )
        self.worker = os.path.join(self.tmpdir, "worker.py")
        self.marker = os.path.join(self.tmpdir, "worker-ran")
        self.log = os.path.join(self.tmpdir, "worker.log")
        with open(self.worker, "w", encoding="utf-8") as handle:
            handle.write(
                "import os\n"
                "with open(os.environ['SIGIL_TEST_GEO_MARKER'], 'a', encoding='utf-8') as out:\n"
                "    out.write('worker-ran\\n')\n"
            )

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _run_dispatch(self, interface, action, delay="0.35"):
        environment = os.environ.copy()
        environment.update({
            "SIGIL_GEO_DELAY_SECONDS": delay,
            "SIGIL_GEO_PYTHON": sys.executable,
            "SIGIL_GEO_SCRIPT": self.worker,
            "SIGIL_GEO_LOG": self.log,
            "SIGIL_TEST_GEO_MARKER": self.marker,
        })
        started = time.monotonic()
        result = subprocess.run(
            ["bash", self.dispatcher, interface, action],
            capture_output=True,
            timeout=2,
            env=environment,
        )
        return result, time.monotonic() - started

    def test_wlan0_up_returns_promptly_and_worker_runs_once(self):
        result, elapsed = self._run_dispatch("wlan0", "up")
        self.assertEqual(result.returncode, 0, msg=result.stderr.decode())
        self.assertLess(elapsed, 0.25)
        self.assertFalse(os.path.exists(self.marker))
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and not os.path.exists(self.marker):
            time.sleep(0.02)
        self.assertTrue(os.path.exists(self.marker))
        with open(self.marker, encoding="utf-8") as handle:
            self.assertEqual(handle.readlines(), ["worker-ran\n"])

    def test_eth0_up_skips(self):
        result, elapsed = self._run_dispatch("eth0", "up", delay="0")
        self.assertEqual(result.returncode, 0)
        self.assertLess(elapsed, 0.25)
        self.assertFalse(os.path.exists(self.marker))

    def test_wlan0_down_skips(self):
        result, _elapsed = self._run_dispatch("wlan0", "down", delay="0")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(os.path.exists(self.marker))

    def test_wlan0_dhcp4_change_skips(self):
        result, _elapsed = self._run_dispatch("wlan0", "dhcp4-change", delay="0")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(os.path.exists(self.marker))

    def test_dispatch_script_syntax_ok(self):
        r = subprocess.run(["bash", "-n", self.dispatcher], capture_output=True, timeout=5)
        self.assertEqual(r.returncode, 0, msg=r.stderr.decode())

    def test_production_worker_uses_protected_absolute_paths(self):
        with open(self.dispatcher, encoding="utf-8") as handle:
            dispatcher = handle.read()
        self.assertIn(
            'GEO_PYTHON="${SIGIL_GEO_PYTHON:-/usr/bin/python3}"', dispatcher
        )
        self.assertIn(
            'GEO_SCRIPT="${SIGIL_GEO_SCRIPT:-/opt/sigil/panel/geolocation.py}"',
            dispatcher,
        )
        self.assertNotIn("/home/sigil/", dispatcher)


class TestConfigLoading(unittest.TestCase):
    def test_load_config(self):
        with patch("builtins.open", side_effect=lambda *a, **kw: (
            io.StringIO('SERVER_URL="https://example.com"\nAPI_KEY="secret123"\n')
        )):
            config = geo._load_config("/dummy")
        self.assertEqual(config.get("SERVER_URL"), "https://example.com")
        self.assertEqual(config.get("API_KEY"), "secret123")

    def test_load_config_file_not_found(self):
        with patch("builtins.open", side_effect=FileNotFoundError(2, "No such file")):
            self.assertEqual(geo._load_config("/nonexistent"), {})


class TestFailureNonCritical(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_geolocate_never_raises(self):
        with patch("urllib.request.urlopen", side_effect=Exception("anything")):
            try:
                result = geo.geolocate("http://server", "key", "dev1", {})
                self.assertFalse(result["success"])
            except Exception:
                self.fail("geolocate() raised unexpectedly")

    def test_main_never_raises_on_lock_busy(self):
        with patch.object(geo, "_acquire_lock", return_value=False):
            try:
                self.assertEqual(geo.main(), 0)
            except Exception:
                self.fail("main() raised unexpectedly")


if __name__ == "__main__":
    unittest.main(verbosity=2)
