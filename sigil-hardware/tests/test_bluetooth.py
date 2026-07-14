#!/usr/bin/env python3
"""Focused tests for privileged PulseAudio calls from the Bluetooth panel."""
import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "panel"))

import bluetooth


class PulseAudioCommandTests(unittest.TestCase):
    @patch("bluetooth.pwd.getpwnam")
    def test_command_sets_target_user_session_after_sudo(self, getpwnam):
        getpwnam.return_value = SimpleNamespace(
            pw_uid=1234,
            pw_dir="/srv/sigil user",
        )

        command = bluetooth._sigil_pactl_command("list", "cards", "short")

        self.assertEqual(command, [
            "sudo", "-H", "-u", "sigil", "--",
            "env",
            "HOME=/srv/sigil user",
            "XDG_RUNTIME_DIR=/run/user/1234",
            "PULSE_SERVER=unix:/run/user/1234/pulse/native",
            "PULSE_RUNTIME_PATH=/run/user/1234/pulse",
            "pactl", "list", "cards", "short",
        ])

    @patch("bluetooth.subprocess.run")
    @patch("bluetooth.pwd.getpwnam")
    def test_a2dp_calls_use_argument_lists_without_shell(
        self, getpwnam, run
    ):
        getpwnam.return_value = SimpleNamespace(
            pw_uid=1001,
            pw_dir="/home/sigil",
        )
        run.side_effect = [
            MagicMock(stdout="1 bluez_card.AA_BB_CC_DD_EE_FF module\n"),
            MagicMock(stdout=""),
        ]

        bluetooth.set_a2dp_profile()

        prefix = [
            "sudo", "-H", "-u", "sigil", "--",
            "env",
            "HOME=/home/sigil",
            "XDG_RUNTIME_DIR=/run/user/1001",
            "PULSE_SERVER=unix:/run/user/1001/pulse/native",
            "PULSE_RUNTIME_PATH=/run/user/1001/pulse",
            "pactl",
        ]
        self.assertEqual(run.call_args_list, [
            call(
                prefix + ["list", "cards", "short"],
                capture_output=True,
                text=True,
                timeout=5,
            ),
            call(
                prefix + [
                    "set-card-profile",
                    "bluez_card.AA_BB_CC_DD_EE_FF",
                    "a2dp_sink",
                ],
                capture_output=True,
                timeout=5,
            ),
        ])
        for invocation in run.call_args_list:
            self.assertNotIn("shell", invocation.kwargs)


if __name__ == "__main__":
    unittest.main()
