#!/usr/bin/env python3
"""Behavioral tests for the single-owner WiFi control daemon."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import types
import unittest
from unittest.mock import MagicMock, patch


ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON_PATH = ROOT / "scripts/sigil-wifi-control.py"
SPEC = importlib.util.spec_from_file_location("sigil_wifi_control", DAEMON_PATH)
assert SPEC and SPEC.loader
wifi_control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wifi_control)


def completed(stdout: str = "", returncode: int = 0) -> types.SimpleNamespace:
    return types.SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)


class WifiControlTests(unittest.TestCase):
    def tearDown(self) -> None:
        wifi_control._operation_id = None
        if hasattr(wifi_control._diagnostic_context, "operation_id"):
            delattr(wifi_control._diagnostic_context, "operation_id")

    def test_saved_wifi_recognizes_networkmanager_type_names(self) -> None:
        for value in ("wifi\n", "802-11-wireless\n", "wireless\n"):
            with self.subTest(value=value), patch.object(
                wifi_control.subprocess, "run", return_value=completed(value)
            ), patch.object(wifi_control, "_log_event"):
                self.assertTrue(wifi_control._has_saved_wifi())

    def test_saved_wifi_does_not_count_non_wifi_or_failed_inventory(self) -> None:
        for result in (completed("ethernet\nbridge\n"), completed("wifi\n", 10)):
            with self.subTest(result=result), patch.object(
                wifi_control.subprocess, "run", return_value=result
            ), patch.object(wifi_control, "_log_event"):
                self.assertFalse(wifi_control._has_saved_wifi())

    def test_probe_stops_at_first_failed_layer(self) -> None:
        with patch.object(wifi_control, "_nm_associated", return_value=False), \
                patch.object(wifi_control, "_has_client_address") as address, \
                patch.object(wifi_control, "_default_route") as route, \
                patch.object(wifi_control, "_dns_available") as dns, \
                patch.object(wifi_control, "_internet_reachable") as https, \
                patch.object(wifi_control, "_log_event"):
            result = wifi_control.probe_connectivity()
        self.assertEqual(result["network_state"], "WIFI_NOT_ASSOCIATED")
        address.assert_not_called()
        route.assert_not_called()
        dns.assert_not_called()
        https.assert_not_called()

    def test_probe_classifies_client_local_only(self) -> None:
        with patch.object(wifi_control, "_nm_associated", return_value=True), \
                patch.object(wifi_control, "_has_client_address", return_value=True), \
                patch.object(wifi_control, "_default_route", return_value=("4", "192.0.2.1")), \
                patch.object(wifi_control, "_gateway_reachable", return_value=True), \
                patch.object(wifi_control, "_dns_available", return_value=False), \
                patch.object(wifi_control, "_internet_reachable") as https, \
                patch.object(wifi_control, "_log_event"):
            result = wifi_control.probe_connectivity()
        self.assertEqual(result["network_state"], "CLIENT_LOCAL_ONLY")
        self.assertTrue(result["gateway_reachable"])
        self.assertFalse(result["internet_online"])
        https.assert_not_called()

    def test_connect_operation_id_is_returned_without_logging_password(self) -> None:
        wifi_control._diagnostic_context.operation_id = "op-test"
        worker = MagicMock()
        with patch.object(wifi_control.threading, "Thread", return_value=worker), \
                patch.object(wifi_control, "_write_state"), \
                patch.object(wifi_control, "_log_event"):
            response = json.loads(wifi_control._handle_client(json.dumps({
                "command": "connect",
                "ssid": "test-network",
                "password": "never-log-this",
            }).encode()))
        self.assertEqual(response["operation_id"], "op-test")
        worker.start.assert_called_once_with()

    def test_activation_failure_restores_ap_before_releasing_inhibit(self) -> None:
        events: list[str] = []

        def remove_inhibit() -> None:
            events.append("remove_inhibit")

        def restore_ap() -> bool:
            events.append("restore_ap")
            return True

        def delete_profile(_profile: str) -> None:
            events.append("delete_profile")

        with patch.object(wifi_control, "_acquire_lock", return_value=3), \
                patch.object(wifi_control, "_release_lock"), \
                patch.object(wifi_control, "_write_inhibit", return_value=True), \
                patch.object(wifi_control, "_remove_inhibit", side_effect=remove_inhibit), \
                patch.object(wifi_control, "_write_state"), \
                patch.object(wifi_control, "_stop_ap_services", return_value=True), \
                patch.object(wifi_control, "_create_nm_profile", return_value=("profile", True)), \
                patch.object(wifi_control, "_activate_profile", return_value=False), \
                patch.object(wifi_control, "_start_ap_services", side_effect=restore_ap), \
                patch.object(wifi_control, "_delete_nm_profile", side_effect=delete_profile), \
                patch.object(wifi_control, "_log_event"):
            wifi_control._operation_id = "op-rollback"
            wifi_control._background_connect("network", "secret", "op-rollback")
        self.assertEqual(events, ["restore_ap", "delete_profile", "remove_inhibit"])

    def test_nm_ownership_waits_until_device_is_available(self) -> None:
        calls: list[list[str]] = []
        states = iter((
            completed("GENERAL.STATE:10 (unmanaged)\n"),
            completed("GENERAL.STATE:20 (unavailable)\n"),
            completed("GENERAL.STATE:30 (disconnected)\n"),
        ))

        def run(args: list[str], **_kwargs: object) -> types.SimpleNamespace:
            calls.append(args)
            if args[:5] == ["nmcli", "-t", "-f", "GENERAL.STATE", "device"]:
                return next(states)
            return completed()

        with patch.object(wifi_control.subprocess, "run", side_effect=run), \
                patch.object(wifi_control.time, "sleep"), \
                patch.object(wifi_control, "_log_event") as log_event:
            self.assertTrue(wifi_control._stop_ap_services())

        activation_states = [
            call for call in calls
            if call[:5] == ["nmcli", "-t", "-f", "GENERAL.STATE", "device"]
        ]
        self.assertEqual(len(activation_states), 3)
        log_event.assert_any_call(
            "WIFI_NM_OWNERSHIP_ACQUIRED", "client_ownership",
            "success", nm_state=30,
        )

    def test_unit_uses_group_ownership_without_chown_capability(self) -> None:
        unit = (ROOT / "services/sigil-wifi-control.service").read_text()
        source = DAEMON_PATH.read_text()
        self.assertIn("Group=sigil", unit)
        self.assertNotIn("CAP_CHOWN", unit)
        self.assertNotIn("CAP_DAC_OVERRIDE", unit)
        self.assertNotIn("os.chown(SOCKET_PATH", source)
        self.assertNotRegex(source, re.compile(r"(?:chmod|makedirs)\([^\n]*0o777"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
