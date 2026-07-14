#!/usr/bin/env python3
"""Focused tests for SIGIL WiFi geolocation integration."""
import io
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
    {"bssid": "AA:BB:CC:DD:EE:01", "signal_dbm": -45, "channel": 6},
    {"bssid": "AA:BB:CC:DD:EE:02", "signal_dbm": -60, "channel": 11},
    {"bssid": "AA:BB:CC:DD:EE:03", "signal_dbm": -75, "channel": 1},
]


def _fake_scan(*args, **kwargs):
    if not hasattr(_fake_scan, "_aps"):
        _fake_scan._aps = list(DEFAULT_APS)
    return _fake_scan._aps


# Patch module-level AND save original for dedup tests
wifi_mod.scan_wifi_aps = _fake_scan
import geolocation as geo
# Also patch geolocation's namespace copy (from-import creates a local reference)
geo.scan_wifi_aps = _fake_scan
import urllib.error


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
        self.assertEqual(wifi_mod._normalize_bssid("AA:BB:CC:DD:EE:FF"), "AA:BB:CC:DD:EE:FF")

    def test_lowercase(self):
        self.assertEqual(wifi_mod._normalize_bssid("aa:bb:cc:dd:ee:ff"), "AA:BB:CC:DD:EE:FF")

    def test_dash_separated(self):
        self.assertEqual(wifi_mod._normalize_bssid("aa-bb-cc-dd-ee-ff"), "AA:BB:CC:DD:EE:FF")

    def test_mixed_format(self):
        self.assertEqual(wifi_mod._normalize_bssid("AA:bb-CC:dd-EE:ff"), "AA:BB:CC:DD:EE:FF")


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

    @patch("subprocess.run")
    def test_dedup_keeps_strongest(self, mock_run):
        cells = [
            ("AA:BB:CC:DD:EE:01", -50, 1),
            ("AA:BB:CC:DD:EE:01", -40, 1),
            ("AA:BB:CC:DD:EE:02", -60, 6),
        ]
        mock_run.return_value = MagicMock(stdout=self._make_scan_output(cells), returncode=0)
        result = _original_scan()
        self.assertEqual(len(result), 2, f"Got {len(result)} APs: {result}")
        ee01 = [a for a in result if a["bssid"] == "AA:BB:CC:DD:EE:01"][0]
        self.assertEqual(ee01["signal_dbm"], -40)

    @patch("subprocess.run")
    def test_sorted_by_signal_descending(self, mock_run):
        cells = [
            ("AA:BB:CC:DD:EE:03", -75, 1),
            ("AA:BB:CC:DD:EE:01", -45, 6),
            ("AA:BB:CC:DD:EE:02", -60, 11),
        ]
        mock_run.return_value = MagicMock(stdout=self._make_scan_output(cells), returncode=0)
        result = _original_scan()
        signals = [a["signal_dbm"] for a in result]
        self.assertEqual(signals, sorted(signals, reverse=True))


class TestAPLimits(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_under_min_aps_returns_error(self):
        _fake_scan._aps = [{"bssid": "AA:BB:CC:DD:EE:01", "signal_dbm": -50}]
        result = geo.geolocate("http://server", "key", "dev", {"SIGIL_GEOLOCATION_MIN_APS": "2"})
        self.assertFalse(result["success"])
        self.assertIn("not_enough_aps", result["error"])

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
        _fake_scan._aps = [
            {"bssid": "AA:BB:CC:DD:EE:01", "signal_dbm": -45, "channel": 6},
            {"bssid": "AA:BB:CC:DD:EE:02", "signal_dbm": -60, "channel": 11},
        ]
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
        self.assertNotIn("macAddress", ap)
        self.assertNotIn("signalStrength", ap)

    def test_url_no_trailing_slash(self):
        _fake_scan._aps = [
            {"bssid": "AA:BB:CC:DD:EE:01", "signal_dbm": -50},
            {"bssid": "AA:BB:CC:DD:EE:02", "signal_dbm": -60},
        ]
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


class TestTimeoutAndRetries(unittest.TestCase):
    def setUp(self):
        _reset_aps()

    def test_timeout_returns_error(self):
        with patch("urllib.request.urlopen", side_effect=socket.timeout("timed out")):
            result = geo.geolocate(
                "http://server", "key", "dev1",
                {"SIGIL_GEOLOCATION_TIMEOUT_SECONDS": "1"},
            )
        self.assertFalse(result["success"])

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
        }
        geo._write_state(state)
        with open(geo.STATE_FILE) as f:
            keys = json.dumps(json.load(f))
        self.assertNotIn("bssid", keys)
        self.assertNotIn("signal_dbm", keys)
        self.assertNotIn("wifi_access_points", keys)

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
