#!/usr/bin/env python3
"""Focused tests for the panel-to-Bluetooth-owner contract."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "panel"))

import bluetooth


FAKE_MAC = "02:00:00:00:00:01"


class BluetoothOwnerContractTests(unittest.TestCase):
    @patch("bluetooth.subprocess.run")
    def test_connect_uses_bounded_structured_owner_request(self, run):
        run.return_value = MagicMock(
            returncode=0,
            stdout=json.dumps({
                "success": True,
                "code": "connected",
                "message": "Conectado exitosamente",
                "mac": FAKE_MAC,
            }),
            stderr="",
        )

        success, message = bluetooth.connect_device(FAKE_MAC.lower())

        self.assertTrue(success)
        self.assertEqual(message, "Conectado exitosamente")
        self.assertEqual(run.call_args_list, [call(
            [bluetooth.BT_OWNER_COMMAND, "request", "connect", FAKE_MAC],
            capture_output=True,
            text=True,
            timeout=bluetooth.BT_OWNER_TIMEOUT_SECONDS,
            check=False,
        )])
        self.assertNotIn("shell", run.call_args.kwargs)

    @patch("bluetooth.subprocess.run")
    def test_owner_failure_cannot_be_reported_as_success(self, run):
        run.return_value = MagicMock(
            returncode=1,
            stdout=json.dumps({
                "success": False,
                "code": "connect_failed",
                "message": "No se pudo conectar",
                "mac": None,
            }),
            stderr="",
        )

        self.assertEqual(
            bluetooth.connect_device(FAKE_MAC),
            (False, "No se pudo conectar"),
        )

    @patch("bluetooth.subprocess.run")
    def test_owner_timeout_is_bounded_and_reported(self, run):
        run.side_effect = bluetooth.subprocess.TimeoutExpired(
            cmd="bt-connect.sh", timeout=bluetooth.BT_OWNER_TIMEOUT_SECONDS
        )

        success, message = bluetooth.pair_device(FAKE_MAC)

        self.assertFalse(success)
        self.assertIn("Timeout", message)

    def test_preferred_reader_normalizes_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            preferred = Path(temp_dir) / "preferred_bt.txt"
            preferred.write_text(FAKE_MAC.lower() + "\n", encoding="ascii")
            with patch.object(bluetooth, "PREFERRED_BT_FILE", str(preferred)):
                self.assertEqual(bluetooth.get_preferred_device(), FAKE_MAC)

            target = Path(temp_dir) / "target"
            target.write_text(FAKE_MAC + "\n", encoding="ascii")
            preferred.unlink()
            preferred.symlink_to(target)
            with patch.object(bluetooth, "PREFERRED_BT_FILE", str(preferred)):
                self.assertIsNone(bluetooth.get_preferred_device())


if __name__ == "__main__":
    unittest.main()
