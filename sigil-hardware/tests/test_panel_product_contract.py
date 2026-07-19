#!/usr/bin/env python3
"""Product-contract tests for the deliberately merged SIGIL panel."""
import os
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PANEL = Path(os.environ.get("SIGIL_PANEL_ROOT", ROOT / "panel")).resolve()


class PanelProductContractTests(unittest.TestCase):
    def run_panel_python(self, source: str) -> subprocess.CompletedProcess:
        environment = os.environ.copy()
        environment.update({
            "PYTHONPATH": str(PANEL),
            "SIGIL_SECRET_KEY": "focused-test-secret",
            "PYTHONPYCACHEPREFIX": "/tmp/sigil-panel-contract-pycache",
        })
        return subprocess.run(
            [sys.executable, "-c", textwrap.dedent(source)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_wifi_password_is_preserved_exactly_and_validated_by_bytes(self):
        result = self.run_panel_python("""
            import wifi
            value = ' contraseña válida '
            ssid, password = wifi.validate_wifi_credentials(' Red SIGIL ', value)
            assert ssid == ' Red SIGIL '
            assert password == value
            for invalid in ('short', '1234567', 'g' * 64, 'valid123\\n'):
                try:
                    wifi.validate_wifi_credentials('Red', invalid)
                except wifi.WifiCredentialError:
                    pass
                else:
                    raise AssertionError(invalid)
            wifi.validate_wifi_credentials('Red', 'A' * 64)
        """)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wifi_acceptance_precedes_transition_start(self):
        result = self.run_panel_python("""
            from unittest.mock import patch
            import app
            started = []
            class FakeThread:
                def __init__(self, *args, **kwargs): self.target = kwargs.get('target')
                def start(self): started.append(self.target)
            with app.app.test_request_context('/wifi/connect', method='POST', json={
                'ssid': 'TestNet', 'password': ' exact-pass '
            }):
                response, status = app.wifi_connect_route()
                payload = response.get_json()
            assert status == 202 and payload['accepted'] is True
            assert started == []
            assert next(iter(app._WIFI_PENDING.values()))['password'] == ' exact-pass '
            with patch.object(app.threading, 'Thread', FakeThread):
                with app.app.test_request_context(payload['commit_url'], method='POST'):
                    _response, commit_status = app.wifi_connect_commit_route(payload['operation_id'])
            assert commit_status == 202 and len(started) == 1
        """)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wifi_worker_start_failure_clears_running_state(self):
        result = self.run_panel_python("""
            from unittest.mock import patch
            import app
            class FailedThread:
                def __init__(self, *args, **kwargs): pass
                def start(self): raise RuntimeError('thread unavailable')
            with app.app.test_request_context('/wifi/connect', method='POST', json={
                'ssid': 'TestNet', 'password': 'exact-pass'
            }):
                response, status = app.wifi_connect_route()
                operation_id = response.get_json()['operation_id']
            with patch.object(app.threading, 'Thread', FailedThread):
                with app.app.test_request_context(
                    f'/wifi/connect/{operation_id}/commit', method='POST'
                ):
                    response, status = app.wifi_connect_commit_route(operation_id)
            assert status == 503 and response.get_json()['success'] is False
            assert app.config.wifi_status['running'] is False
            assert app.config.wifi_status['phase'] == 'failed'
        """)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wifi_interface_contract_is_shared(self):
        wifi = (PANEL / "wifi.py").read_text(encoding="utf-8")
        helper = (ROOT / "scripts/wifi-fallback.sh").read_text(encoding="utf-8")
        sudoers = (ROOT / "conf/sigil-network.sudoers").read_text(encoding="utf-8")
        service = (ROOT / "services/bluetooth-panel.service").read_text(encoding="utf-8")
        defaults = (ROOT / "conf/wifi-fallback.conf").read_text(encoding="utf-8")
        self.assertIn("SIGIL_WIFI_INTERFACE", wifi)
        self.assertNotIn("SIGIL_WIFI_IFACE", wifi)
        self.assertIn('AP_INTERFACE="${SIGIL_WIFI_INTERFACE:-wlan0}"', helper)
        self.assertIn("SIGIL_WIFI_INTERFACE=wlan0", defaults)
        # No sudo panel-scan path — all scans route through sigil-wifi-control socket
        self.assertNotIn("panel-scan", sudoers)
        self.assertNotIn("wifi-fallback.sh", sudoers)
        self.assertIn("EnvironmentFile=-/etc/sigil/wifi-fallback.conf", service)

    def test_wifi_handoff_frontend_does_not_poll_the_disappearing_ap(self):
        javascript = (PANEL / "static/js/app.js").read_text(encoding="utf-8")
        wifi_block = javascript[javascript.index("function connectWifi"):]
        self.assertNotIn("fetch('/wifi/status')", wifi_block)
        self.assertIn("commit_url", wifi_block)
        self.assertIn("Expected when the accepted transition removes the SIGIL AP", wifi_block)
        self.assertIn("http://sigil.local", wifi_block)

    def test_failed_new_profile_is_cleaned_but_existing_profile_is_retained(self):
        daemon = (ROOT / "scripts/sigil-wifi-control.py").read_text(encoding="utf-8")
        self.assertIn("profile_created = False", daemon)
        self.assertIn("if profile_created and profile_id is not None", daemon)
        self.assertIn("_delete_nm_profile(profile_id)", daemon)
        self.assertNotIn("if not profile_created and profile_id is not None", daemon)

    def test_wifi_recovery_delegates_known_profile_selection_to_networkmanager(self):
        helper = (ROOT / "scripts/wifi-fallback.sh").read_text(encoding="utf-8")
        daemon = (ROOT / "scripts/sigil-wifi-control.py").read_text(encoding="utf-8")
        self.assertIn("'{\"command\":\"recover_client\"}'", helper)
        self.assertNotIn('nmcli device connect "$AP_INTERFACE"', helper)
        self.assertIn("['nmcli', 'device', 'connect', WIFI_INTERFACE]", daemon)
        self.assertNotIn("connection up id", helper)
        self.assertIn("LAST_SUCCESSFUL_PROFILE", helper)

    def test_automatic_bluetooth_never_blocks_or_untrusts_unrelated_devices(self):
        owner = (ROOT / "scripts/bt-connect.sh").read_text(encoding="utf-8")
        auto = owner[owner.index("auto_cycle_locked()") : owner.index("run_daemon()")]
        self.assertNotRegex(auto, r"\b(block|untrust|remove)\b")
        self.assertNotIn("disconnect_previous_preferred", auto)
        self.assertNotRegex(owner, r"run_bt [0-9]+ block")

    def test_explicit_remove_is_the_only_destructive_bluetooth_cleanup(self):
        owner = (ROOT / "scripts/bt-connect.sh").read_text(encoding="utf-8")
        remove = owner[owner.index("request_remove_locked()") : owner.index("emit_result()")]
        self.assertIn('run_bt 5 untrust "$mac"', remove)
        self.assertIn('run_bt 8 remove "$mac"', remove)
        prefix = owner[: owner.index("request_remove_locked()")]
        suffix = owner[owner.index("emit_result()") :]
        self.assertNotRegex(prefix + suffix, r"run_bt [0-9]+ (?:untrust|remove)")

    def test_preferred_bluetooth_recovery_uses_bounded_backoff(self):
        owner = (ROOT / "scripts/bt-connect.sh").read_text(encoding="utf-8")
        self.assertIn('preferred=$(read_preferred', owner)
        self.assertIn('prepare_target "$preferred"', owner)
        self.assertIn('AUTO_RETRY_INITIAL="${SIGIL_BT_RETRY_INITIAL:-15}"', owner)
        self.assertIn('AUTO_RETRY_MAX="${SIGIL_BT_RETRY_MAX:-300}"', owner)
        self.assertIn('retry_delay=$((retry_delay * 2))', owner)

    def test_scan_snapshot_and_lock_are_bounded(self):
        bluetooth = (PANEL / "bluetooth.py").read_text(encoding="utf-8")
        stream = bluetooth[bluetooth.index("def stream_bluetooth_scan"):]
        self.assertIn("scan_lock.acquire(blocking=False)", stream)
        self.assertEqual(stream.count("get_known_devices()"), 1)
        self.assertIn("info_cache", stream)
        self.assertIn("_is_audio_properties(properties)", stream)
        self.assertIn("proc.wait(timeout=3)", stream)

    def test_known_snapshot_uses_one_info_call_per_device(self):
        result = self.run_panel_python("""
            from unittest.mock import MagicMock, patch
            import bluetooth
            calls = []
            listing = '\\n'.join(
                f'Device 02:00:00:00:00:{number:02X} Speaker-{number}'
                for number in range(1, 6)
            )
            def fake_run(command, **_kwargs):
                calls.append(tuple(command))
                response = MagicMock(returncode=0, stderr='')
                if command == ['bluetoothctl', 'devices']:
                    response.stdout = listing
                else:
                    response.stdout = (
                        'Name: Speaker\\nIcon: audio-card\\nPaired: yes\\n'
                        'Connected: no\\nUUID: Audio Sink (0000110b)\\n'
                    )
                return response
            with patch.object(bluetooth.subprocess, 'run', side_effect=fake_run):
                devices = bluetooth.get_known_devices()
            info_calls = [call for call in calls if call[:2] == ('bluetoothctl', 'info')]
            assert len(devices) == 5
            assert len(info_calls) == 5
            assert len(calls) == 6
            assert len(set(info_calls)) == 5
        """)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_frontend_refreshes_complete_bluetooth_rows(self):
        javascript = (PANEL / "static/js/app.js").read_text(encoding="utf-8")
        self.assertIn("function refreshBluetoothState()", javascript)
        self.assertIn("existing.replaceWith(makeBtRow(data))", javascript)
        self.assertIn("setBluetoothRowProgress", javascript)
        self.assertIn("method: 'POST'", javascript)
        self.assertNotIn("setTimeout(() => location.reload()", javascript)

    def test_visual_assets_are_referenced_and_present(self):
        login = (PANEL / "templates/login.html").read_text(encoding="utf-8")
        index = (PANEL / "templates/index.html").read_text(encoding="utf-8")
        style = (PANEL / "static/css/style.css").read_text(encoding="utf-8")
        self.assertIn("video/login-bg.mp4", login)
        self.assertIn("img/logo.png", login + index)
        self.assertIn("prefers-reduced-motion", style)
        for relative in ("static/video/login-bg.mp4", "static/img/logo.png"):
            self.assertTrue((PANEL / relative).is_file(), relative)


if __name__ == "__main__":
    unittest.main()
