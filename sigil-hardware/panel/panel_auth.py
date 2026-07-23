#!/usr/bin/env python3
"""Local panel credential provisioning and Argon2id verification.

The plaintext PIN is accepted only from the protected manufacturing JSON file.
It is never accepted on argv and is erased after a verified hash is durable.
"""

from __future__ import annotations

import argparse
import grp
import json
import os
import secrets
import stat
from pathlib import Path

from argon2 import PasswordHasher, Type
from argon2.exceptions import VerificationError, VerifyMismatchError

try:  # argon2-cffi renamed this exception on older Raspberry Pi images.
    from argon2.exceptions import InvalidHashError as InvalidHash
except ImportError:
    from argon2.exceptions import InvalidHash


DEFAULT_INPUT = "/etc/sigil/manufacturing/sigil_secrets.json"
DEFAULT_OUTPUT = "/etc/sigil/secrets/panel-pin.hash"
DEFAULT_LENGTH_OUTPUT = "/etc/sigil/secrets/panel-pin.length"
MAX_SECRET_BYTES = 1024
MAX_HASH_BYTES = 1024

# Roughly 19 MiB and two passes keeps login interactive on a Pi Zero 2 W while
# retaining memory-hard password hashing. Encoded hashes carry these parameters.
PASSWORD_HASHER = PasswordHasher(
    time_cost=2,
    memory_cost=19_456,
    parallelism=1,
    hash_len=32,
    salt_len=16,
    type=Type.ID,
)


class PanelCredentialError(ValueError):
    """A safe, non-secret-bearing panel credential error."""


def validate_panel_pin(pin: object) -> str:
    if not isinstance(pin, str) or not 6 <= len(pin) <= 12 or not pin.isascii() or not pin.isdigit():
        raise PanelCredentialError("panel PIN must contain exactly 6 to 12 decimal digits")
    repeated = all(character == pin[0] for character in pin)
    ascending = pin in "12345678901234567890"
    descending = pin in "98765432109876543210"
    if repeated or ascending or descending:
        raise PanelCredentialError("panel PIN is too trivial")
    return pin


def _read_regular_nofollow(path: str, maximum: int, label: str) -> tuple[bytes, os.stat_result]:
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        raise
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise PanelCredentialError(f"{label} must be a regular non-symlink file")
    if before.st_size > maximum:
        raise PanelCredentialError(f"{label} exceeds its size limit")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise PanelCredentialError(f"{label} changed while opening")
        data = os.read(descriptor, maximum + 1)
    finally:
        os.close(descriptor)
    if len(data) > maximum:
        raise PanelCredentialError(f"{label} exceeds its size limit")
    return data, opened


def load_manufacturing_secret(
    path: str = DEFAULT_INPUT, expected_uid: int | None = None
) -> tuple[str, os.stat_result]:
    raw, opened = _read_regular_nofollow(path, MAX_SECRET_BYTES, "manufacturing secret")
    if stat.S_IMODE(opened.st_mode) != 0o600:
        raise PanelCredentialError("manufacturing secret must have mode 0600")
    if expected_uid is not None and opened.st_uid != expected_uid:
        raise PanelCredentialError("manufacturing secret has an unexpected owner")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PanelCredentialError("manufacturing secret is not valid UTF-8 JSON") from error
    if not isinstance(document, dict) or set(document) != {"_schema_version", "panel_pin"}:
        raise PanelCredentialError("manufacturing secret violates the exact schema")
    if document["_schema_version"] != "1.0":
        raise PanelCredentialError("manufacturing secret schema version must be 1.0")
    return validate_panel_pin(document["panel_pin"]), opened


def hash_panel_pin(pin: str) -> str:
    return PASSWORD_HASHER.hash(validate_panel_pin(pin))


def verify_encoded_hash(encoded_hash: str, pin: str) -> bool:
    try:
        return PASSWORD_HASHER.verify(encoded_hash, pin)
    except (InvalidHash, VerificationError, VerifyMismatchError, TypeError):
        return False


def verify_panel_pin_hash(
    path: str, pin: str, expected_uid: int = 0, expected_gid: int | None = None
) -> bool:
    try:
        raw, opened = _read_regular_nofollow(path, MAX_HASH_BYTES, "panel PIN hash")
    except (FileNotFoundError, OSError, PanelCredentialError):
        return False
    if expected_gid is None:
        try:
            expected_gid = grp.getgrnam("sigil").gr_gid
        except KeyError:
            return False
    if (
        stat.S_IMODE(opened.st_mode) != 0o640
        or opened.st_uid != expected_uid
        or opened.st_gid != expected_gid
    ):
        return False
    try:
        encoded = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        return False
    return encoded.startswith("$argon2id$") and verify_encoded_hash(encoded, pin)


def panel_hash_is_provisioned(
    path: str, expected_uid: int = 0, expected_gid: int | None = None
) -> bool:
    if expected_gid is None:
        try:
            expected_gid = grp.getgrnam("sigil").gr_gid
        except KeyError:
            return False
    try:
        _read_valid_encoded_hash(path, expected_uid, expected_gid)
    except (FileNotFoundError, OSError, PanelCredentialError):
        return False
    return True


def _read_valid_encoded_hash(path: str, expected_uid: int, expected_gid: int) -> str:
    raw, opened = _read_regular_nofollow(path, MAX_HASH_BYTES, "panel PIN hash")
    if (
        stat.S_IMODE(opened.st_mode) != 0o640
        or opened.st_uid != expected_uid
        or opened.st_gid != expected_gid
    ):
        raise PanelCredentialError("panel PIN hash ownership or mode is invalid")
    try:
        encoded = raw.decode("ascii").strip()
        if not encoded.startswith("$argon2id$"):
            raise PanelCredentialError("panel PIN hash must use Argon2id")
        PASSWORD_HASHER.check_needs_rehash(encoded)
    except (UnicodeDecodeError, InvalidHash) as error:
        raise PanelCredentialError("existing panel PIN hash is invalid") from error
    return encoded


def _sync_directory(path: str) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write_hash(path: str, encoded_hash: str, owner_uid: int, owner_gid: int) -> None:
    destination = Path(path)
    parent = str(destination.parent)
    parent_stat = os.lstat(parent)
    if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
        raise PanelCredentialError("panel secret directory must be a non-symlink directory")
    if (
        stat.S_IMODE(parent_stat.st_mode) != 0o750
        or parent_stat.st_uid != owner_uid
        or parent_stat.st_gid != owner_gid
    ):
        raise PanelCredentialError("panel secret directory ownership or mode is invalid")
    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        existing = None
    if existing is not None and (stat.S_ISLNK(existing.st_mode) or not stat.S_ISREG(existing.st_mode)):
        raise PanelCredentialError("panel PIN hash destination is unsafe")

    temporary = os.path.join(parent, f".{destination.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        payload = (encoded_hash + "\n").encode("ascii")
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fchmod(descriptor, 0o640)
        os.fchown(descriptor, owner_uid, owner_gid)
        os.fsync(descriptor)
    except Exception:
        os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    else:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
        _sync_directory(parent)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _atomic_write_pin_length(path: str, pin_length: int, owner_uid: int, owner_gid: int) -> None:
    """Persist only the PIN length; the PIN itself remains unavailable after provisioning."""
    if not 6 <= pin_length <= 12:
        raise PanelCredentialError("panel PIN length must be between 6 and 12")
    destination = Path(path)
    parent = str(destination.parent)
    parent_stat = os.lstat(parent)
    if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
        raise PanelCredentialError("panel secret directory must be a non-symlink directory")
    if (
        stat.S_IMODE(parent_stat.st_mode) != 0o750
        or parent_stat.st_uid != owner_uid
        or parent_stat.st_gid != owner_gid
    ):
        raise PanelCredentialError("panel secret directory ownership or mode is invalid")

    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        existing = None
    if existing is not None and (stat.S_ISLNK(existing.st_mode) or not stat.S_ISREG(existing.st_mode)):
        raise PanelCredentialError("panel PIN length destination is unsafe")

    temporary = os.path.join(parent, f".{destination.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        payload = f"{pin_length}\n".encode("ascii")
        os.write(descriptor, payload)
        os.fchmod(descriptor, 0o640)
        os.fchown(descriptor, owner_uid, owner_gid)
        os.fsync(descriptor)
    except Exception:
        os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    else:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
        _sync_directory(parent)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def read_panel_pin_length(
    path: str, expected_uid: int = 0, expected_gid: int | None = None
) -> int | None:
    """Return a provisioned PIN length only when its protected metadata is valid."""
    if expected_gid is None:
        try:
            expected_gid = grp.getgrnam("sigil").gr_gid
        except KeyError:
            return None
    try:
        raw, opened = _read_regular_nofollow(path, 16, "panel PIN length")
    except (FileNotFoundError, OSError, PanelCredentialError):
        return None
    if (
        stat.S_IMODE(opened.st_mode) != 0o640
        or opened.st_uid != expected_uid
        or opened.st_gid != expected_gid
    ):
        return None
    try:
        value = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        return None
    if not value.isdigit():
        return None
    pin_length = int(value)
    return pin_length if 6 <= pin_length <= 12 else None


def _erase_consumed_secret(path: str, expected: os.stat_result) -> None:
    flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            raise PanelCredentialError("manufacturing secret changed before removal")
        remaining = opened.st_size
        zeroes = b"\0" * min(4096, max(remaining, 1))
        while remaining:
            written = os.write(descriptor, zeroes[:remaining])
            remaining -= written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.unlink(path)
    _sync_directory(str(Path(path).parent))


def consume_manufacturing_secret(
    input_path: str = DEFAULT_INPUT,
    output_path: str = DEFAULT_OUTPUT,
    owner_uid: int = 0,
    owner_gid: int | None = None,
    length_output_path: str | None = None,
) -> str:
    if owner_gid is None:
        owner_gid = grp.getgrnam("sigil").gr_gid
    if length_output_path is None:
        length_output_path = str(Path(output_path).with_name("panel-pin.length"))
    try:
        pin, source_stat = load_manufacturing_secret(input_path, expected_uid=owner_uid)
    except FileNotFoundError:
        if os.path.lexists(output_path):
            _read_valid_encoded_hash(output_path, owner_uid, owner_gid)
            return "already-configured"
        return "setup-locked"

    if os.path.lexists(output_path):
        existing_hash = _read_valid_encoded_hash(output_path, owner_uid, owner_gid)
        if not verify_encoded_hash(existing_hash, pin):
            raise PanelCredentialError("existing panel PIN hash does not match manufacturing input")
    else:
        encoded_hash = hash_panel_pin(pin)
        _atomic_write_hash(output_path, encoded_hash, owner_uid, owner_gid)
        if not verify_panel_pin_hash(output_path, pin, owner_uid, owner_gid):
            raise PanelCredentialError("written panel PIN hash could not be verified")

    existing_length = read_panel_pin_length(length_output_path, owner_uid, owner_gid)
    if existing_length is not None and existing_length != len(pin):
        raise PanelCredentialError("existing panel PIN length does not match manufacturing input")
    if existing_length is None:
        _atomic_write_pin_length(length_output_path, len(pin), owner_uid, owner_gid)

    _erase_consumed_secret(input_path, source_stat)
    return "configured"


def main() -> int:
    parser = argparse.ArgumentParser(description="Consume a protected panel PIN secret")
    parser.add_argument("--input", default=DEFAULT_INPUT, help="protected secret JSON path")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="encoded hash destination")
    parser.add_argument("--length-output", default=DEFAULT_LENGTH_OUTPUT, help="non-secret PIN length destination")
    args = parser.parse_args()
    try:
        result = consume_manufacturing_secret(
            args.input, args.output, length_output_path=args.length_output
        )
    except (OSError, PanelCredentialError) as error:
        print(f"panel credential provisioning failed: {error}", file=os.sys.stderr)
        return 1
    print(f"panel credential state: {result}")
    return 0 if result != "setup-locked" else 3


if __name__ == "__main__":
    raise SystemExit(main())
