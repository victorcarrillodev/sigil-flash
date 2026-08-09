#!/usr/bin/env python3
"""Small, atomic state machine for SIGIL's offline playback entitlement.

Only audio-manager mutates the normal clock.  audio-player and radio-fetcher
use ``gate`` as a read-only, fail-closed check immediately before they can make
licensed media audible or active.  The file intentionally contains no server
response, URL, token or device identifier.
"""

from __future__ import annotations

import argparse
import fcntl
import grp
import json
import os
import sys
import tempfile
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


PRODUCTION_GRACE_SECONDS = 604800
CHECKPOINT_SECONDS = 60
UNCLEAN_BOOT_RESERVE_SECONDS = 60
STATE_FILE = Path(os.environ.get("SIGIL_LICENSE_STATE_FILE", "/var/lib/sigil/license_state.json"))
BLOCK_MARKER = Path(os.environ.get("SIGIL_LICENSE_BLOCK_MARKER", "/run/sigil/license-blocked"))

PLAYABLE_PHASES = {"LICENSE_AUTHORIZED", "LICENSE_GRACE_OFFLINE"}
PENDING_PHASES = {"LICENSE_EXPIRY_PENDING_TRACK_END", "LICENSE_DENIAL_PENDING_TRACK_END"}
TERMINAL_PHASES = {"LICENSE_EXPIRED_PURGED", "LICENSE_DENIED_PURGED"}


def _share_with_sigil_group(descriptor: int) -> None:
    """Deja el candado accesible a root y al grupo ``sigil``.

    Se corrige también cuando el archivo ya existía con permisos restrictivos
    de una versión anterior: sin esto, una tarjeta ya fabricada seguiría rota
    aunque el código nuevo esté instalado. Cualquier fallo es tolerable —el
    proceso sigue teniendo su propio acceso—, así que nunca aborta.
    """
    try:
        os.fchmod(descriptor, 0o660)
    except OSError:
        return
    try:
        sigil_gid = grp.getgrnam("sigil").gr_gid
    except KeyError:
        return
    try:
        if os.fstat(descriptor).st_gid != sigil_gid:
            os.fchown(descriptor, -1, sigil_gid)
    except OSError:
        # Sin privilegios para reasignar el grupo: lo hará el proceso de root
        # que pase después. No es motivo para impedir la operación en curso.
        pass


@contextmanager
def _state_lock():
    """Serialize every state transition across service restart boundaries.

    El candado lo comparten procesos de root (firstboot, instalación) y los
    servicios de audio, que corren como el usuario ``sigil``. Con 0600 el
    primero en crearlo dejaba fuera al otro para siempre: si lo creaba root,
    audio-manager moría con PermissionError en cada arranque y systemd lo daba
    por fallido tras varios reintentos. Por eso 0660 con grupo ``sigil``, igual
    que el resto de candados de /run/sigil.
    """
    STATE_FILE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    lock_path = STATE_FILE.parent / ".license-state.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o660)
    try:
        _share_with_sigil_group(descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _boot_id() -> str:
    if os.environ.get("SIGIL_LICENSE_TEST_MODE") == "1":
        candidate = os.environ.get("SIGIL_LICENSE_TEST_BOOT_ID", "")
        if candidate and len(candidate) <= 128 and all(char.isalnum() or char in "-_" for char in candidate):
            return candidate
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    except OSError:
        return "unknown-boot"


def _uptime() -> int:
    if os.environ.get("SIGIL_LICENSE_TEST_MODE") == "1":
        candidate = os.environ.get("SIGIL_LICENSE_TEST_UPTIME_SECONDS", "")
        try:
            if candidate:
                return max(0, int(candidate))
        except ValueError:
            pass
    try:
        return max(0, int(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])))
    except (OSError, ValueError, IndexError):
        return 0


def _limit() -> int:
    """Production cannot be overridden by audio.conf or normal environment."""
    if os.environ.get("SIGIL_LICENSE_TEST_MODE") == "1":
        raw = os.environ.get("SIGIL_LICENSE_TEST_GRACE_SECONDS", "")
        try:
            value = int(raw)
            if 1 <= value <= PRODUCTION_GRACE_SECONDS:
                return value
        except ValueError:
            pass
    return PRODUCTION_GRACE_SECONDS


def _default_state() -> dict[str, Any]:
    boot = _boot_id()
    uptime = _uptime()
    return {
        "_schema_version": "1.0",
        "phase": "LICENSE_REAUTHORIZING",
        "offline_accumulated_seconds": 0,
        "grace_limit_seconds": _limit(),
        "boot_id": boot,
        "last_monotonic_checkpoint": uptime,
        "clean_shutdown": False,
        "last_successful_authorization_at": None,
        "last_successful_authorization_source": None,
        "last_authorization_result": "NEVER_AUTHORIZED",
        "last_authorization_event_id": None,
        "expiry_pending": False,
        "purge_required": False,
        "purged": False,
        "block_reason": "no_successful_authorization",
        "updated_at": _now(),
    }


def _normalise(data: dict[str, Any]) -> dict[str, Any]:
    defaults = _default_state()
    for key, value in defaults.items():
        data.setdefault(key, value)
    data["grace_limit_seconds"] = _limit()
    try:
        data["offline_accumulated_seconds"] = max(0, int(data["offline_accumulated_seconds"]))
        data["last_monotonic_checkpoint"] = max(0, int(data["last_monotonic_checkpoint"]))
    except (TypeError, ValueError):
        data["phase"] = "LICENSE_REAUTHORIZING"
        data["offline_accumulated_seconds"] = 0
        data["last_monotonic_checkpoint"] = _uptime()
        data["block_reason"] = "invalid_license_state"
    if data.get("phase") not in PLAYABLE_PHASES | PENDING_PHASES | TERMINAL_PHASES | {"LICENSE_REAUTHORIZING"}:
        data["phase"] = "LICENSE_REAUTHORIZING"
        data["block_reason"] = "invalid_license_phase"
    return data


def _load() -> tuple[dict[str, Any], bool]:
    try:
        parsed = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError("state is not an object")
        return _normalise(parsed), False
    except (OSError, ValueError, json.JSONDecodeError):
        return _default_state(), True


def _atomic_write(data: dict[str, Any]) -> None:
    STATE_FILE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    data["updated_at"] = _now()
    fd, temporary = tempfile.mkstemp(prefix=".license-state.", suffix=".tmp", dir=STATE_FILE.parent)
    try:
        # Mismo criterio que el candado: root y los servicios de audio (usuario
        # ``sigil``) escriben este archivo. Con 0600, el primero en crearlo deja
        # al otro fuera de forma permanente.
        _share_with_sigil_group(fd)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, STATE_FILE)
        try:
            with open(STATE_FILE, "r+b") as final:
                _share_with_sigil_group(final.fileno())
        except OSError:
            pass
        directory = os.open(STATE_FILE.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _effective_used(data: dict[str, Any]) -> tuple[int, bool]:
    """Return (seconds, changed_boot); wall clock is deliberately irrelevant."""
    current_boot, current_uptime = _boot_id(), _uptime()
    used = int(data["offline_accumulated_seconds"])
    checkpoint = int(data["last_monotonic_checkpoint"])
    if data.get("boot_id") != current_boot:
        # A clean shutdown committed its exact delta.  A sudden power loss may
        # hide up to one checkpoint, so debit one conservative interval once.
        if not bool(data.get("clean_shutdown")):
            used += UNCLEAN_BOOT_RESERVE_SECONDS
        used += current_uptime
        return used, True
    delta = current_uptime - checkpoint
    if delta < 0 or delta > PRODUCTION_GRACE_SECONDS * 2:
        # A malformed monotonic source is never allowed to extend entitlement.
        return int(data["grace_limit_seconds"]), False
    return used + delta, False


def _set_marker(data: dict[str, Any], effective_used: int | None = None) -> None:
    used = int(data["offline_accumulated_seconds"] if effective_used is None else effective_used)
    blocked = (
        data.get("phase") not in PLAYABLE_PHASES
        or bool(data.get("purged"))
        or bool(data.get("expiry_pending"))
        or used >= int(data["grace_limit_seconds"])
    )
    if blocked:
        BLOCK_MARKER.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".license-block.", dir=BLOCK_MARKER.parent)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, f"{data.get('phase')}\n".encode("ascii", "replace"))
            os.fsync(fd)
            os.close(fd)
            os.replace(temporary, BLOCK_MARKER)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    else:
        try:
            BLOCK_MARKER.unlink()
        except FileNotFoundError:
            pass


def _public(data: dict[str, Any], used: int | None = None) -> dict[str, Any]:
    effective = int(data["offline_accumulated_seconds"] if used is None else used)
    limit = int(data["grace_limit_seconds"])
    result = dict(data)
    result["offline_grace_used_seconds"] = min(effective, limit)
    result["offline_grace_remaining_seconds"] = max(0, limit - effective)
    result["license_authorized"] = data.get("phase") in PLAYABLE_PHASES and not data.get("purged")
    return result


def command_init(_: argparse.Namespace) -> int:
    data, invalid = _load()
    if invalid:
        _atomic_write(data)
    used, _ = _effective_used(data)
    _set_marker(data, used)
    print(json.dumps(_public(data, used), separators=(",", ":")))
    return 0


def command_tick(args: argparse.Namespace) -> int:
    data, invalid = _load()
    used, boot_changed = _effective_used(data)
    previous_phase = data["phase"]
    phase_changed = False
    if data["phase"] in PLAYABLE_PHASES and used >= int(data["grace_limit_seconds"]):
        data["phase"] = "LICENSE_EXPIRY_PENDING_TRACK_END"
        data["expiry_pending"] = True
        data["purge_required"] = False
        data["block_reason"] = "offline_grace_expired"
        data["last_authorization_result"] = "OFFLINE_GRACE_EXHAUSTED"
        phase_changed = True
    if data["phase"] == "LICENSE_AUTHORIZED" and args.transient_failure:
        data["phase"] = "LICENSE_GRACE_OFFLINE"
        data["last_authorization_result"] = args.transient_failure
        phase_changed = True
    # The fetcher emits one immutable observation per attempt.  Consume that
    # observation in the same transaction as the clock transition: otherwise
    # a crash between `tick` and a later acknowledgement replays it forever.
    event_changed = bool(args.event_id and args.event_id != data.get("last_authorization_event_id"))
    if args.event_id:
        data["last_authorization_event_id"] = args.event_id
    now_up = _uptime()
    checkpoint_due = boot_changed or (now_up - int(data["last_monotonic_checkpoint"]) >= CHECKPOINT_SECONDS)
    if invalid or checkpoint_due or phase_changed or event_changed or args.force:
        data["offline_accumulated_seconds"] = min(used, int(data["grace_limit_seconds"]))
        data["boot_id"] = _boot_id()
        data["last_monotonic_checkpoint"] = now_up
        data["clean_shutdown"] = False
        _atomic_write(data)
    _set_marker(data, used)
    print(json.dumps(_public(data, used), separators=(",", ":")))
    return 0 if data["phase"] not in PENDING_PHASES else 2


def command_authorize(args: argparse.Namespace) -> int:
    data, _ = _load()
    if data.get("purged") and not args.post_purge:
        return 3
    data.update({
        "phase": "LICENSE_AUTHORIZED",
        "offline_accumulated_seconds": 0,
        "grace_limit_seconds": _limit(),
        "boot_id": _boot_id(),
        "last_monotonic_checkpoint": _uptime(),
        "clean_shutdown": False,
        "last_successful_authorization_at": _now(),
        "last_successful_authorization_source": "authenticated_playlist",
        "last_authorization_result": "AUTHENTICATED_PLAYLIST_OK",
        "last_authorization_event_id": args.event_id,
        "expiry_pending": False,
        "purge_required": False,
        "purged": False,
        "block_reason": None,
    })
    _atomic_write(data)
    _set_marker(data, 0)
    print(json.dumps(_public(data, 0), separators=(",", ":")))
    return 0


def command_ack_event(args: argparse.Namespace) -> int:
    """Consume a server observation without treating it as authorization.

    In particular, a playlist response that arrived after expiry became pending
    must not be replayed after the destructive purge to unlock old media.
    """
    data, _ = _load()
    data["last_authorization_event_id"] = args.event_id
    data["last_authorization_result"] = args.result
    data["clean_shutdown"] = False
    _atomic_write(data)
    _set_marker(data)
    print(json.dumps(_public(data), separators=(",", ":")))
    return 0


def command_denied(args: argparse.Namespace) -> int:
    data, _ = _load()
    if data.get("phase") in TERMINAL_PHASES:
        if args.event_id:
            data["last_authorization_event_id"] = args.event_id
            data["last_authorization_result"] = args.reason
            _atomic_write(data)
        print(json.dumps(_public(data), separators=(",", ":")))
        return 0
    data.update({
        "phase": "LICENSE_DENIAL_PENDING_TRACK_END",
        "expiry_pending": True,
        "purge_required": False,
        "purged": False,
        "block_reason": args.reason,
        "last_authorization_result": args.reason,
        "last_authorization_event_id": args.event_id or data.get("last_authorization_event_id"),
        "clean_shutdown": False,
    })
    _atomic_write(data)
    _set_marker(data)
    print(json.dumps(_public(data), separators=(",", ":")))
    return 0


def command_request_purge(_: argparse.Namespace) -> int:
    data, _ = _load()
    if data.get("phase") not in PENDING_PHASES:
        return 3
    data["purge_required"] = True
    data["clean_shutdown"] = False
    _atomic_write(data)
    _set_marker(data)
    print(json.dumps(_public(data), separators=(",", ":")))
    return 0


def command_purge_complete(_: argparse.Namespace) -> int:
    data, _ = _load()
    if data.get("phase") == "LICENSE_DENIAL_PENDING_TRACK_END":
        data["phase"] = "LICENSE_DENIED_PURGED"
    else:
        data["phase"] = "LICENSE_EXPIRED_PURGED"
    data.update({"expiry_pending": False, "purge_required": False, "purged": True, "clean_shutdown": False})
    _atomic_write(data)
    _set_marker(data)
    print(json.dumps(_public(data), separators=(",", ":")))
    return 0


def command_reauthorizing(_: argparse.Namespace) -> int:
    data, _ = _load()
    if data.get("phase") not in TERMINAL_PHASES | {"LICENSE_REAUTHORIZING"}:
        return 3
    data["phase"] = "LICENSE_REAUTHORIZING"
    data["block_reason"] = "awaiting_authenticated_reauthorization"
    _atomic_write(data)
    _set_marker(data)
    print(json.dumps(_public(data), separators=(",", ":")))
    return 0


def command_gate(_: argparse.Namespace) -> int:
    data, invalid = _load()
    used, _ = _effective_used(data)
    if invalid:
        data["phase"] = "LICENSE_REAUTHORIZING"
        data["block_reason"] = "invalid_license_state"
    # `gate` is intentionally read-only.  It is on the hot playback path and
    # must never turn a denied read into a write storm.  State-changing helper
    # commands maintain the marker atomically with their persistent update.
    print(json.dumps(_public(data, used), separators=(",", ":")))
    if data.get("phase") in PLAYABLE_PHASES and not data.get("purged") and used < int(data["grace_limit_seconds"]):
        return 0
    return 2


def command_clean_shutdown(_: argparse.Namespace) -> int:
    data, _ = _load()
    used, _ = _effective_used(data)
    data["offline_accumulated_seconds"] = min(used, int(data["grace_limit_seconds"]))
    data["boot_id"] = _boot_id()
    data["last_monotonic_checkpoint"] = _uptime()
    data["clean_shutdown"] = True
    _atomic_write(data)
    _set_marker(data, used)
    print(json.dumps(_public(data, used), separators=(",", ":")))
    return 0


def command_status(_: argparse.Namespace) -> int:
    data, _ = _load()
    used, _ = _effective_used(data)
    print(json.dumps(_public(data, used), separators=(",", ":")))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init")
    tick = commands.add_parser("tick")
    tick.add_argument("--force", action="store_true")
    tick.add_argument("--transient-failure", default="")
    tick.add_argument("--event-id", default="")
    authorize = commands.add_parser("authorize")
    authorize.add_argument("--event-id", required=True)
    authorize.add_argument("--post-purge", action="store_true")
    acknowledge = commands.add_parser("ack-event")
    acknowledge.add_argument("--event-id", required=True)
    acknowledge.add_argument("--result", required=True)
    denied = commands.add_parser("denied")
    denied.add_argument("--reason", required=True)
    denied.add_argument("--event-id", default="")
    commands.add_parser("request-purge")
    commands.add_parser("purge-complete")
    commands.add_parser("reauthorizing")
    commands.add_parser("gate")
    commands.add_parser("clean-shutdown")
    commands.add_parser("status")
    args = parser.parse_args()
    handler = {
        "init": command_init,
        "tick": command_tick,
        "authorize": command_authorize,
        "ack-event": command_ack_event,
        "denied": command_denied,
        "request-purge": command_request_purge,
        "purge-complete": command_purge_complete,
        "reauthorizing": command_reauthorizing,
        "gate": command_gate,
        "clean-shutdown": command_clean_shutdown,
        "status": command_status,
    }[args.command]
    with _state_lock():
        return handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
