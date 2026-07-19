import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "panel" / "device_identity.py"
SPEC = importlib.util.spec_from_file_location("device_identity", MODULE_PATH)
identity = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(identity)


class DeviceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.provision = root / "provision.json"
        self.device_conf = root / "device.conf"
        self.audio_conf = root / "audio.conf"
        self.cpuinfo = root / "cpuinfo"
        self.machine_id = root / "machine-id"
        self.wlan_address = root / "wlan-address"
        self.document = {
            "_schema_version": "1.0",
            "serial_number": "SIGIL-TEST-0001",
            "model": "Sigil-Streamer",
            "model_version": "v1",
            "batch": "2026-TEST",
            "capabilities": {"i2s_dac": True},
        }
        self.provision.write_text(json.dumps(self.document), encoding="utf-8")
        self.audio_conf.write_text("SIGIL_I2S_DAC_PRESENT=1\n", encoding="utf-8")
        self.cpuinfo.write_text("Model: Test\nSerial : 1234abcd\n", encoding="utf-8")
        self.machine_id.write_text("machine-test-id\n", encoding="utf-8")

    def tearDown(self):
        self.directory.cleanup()

    def persist(self):
        return identity.persist_provision(
            str(self.provision),
            str(self.device_conf),
            uid=os.getuid(),
            gid=os.getgid(),
        )

    def load(self):
        return identity.load_identity(
            str(self.device_conf),
            str(self.audio_conf),
            str(self.cpuinfo),
            str(self.machine_id),
            str(self.wlan_address),
        )

    def test_device_conf_is_atomic_contract_with_mode_0640(self):
        self.persist()
        self.assertEqual(
            self.device_conf.read_text(encoding="utf-8"),
            'SIGIL_SERIAL_NUMBER="SIGIL-TEST-0001"\n'
            'SIGIL_MODEL="Sigil-Streamer"\n'
            'SIGIL_MODEL_VERSION="v1"\n'
            'SIGIL_BATCH="2026-TEST"\n',
        )
        self.assertEqual(stat.S_IMODE(self.device_conf.stat().st_mode), 0o640)
        self.assertEqual(self.device_conf.stat().st_uid, os.getuid())
        self.assertEqual(self.device_conf.stat().st_gid, os.getgid())

    def test_cpu_serial_and_provision_produce_complete_identity(self):
        self.persist()
        actual = self.load()
        self.assertEqual(actual["device_id"], "1234abcd")
        self.assertEqual(actual["serial_number"], "SIGIL-TEST-0001")
        self.assertEqual(actual["model_version"], "v1")
        self.assertEqual(actual["capabilities"], {"i2s_dac": True})

    def test_permanent_wlan_mac_is_preferred_for_device_identity(self):
        self.wlan_address.write_text("D8:3A:DD:71:1C:13\n", encoding="utf-8")
        self.persist()
        self.assertEqual(self.load()["device_id"], "d8:3a:dd:71:1c:13")

    def test_empty_machine_id_never_returns_empty_device_id(self):
        self.cpuinfo.write_text("Serial : 0000000000000000\n", encoding="utf-8")
        self.machine_id.write_text("\n", encoding="utf-8")
        self.assertEqual(
            identity.resolve_device_id(str(self.cpuinfo), str(self.machine_id)),
            "sigil-unknown",
        )

    def test_missing_model_version_is_rejected(self):
        del self.document["model_version"]
        self.provision.write_text(json.dumps(self.document), encoding="utf-8")
        with self.assertRaisesRegex(identity.IdentityError, "missing provision fields"):
            self.persist()

    def test_string_true_capability_is_rejected(self):
        self.document["capabilities"]["i2s_dac"] = "true"
        self.provision.write_text(json.dumps(self.document), encoding="utf-8")
        with self.assertRaisesRegex(identity.IdentityError, "must be boolean"):
            self.persist()

    def test_registration_document_has_full_identity_and_no_token(self):
        self.persist()
        document = identity.registration_document(self.load())
        self.assertEqual(document["_schema_version"], "1.0")
        self.assertEqual(set(document), {
            "_schema_version", "device_id", "serial_number", "model",
            "model_version", "batch", "capabilities",
        })
        self.assertNotIn("token", json.dumps(document).lower())


if __name__ == "__main__":
    unittest.main()
