import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PanelPrivilegeSeparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.installer = (ROOT / "install.sh").read_text(encoding="utf-8")
        cls.unit = (ROOT / "services/bluetooth-panel.service").read_text(
            encoding="utf-8"
        )
        cls.network_sudoers = (ROOT / "conf/sigil-network.sudoers").read_text(
            encoding="utf-8"
        )
        cls.bluetooth_sudoers = (ROOT / "conf/sigil.sudoers").read_text(
            encoding="utf-8"
        )
        cls.dispatcher = (ROOT / "conf/90-sigil-geolocate").read_text(
            encoding="utf-8"
        )

    def test_flask_runs_as_sigil_from_the_protected_tree(self):
        self.assertRegex(self.unit, r"(?m)^User=sigil$")
        self.assertRegex(self.unit, r"(?m)^Group=sigil$")
        self.assertRegex(self.unit, r"(?m)^WorkingDirectory=/opt/sigil/panel$")
        self.assertRegex(
            self.unit,
            r"(?m)^ExecStart=/usr/bin/python3 /opt/sigil/panel/app\.py$",
        )
        self.assertNotRegex(self.unit, r"(?m)^ExecStart=.*?/home/sigil/.*\.py$")

    def test_only_low_port_binding_is_ambient_in_flask(self):
        self.assertRegex(
            self.unit, r"(?m)^AmbientCapabilities=CAP_NET_BIND_SERVICE$"
        )
        self.assertRegex(
            self.unit,
            r"(?m)^CapabilityBoundingSet="
            r"CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW "
            r"CAP_SETUID CAP_SETGID$",
        )
        self.assertNotRegex(
            self.unit, r"(?m)^AmbientCapabilities=.*CAP_(NET_ADMIN|NET_RAW)"
        )

    def test_wifi_power_save_setup_is_an_isolated_root_one_shot(self):
        self.assertRegex(
            self.unit,
            r"(?m)^ExecStartPre=-\+/usr/sbin/iw "
            r"dev wlan0 set power_save off$",
        )

    def test_installer_uses_root_owned_read_only_panel_tree(self):
        self.assertIn('PANEL_INSTALL_DIR="/opt/sigil/panel"', self.installer)
        self.assertIn("install -d -o root -g root -m 0755", self.installer)
        self.assertIn("install -o root -g root -m 0644", self.installer)
        self.assertNotRegex(
            self.installer,
            r'cp\s+"\$\{REPO_DIR\}/panel/"\*\.py\s+"\$\{SIGIL_HOME\}/"',
        )
        self.assertNotIn(
            'chown -R "${SIGIL_USER}:${SIGIL_USER}" "${SIGIL_HOME}"',
            self.installer,
        )
        self.assertIn(
            'chown -R root:root "${PANEL_INSTALL_DIR}"', self.installer
        )
        self.assertIn(
            'find "${PANEL_INSTALL_DIR}" -type d -exec chmod 0755 {} +',
            self.installer,
        )
        self.assertIn(
            'find "${PANEL_INSTALL_DIR}" -type f -exec chmod 0644 {} +',
            self.installer,
        )

    def test_installer_step_is_repeatable(self):
        panel_step = self.installer.split(
            "# ── Paso 4: Panel Python", maxsplit=1
        )[1].split("# ── Paso 5: Scripts de sistema", maxsplit=1)[0]
        self.assertNotRegex(panel_step, r"\b(mv|ln|cp -r)\b")
        self.assertEqual(
            panel_step.count('chown -R root:root "${PANEL_INSTALL_DIR}"'), 1
        )
        self.assertEqual(panel_step.count("install -d -o root -g root -m 0755"), 1)
        self.assertEqual(panel_step.count("install -o root -g root -m 0644"), 4)

    def test_root_dispatcher_uses_only_the_protected_python_tree(self):
        self.assertIn(
            'GEO_PYTHON="${SIGIL_GEO_PYTHON:-/usr/bin/python3}"', self.dispatcher
        )
        self.assertIn(
            'GEO_SCRIPT="${SIGIL_GEO_SCRIPT:-/opt/sigil/panel/geolocation.py}"',
            self.dispatcher,
        )
        self.assertNotIn("/home/sigil/", self.dispatcher)

    def test_installer_does_not_deploy_geolocation_code_to_sigil_home(self):
        self.assertNotIn(
            "for helper in device_identity.py geolocation.py wifi.py", self.installer
        )
        self.assertNotRegex(
            self.installer,
            r'panel/(?:geolocation|wifi)\.py[^\n]*"\$\{SIGIL_HOME\}',
        )
        self.assertRegex(
            self.installer,
            r'install -o root -g root -m 0755 \\\n'
            r'\s+"\$\{REPO_DIR\}/conf/90-sigil-geolocate" '
            r'"\$\{DISPATCHER_DIR\}/90-sigil-geolocate"',
        )

    def test_root_sudo_commands_are_enumerated(self):
        policies = self.network_sudoers + self.bluetooth_sudoers
        self.assertNotIn("(ALL)", policies)
        self.assertNotRegex(policies, r"(?m)^.*NOPASSWD: /usr/bin/pkill\s*$")
        self.assertNotRegex(policies, r"(?m)^.*NOPASSWD: /usr/bin/pactl\s*$")
        self.assertNotRegex(policies, r"(?m)^.*NOPASSWD: /usr/bin/pinctrl\s*$")
        for command in (
            "/usr/local/bin/wifi-fallback.sh --prepare-client",
            "/usr/local/bin/wifi-fallback.sh --restore-ap",
            "/usr/local/bin/wifi-fallback.sh --external-client-handoff",
            "/usr/sbin/iwlist wlan0 scan",
            "/usr/sbin/iw dev wlan0 set power_save off",
        ):
            self.assertIn(f"sigil ALL=(root) NOPASSWD: {command}", policies)

        for ownership_bypass in (
            "/usr/bin/systemctl stop hostapd",
            "/usr/bin/systemctl stop dnsmasq",
            "/usr/sbin/ip addr flush dev wlan0",
        ):
            self.assertNotIn(ownership_bypass, policies)

        for obsolete_command in (
            "/usr/bin/systemctl stop bt-connect",
            "/usr/bin/systemctl start bt-connect",
            "/usr/bin/systemctl restart bt-connect",
            "/usr/bin/systemctl reset-failed bt-connect",
            "/usr/bin/systemctl reset-failed radio-stream",
            "/usr/bin/systemctl stop radio-stream",
            "/bin/chown sigil\\:sigil /home/sigil/preferred_bt.txt",
            "/bin/chmod 644 /home/sigil/preferred_bt.txt",
        ):
            self.assertNotIn(obsolete_command, policies)

    def test_pulseaudio_sudo_rule_cannot_change_identity(self):
        self.assertNotRegex(
            self.network_sudoers,
            re.compile(r"ALL=\(root\).*?/usr/bin/(env|pactl)", re.MULTILINE),
        )


if __name__ == "__main__":
    unittest.main()
