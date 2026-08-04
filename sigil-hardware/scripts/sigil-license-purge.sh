#!/bin/bash
# Dedicated, idempotent licensed-media purge.  This is deliberately separate
# from sigil-cache-wipe.sh: SSH maintenance preserves archive state, whereas an
# exhausted or denied license must remove every playable generation.
set -euo pipefail

STATE_DIR="${SIGIL_STATE_DIR:-/var/lib/sigil}"
MUSIC_ROOT="${SIGIL_MUSIC_ROOT:-/home/sigil/music}"
CACHE_LOCK="${SIGIL_CACHE_OP_LOCK:-/run/sigil/cache-operation.lock}"
LICENSE_STATE_FILE="${SIGIL_LICENSE_STATE_FILE:-${STATE_DIR}/license_state.json}"
PLAYBACK_STATE_FILE="${SIGIL_PLAYBACK_STATE_FILE:-${STATE_DIR}/playback_state.json}"
CACHE_META_FILE="${SIGIL_CACHE_META_FILE:-${STATE_DIR}/cache_meta.json}"
MEDIA_SYNC_FILE="${SIGIL_MEDIA_SYNC_FILE:-${STATE_DIR}/media_sync_state.json}"
PLAYLIST_ACTIVE_FILE="${SIGIL_PLAYLIST_ACTIVE_FILE:-${STATE_DIR}/playlist.active.json}"
PLAYLIST_STAGING_FILE="${SIGIL_PLAYLIST_STAGING_FILE:-${STATE_DIR}/playlist.staging.json}"

if [ "${1:-}" = "--help" ]; then
    echo "Usage: sigil-license-purge.sh"
    exit 0
fi

mkdir -p "$(dirname "$CACHE_LOCK")"
exec 201>"$CACHE_LOCK"
if ! flock -w 2 201; then
    # The manager leaves the persistent request in place and retries; no media
    # can start while that request is present.
    exit 75
fi

python3 - "$LICENSE_STATE_FILE" "$PLAYBACK_STATE_FILE" "$MUSIC_ROOT" \
    "$CACHE_META_FILE" "$MEDIA_SYNC_FILE" "$PLAYLIST_ACTIVE_FILE" "$PLAYLIST_STAGING_FILE" <<'PYEOF'
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

(license_file, playback_file, music_root, cache_meta, media_sync,
 playlist_active, playlist_staging) = map(Path, sys.argv[1:])

def load(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

try:
    license_state = load(license_file)
except Exception:
    raise SystemExit("license state unreadable")

terminal_repair = (license_state.get("phase") in {"LICENSE_EXPIRED_PURGED", "LICENSE_DENIED_PURGED"}
                   and license_state.get("purged") is True)
if not terminal_repair and (not license_state.get("purge_required") or license_state.get("phase") not in {
    "LICENSE_EXPIRY_PENDING_TRACK_END", "LICENSE_DENIAL_PENDING_TRACK_END"
}):
    raise SystemExit("purge not requested")

# Never race a decoder.  PID identity includes start ticks, not only a reused
# PID number.  The owner (audio-player) is responsible for ending naturally.
try:
    playback = load(playback_file)
    process = playback.get("process") if playback.get("playing") else None
    if isinstance(process, dict):
        pid, ticks = process.get("pid"), process.get("start_ticks")
        if isinstance(pid, int) and isinstance(ticks, int):
            stat = Path(f"/proc/{pid}/stat")
            if stat.exists() and int(stat.read_text(encoding="ascii").split()[21]) == ticks:
                raise SystemExit("owned decoder is still active")
except FileNotFoundError:
    pass
except (ValueError, IndexError, OSError):
    # An unreadable identity is fail-closed: wait for audio-player/manager to
    # publish an idle state instead of deleting under an unknown process.
    raise SystemExit("playback identity cannot be verified")

root = music_root.resolve()
if root == Path("/") or root.name != "music":
    raise SystemExit("unsafe music root")

def fsync_dir(path: Path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def atomic_json(path: Path, document: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".sigil-license-purge.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
        fsync_dir(path.parent)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

# Remove exactly the three generation roots.  We deliberately repeat this
# even for a recorded terminal state: a prior power loss, filesystem repair or
# stale pre-expiry worker must never leave playable bytes behind merely because
# the state record says the first attempt finished.
for name in ("active", "staging", "archive"):
    target = root / name
    if target.exists() or target.is_symlink():
        if target.is_symlink() or target.resolve().parent != root:
            raise SystemExit(f"unsafe generation path: {target}")
        shutil.rmtree(target)
    target.mkdir(mode=0o750, parents=True, exist_ok=True)
    (target / "tracks").mkdir(mode=0o750, exist_ok=True)
    fsync_dir(target)

for manifest in (playlist_active, playlist_staging):
    try:
        manifest.unlink()
    except FileNotFoundError:
        pass

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
atomic_json(cache_meta, {
    "_schema_version": "1.0",
    "cache_policy": {"max_ttl_days": 7, "auto_renew": True, "preserve_on_server_unavailable": True},
    "active_cache": {"playlist_id": None, "version_hash": None, "downloaded_at": None,
                     "expires_at": None, "tracks_count": 0, "total_size_bytes": 0,
                     "last_verified_at": None, "last_hash_check": None,
                     "integrity_verified": False},
    "staging_cache": {"playlist_id": None, "version_hash": None, "download_started_at": None,
                      "progress_percent": 0, "tracks_downloaded": 0, "tracks_total": 0,
                      "failed_tracks": []},
    "statistics": {"total_sync_operations": 0, "successful_syncs": 0, "failed_syncs": 0,
                   "last_successful_sync": None, "last_failed_sync": None,
                   "bytes_downloaded_total": 0, "bandwidth_saved_by_skipping": 0},
    "expiration_warning_sent": False, "expiration_warning_at": None,
    "purged": True, "purge_reason": license_state.get("block_reason"), "purged_at": now,
})
atomic_json(media_sync, {
    "_schema_version": "1.0", "phase": "LICENSE_PURGED", "playlist_id": None,
    "generation_id": None, "validated_tracks": 0, "total_tracks": 0,
    "priority_cursor": 0, "last_error": license_state.get("block_reason"),
    "updated_at": now,
})
fsync_dir(root)
PYEOF

flock -u 201
