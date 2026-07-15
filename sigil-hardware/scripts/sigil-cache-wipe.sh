#!/bin/bash
# sigil-cache-wipe.sh — Wipe music cache for SSH security maintenance mode
#
# Removes active/ and staging/ track files while preserving archive/ and
# all JSON state files. Stops audio-player if running before wipe.
#
# Usage:
#   sigil-cache-wipe.sh              # normal wipe
#   sigil-cache-wipe.sh --dry-run    # show what would be done
#   sigil-cache-wipe.sh --help       # show this message
# =============================================================================
set -euo pipefail
# shellcheck source=./scripts/sigil-cache-meta-perms.sh
. "$(dirname "${BASH_SOURCE[0]}")/sigil-cache-meta-perms.sh"

MUSIC_DIR="${SIGIL_MUSIC_DIR:-/home/sigil/music}"
ACTIVE_DIR="${MUSIC_DIR}/active/tracks"
STAGING_DIR="${MUSIC_DIR}/staging/tracks"
ARCHIVE_DIR="${MUSIC_DIR}/archive"
CACHE_META="${SIGIL_CACHE_META_FILE:-/var/lib/sigil/cache_meta.json}"
CACHE_OP_LOCK="${SIGIL_CACHE_OP_LOCK:-/run/sigil/cache-operation.lock}"

DRY_RUN=false

log() {
    local level="${1:-INFO}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help)    cat <<'EOF'
Usage: sigil-cache-wipe.sh [--dry-run]

Wipes /home/sigil/music/{active,staging}/tracks/.
Preserves archive/ and all JSON state files.

Options:
  --dry-run   Show what would be done without making changes
  --help      Show this message
EOF
                   exit 0 ;;
    esac
done

wipe_directory() {
    local dir="$1" label="$2"
    if [ ! -d "$dir" ]; then
        log "INFO" "Directory ${dir} does not exist — skipping"
        return 0
    fi
    local count
    count=$(find "$dir" -type f 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        log "INFO" "${label}: already empty"
        return 0
    fi
    log "INFO" "Wiping ${count} file(s) from ${label}"
    if $DRY_RUN; then
        log "DRY" "Would rm -f ${dir}/*"
    else
        rm -f "${dir}"/*
        log "INFO" "${label}: wiped"
    fi
}

stop_playback() {
    if systemctl is-active --quiet audio-player.service 2>/dev/null; then
        log "INFO" "Stopping audio-player.service"
        if $DRY_RUN; then
            log "DRY" "Would systemctl stop audio-player.service"
        else
            systemctl stop audio-player.service 2>/dev/null || true
        fi
    fi
    if pgrep -x mpg123 &>/dev/null; then
        log "INFO" "Killing mpg123 processes"
        if $DRY_RUN; then
            log "DRY" "Would pkill -9 mpg123"
        else
            pkill -9 mpg123 2>/dev/null || true
        fi
    fi
}

update_cache_meta() {
    log "INFO" "Resetting cache_meta.json active/staging state"
    if $DRY_RUN; then
        log "DRY" "Would reset cache_meta.json active/staging fields"
        return 0
    fi
    python3 - "$CACHE_META" <<'PYEOF'
import grp
import json
import os
import pwd
import stat
import sys
import tempfile

fp = sys.argv[1]
dirn = os.path.dirname(fp) or "."

if os.path.exists(fp):
    with open(fp, encoding="utf-8") as handle:
        doc = json.load(handle)
try:
    target_uid = pwd.getpwnam("sigil").pw_uid
    target_gid = grp.getgrnam("sigil").gr_gid
except KeyError:
    existing = os.stat(fp) if os.path.exists(fp) else None
    if existing is None:
        raise RuntimeError("canonical sigil user/group is unavailable")
    target_uid, target_gid = existing.st_uid, existing.st_gid
target_mode = 0o660
if not os.path.exists(fp):
    doc = {
        "_schema_version": "1.0",
        "cache_policy": {
            "max_ttl_days": 7,
            "auto_renew": True,
            "delete_on_expire": True,
            "preserve_on_server_unavailable": False,
        },
        "statistics": {
            "total_sync_operations": 0,
            "successful_syncs": 0,
            "failed_syncs": 0,
            "last_successful_sync": None,
            "last_failed_sync": None,
            "bytes_downloaded_total": 0,
            "bandwidth_saved_by_skipping": 0,
        },
        "expiration_warning_sent": False,
        "expiration_warning_at": None,
        "runtime": {
            "runtime_seconds": 0,
            "runtime_limit_seconds": 604800,
            "runtime_remaining_seconds": 604800,
            "last_runtime_check_uptime": 0,
        },
    }
doc["active_cache"] = {
    "playlist_id": None,
    "version_hash": None,
    "downloaded_at": None,
    "expires_at": None,
    "tracks_count": 0,
    "total_size_bytes": 0,
    "last_verified_at": None,
    "last_hash_check": None,
    "integrity_verified": False,
}
doc["staging_cache"] = {
    "playlist_id": None,
    "version_hash": None,
    "download_started_at": None,
    "progress_percent": 0,
    "tracks_downloaded": 0,
    "tracks_total": 0,
    "failed_tracks": [],
}
fd, tmp = tempfile.mkstemp(dir=dirn, suffix=".tmp")
try:
    os.fchown(fd, target_uid, target_gid)
    os.fchmod(fd, target_mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        fd = -1
        json.dump(doc, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, fp)
    tmp = ""
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_fd = os.open(dirn, flags)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except BaseException:
    if fd >= 0:
        os.close(fd)
    raise
finally:
    if tmp:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
PYEOF
    sigil_cache_meta_fix_permissions "$CACHE_META"
    log "INFO" "cache_meta.json updated"
}

# ── Main ────────────────────────────────────────────────────────────────────

# Acquire shared cache-operation lock (blocking with 30s timeout)
exec 201>"$CACHE_OP_LOCK"
if ! flock -w 30 201; then
    log "ERROR" "Could not acquire cache-operation lock — another cache op is in progress"
    exit 1
fi
cleanup() {
    flock -u 201 2>/dev/null || true
}
trap cleanup EXIT

stop_playback
wipe_directory "$ACTIVE_DIR" "active/tracks"
wipe_directory "$STAGING_DIR" "staging/tracks"
update_cache_meta

if [ -d "$ARCHIVE_DIR" ]; then
    archive_count=$(find "$ARCHIVE_DIR" -type f 2>/dev/null | wc -l)
    log "INFO" "Archive preserved: ${archive_count} file(s)"
fi

log "INFO" "Cache wipe complete"
