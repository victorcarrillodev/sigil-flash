"""Canonical SIGIL device identity loading and provisioning persistence.

Manufacturing identity is stored in ``/etc/sigil/device.conf``.  The runtime
``device_id`` is discovered from the permanent ``wlan0`` MAC, then Raspberry Pi
CPU serial, then machine-id, and finally the non-empty sentinel
``sigil-unknown``.  API credentials are
intentionally outside this module and are never returned or logged here.
"""

from __future__ import annotations

import argparse
import grp
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Mapping

SCHEMA_VERSION = "1.0"
DEVICE_CONF = "/etc/sigil/device.conf"
AUDIO_CONF = "/etc/sigil/audio.conf"
CPUINFO = "/proc/cpuinfo"
MACHINE_ID = "/etc/machine-id"
WLAN_ADDRESS = "/sys/class/net/wlan0/address"

_DEVICE_KEYS = {
    "serial_number": "SIGIL_SERIAL_NUMBER",
    "model": "SIGIL_MODEL",
    "model_version": "SIGIL_MODEL_VERSION",
    "batch": "SIGIL_BATCH",
}
_PROVISION_KEYS = {
    "_schema_version",
    "serial_number",
    "model",
    "model_version",
    "batch",
    "capabilities",
}
_SAFE_VALUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+:/-]{0,63}$")
_SAFE_SERIAL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_ASSIGNMENT = re.compile(
    r'^([A-Z][A-Z0-9_]*)=(?:"([^"\\]*)"|\'([^\'\\]*)\'|([^\s#]+))$'
)


class IdentityError(ValueError):
    """Raised when persisted or provisioned identity violates the contract."""


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (FileNotFoundError, OSError, UnicodeError):
        return ""


def resolve_device_id(
    cpuinfo_path: str = CPUINFO,
    machine_id_path: str = MACHINE_ID,
    wlan_address_path: str = WLAN_ADDRESS,
) -> str:
    """Resolve a non-empty runtime identifier without using manufacturing data."""
    wlan_address = _read_text(wlan_address_path).strip().lower()
    if re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", wlan_address):
        return wlan_address
    for line in _read_text(cpuinfo_path).splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() == "Serial":
            serial = value.strip()
            if serial and serial != "0000000000000000":
                return serial

    machine_id = _read_text(machine_id_path).strip()
    if machine_id:
        return machine_id[:16]
    return "sigil-unknown"


def _parse_assignments(path: str) -> dict[str, str]:
    result: dict[str, str] = {}
    text = _read_text(path)
    if not text and not Path(path).is_file():
        raise IdentityError(f"required configuration is missing: {path}")
    for number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = _ASSIGNMENT.fullmatch(line)
        if not match:
            raise IdentityError(f"invalid assignment in {path}:{number}")
        key = match.group(1)
        value = next(group for group in match.groups()[1:] if group is not None)
        if key in result:
            raise IdentityError(f"duplicate configuration field {key} in {path}")
        result[key] = value
    return result


def _validate_string(field: str, value: Any) -> str:
    if not isinstance(value, str) or not value or not _SAFE_VALUE.fullmatch(value):
        raise IdentityError(
            f"{field} must be a non-empty safe string of at most 64 characters"
        )
    if field == "serial_number" and not _SAFE_SERIAL.fullmatch(value):
        raise IdentityError("serial_number contains unsupported characters")
    return value


def validate_provision(document: Any) -> dict[str, Any]:
    """Validate and normalize strict manufacturing provision JSON."""
    if not isinstance(document, dict):
        raise IdentityError("provision root must be an object")
    unknown = set(document) - _PROVISION_KEYS
    missing = _PROVISION_KEYS - set(document)
    if unknown:
        raise IdentityError(f"unknown provision fields: {', '.join(sorted(unknown))}")
    if missing:
        raise IdentityError(f"missing provision fields: {', '.join(sorted(missing))}")
    if document["_schema_version"] != SCHEMA_VERSION:
        raise IdentityError("_schema_version must be 1.0")

    normalized: dict[str, Any] = {"_schema_version": SCHEMA_VERSION}
    for field in ("serial_number", "model", "model_version", "batch"):
        normalized[field] = _validate_string(field, document[field])

    capabilities = document["capabilities"]
    if not isinstance(capabilities, dict) or set(capabilities) != {"i2s_dac"}:
        raise IdentityError("capabilities must contain exactly i2s_dac")
    if type(capabilities["i2s_dac"]) is not bool:
        raise IdentityError("capabilities.i2s_dac must be boolean")
    normalized["capabilities"] = {"i2s_dac": capabilities["i2s_dac"]}
    return normalized


def load_provision(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as handle:
            return validate_provision(json.load(handle))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IdentityError(f"cannot read valid provision JSON: {error}") from error


def _legacy_i2s(model: str, model_version: str) -> bool:
    """Confirmed legacy mapping; never inspect ALSA or PulseAudio."""
    return (model, model_version) == ("Sigil-Streamer", "v1")


def _read_i2s(audio_conf_path: str, model: str, model_version: str) -> bool:
    try:
        assignments = _parse_assignments(audio_conf_path)
    except IdentityError:
        return _legacy_i2s(model, model_version)
    value = assignments.get("SIGIL_I2S_DAC_PRESENT")
    if value == "1":
        return True
    if value == "0":
        return False
    return _legacy_i2s(model, model_version)


def load_identity(
    device_conf_path: str = DEVICE_CONF,
    audio_conf_path: str = AUDIO_CONF,
    cpuinfo_path: str = CPUINFO,
    machine_id_path: str = MACHINE_ID,
    wlan_address_path: str = WLAN_ADDRESS,
) -> dict[str, Any]:
    """Return the complete non-secret identity contract."""
    assignments = _parse_assignments(device_conf_path)
    allowed = set(_DEVICE_KEYS.values())
    unknown = set(assignments) - allowed
    if unknown:
        raise IdentityError(f"unknown identity fields: {', '.join(sorted(unknown))}")

    identity: dict[str, Any] = {
        "device_id": resolve_device_id(cpuinfo_path, machine_id_path, wlan_address_path)
    }
    for field, key in _DEVICE_KEYS.items():
        if key not in assignments:
            legacy = " (legacy devices must be explicitly migrated)" if field == "model_version" else ""
            raise IdentityError(f"required provisioning metadata is missing: {key}{legacy}")
        identity[field] = _validate_string(field, assignments[key])
    identity["capabilities"] = {
        "i2s_dac": _read_i2s(
            audio_conf_path,
            identity["model"],
            identity["model_version"],
        )
    }
    if not identity["device_id"]:
        raise IdentityError("device_id resolution produced an empty value")
    return identity


def registration_document(identity: Mapping[str, Any]) -> dict[str, Any]:
    """Build the full initial registration body, excluding all credentials."""
    return {
        "_schema_version": SCHEMA_VERSION,
        "device_id": identity["device_id"],
        "serial_number": identity["serial_number"],
        "model": identity["model"],
        "model_version": identity["model_version"],
        "batch": identity["batch"],
        "capabilities": dict(identity["capabilities"]),
    }


def _quote(value: str) -> str:
    if '"' in value or "\\" in value or "\n" in value or "\r" in value:
        raise IdentityError("configuration value cannot be safely quoted")
    return f'"{value}"'


def _atomic_write(path: str, content: str, mode: int, uid: int, gid: int) -> None:
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o750, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".sigil-identity-", suffix=".tmp")
    try:
        os.fchmod(fd, mode)
        os.fchown(fd, uid, gid)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            fd = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = ""
        directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def persist_provision(
    provision_path: str,
    device_conf_path: str = DEVICE_CONF,
    *,
    uid: int = 0,
    gid: int | None = None,
) -> dict[str, Any]:
    """Atomically persist manufacturing identity as root:sigil mode 0640."""
    provision = load_provision(provision_path)
    if Path(device_conf_path).is_file():
        existing = _parse_assignments(device_conf_path)
        expected = {_DEVICE_KEYS[field]: provision[field] for field in _DEVICE_KEYS}
        if existing != expected:
            raise IdentityError(
                "refusing to overwrite a different persisted serial, model, model_version, or batch"
            )
    if gid is None:
        try:
            gid = grp.getgrnam("sigil").gr_gid
        except KeyError as error:
            raise IdentityError("required group does not exist: sigil") from error
    lines = [
        f'{_DEVICE_KEYS[field]}={_quote(provision[field])}'
        for field in ("serial_number", "model", "model_version", "batch")
    ]
    _atomic_write(device_conf_path, "\n".join(lines) + "\n", 0o640, uid, gid)
    return provision


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Load or persist non-secret SIGIL identity")
    parser.add_argument("--device-conf", default=DEVICE_CONF)
    parser.add_argument("--audio-conf", default=AUDIO_CONF)
    parser.add_argument("--cpuinfo", default=CPUINFO)
    parser.add_argument("--machine-id", default=MACHINE_ID)
    parser.add_argument("--field", choices=("device_id", "i2s_dac"))
    parser.add_argument("--registration", action="store_true")
    parser.add_argument("--persist-provision")
    parser.add_argument("--validate-provision")
    args = parser.parse_args(argv)
    try:
        if args.persist_provision or args.validate_provision:
            provision = (
                persist_provision(args.persist_provision, args.device_conf)
                if args.persist_provision
                else load_provision(args.validate_provision)
            )
            print("1" if provision["capabilities"]["i2s_dac"] else "0")
            return 0
        identity = load_identity(
            args.device_conf, args.audio_conf, args.cpuinfo, args.machine_id
        )
        if args.field:
            if args.field == "i2s_dac":
                print("1" if identity["capabilities"]["i2s_dac"] else "0")
            else:
                print(identity[args.field])
        else:
            document = registration_document(identity) if args.registration else identity
            print(json.dumps(document, separators=(",", ":"), sort_keys=True))
        return 0
    except IdentityError as error:
        print(f"identity error: {error}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
