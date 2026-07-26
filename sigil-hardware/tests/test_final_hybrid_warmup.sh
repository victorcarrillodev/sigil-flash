#!/bin/bash
# Focused production contract for controlled stream-to-cache warm-up.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PASS=0
FAIL=0
CASE_DIR=""

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
cleanup() { [ -z "$CASE_DIR" ] || rm -rf "$CASE_DIR"; }
trap cleanup EXIT

CASE_DIR=$(mktemp -d /tmp/sigil-hybrid-warmup.XXXXXX)
mkdir -p "$CASE_DIR"/{active/tracks,staging/tracks,archive,state}

# shellcheck source=scripts/radio-fetcher.sh
source "$ROOT/scripts/radio-fetcher.sh"
set +e
DRY_RUN=false
LOG="$CASE_DIR/fetcher.log"
SERVER_URL="https://media.invalid"
PLAYLIST_ACTIVE_FILE="$CASE_DIR/state/playlist.active.json"
PLAYLIST_STAGING_FILE="$CASE_DIR/state/playlist.staging.json"
MEDIA_SYNC_FILE="$CASE_DIR/state/media_sync_state.json"
CACHE_META_FILE="$CASE_DIR/state/cache_meta.json"
MUSIC_ACTIVE="$CASE_DIR/active"
MUSIC_STAGING="$CASE_DIR/staging"
MUSIC_ARCHIVE="$CASE_DIR/archive"

printf 'verified-media' > "$CASE_DIR/source.mp3"
SOURCE_SIZE=$(stat -c%s "$CASE_DIR/source.mp3")
SOURCE_HASH=$(sha256sum "$CASE_DIR/source.mp3" | awk '{print $1}')
http_get_to_file() {
    cp "$CASE_DIR/source.mp3" "$3"
}

download_track "/media/one" "$CASE_DIR/staging/tracks/one.mp3" \
    "$SOURCE_HASH" "$SOURCE_SIZE" >/dev/null
check "verified download is atomically committed" test -f "$CASE_DIR/staging/tracks/one.mp3"
check "verified download leaves no partial file" test ! -e "$CASE_DIR/staging/tracks/one.mp3.partial"

download_track "/media/bad" "$CASE_DIR/staging/tracks/bad.mp3" \
    "$SOURCE_HASH" "$((SOURCE_SIZE + 1))" >/dev/null 2>&1
check "size mismatch never activates a media file" test ! -e "$CASE_DIR/staging/tracks/bad.mp3"
check "size mismatch removes partial media" test ! -e "$CASE_DIR/staging/tracks/bad.mp3.partial"

python3 - "$PLAYLIST_STAGING_FILE" <<'PY'
import json, sys
json.dump({
    "_schema_version": "1.0",
    "playlist_id": "pl-new",
    "version_hash": "generation-new",
    "tracks": [
        {"id": f"t{i}", "url": f"/media/{i}.mp3", "filename": f"{i}.mp3", "sha256": ""}
        for i in range(4)
    ],
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
QUEUE="$CASE_DIR/queue"
build_priority_track_queue "$PLAYLIST_STAGING_FILE" 1 "$QUEUE"
QUEUE_IDS=$(python3 - "$QUEUE" <<'PY'
import json, sys
print(",".join(json.loads(line)["id"] for line in open(sys.argv[1], encoding="utf-8")))
PY
)
check "download queue prioritizes tracks after the cursor" test "$QUEUE_IDS" = "t2,t3,t0,t1"

record_track_integrity "$PLAYLIST_STAGING_FILE" "t0" "0.mp3" \
    "$CASE_DIR/staging/tracks/one.mp3"
check "missing server integrity is persisted after local validation" \
    python3 - "$PLAYLIST_STAGING_FILE" "$SOURCE_HASH" "$SOURCE_SIZE" <<'PY'
import json, sys
track = json.load(open(sys.argv[1], encoding="utf-8"))["tracks"][0]
raise SystemExit(0 if track["sha256"] == sys.argv[2] and track["size_bytes"] == int(sys.argv[3]) else 1)
PY

rm -rf "$MUSIC_ACTIVE" "$MUSIC_STAGING"
mkdir -p "$MUSIC_ACTIVE/tracks" "$MUSIC_STAGING/tracks"
printf old > "$MUSIC_ACTIVE/tracks/old.mp3"
printf new > "$MUSIC_STAGING/tracks/new.mp3"
printf '{"tracks":[]}' > "$PLAYLIST_STAGING_FILE"
atomic_swap
check "generation promotion exposes the new active directory" test -f "$MUSIC_ACTIVE/tracks/new.mp3"
check "generation promotion archives the previous active directory" \
    bash -c 'find "$1" -type f -name old.mp3 -print -quit | grep -q .' _ "$MUSIC_ARCHIVE"

# Exercise the complete first-generation transaction with server integrity
# metadata absent. The fetcher must compute and persist local size/SHA before
# promotion, matching the currently deployed server contract.
rm -rf "$MUSIC_ACTIVE" "$MUSIC_STAGING" "$MUSIC_ARCHIVE"
mkdir -p "$MUSIC_ACTIVE/tracks" "$MUSIC_STAGING/tracks" "$MUSIC_ARCHIVE" "$CASE_DIR/run"
rm -f "$PLAYLIST_ACTIVE_FILE" "$PLAYLIST_STAGING_FILE" "$CACHE_META_FILE" "$MEDIA_SYNC_FILE"
RUN_SIGIL_DIR="$CASE_DIR/run"
CACHE_OP_LOCK="$RUN_SIGIL_DIR/cache-operation.lock"
SSH_ACTIVE_MARKER="$RUN_SIGIL_DIR/ssh-active"
LOGOUT_FETCH_MARKER="$RUN_SIGIL_DIR/logout-fetch-active"
PLAYBACK_STATE_FILE="$CASE_DIR/state/playback-priority.json"
LOCK_FILE="$CASE_DIR/fetcher.lock"
REMOTE_JSON='{"_schema_version":"1.0","playlist_id":"production-like","tracks":[{"id":"only","url":"/only.mp3","filename":"only.mp3","sha256":"","size_bytes":0}]}'
get_device_id() { printf 'TEST-DEVICE\n'; }
fetch_remote_playlist() { printf '%s\n' "$REMOTE_JSON"; }
http_get_to_file() { cp "$CASE_DIR/source.mp3" "$3"; }
exec 200>"$LOCK_FILE"
sync_cycle
check "complete sync promotes an internally verified generation" \
    test -f "$MUSIC_ACTIVE/tracks/only.mp3"
check "complete sync publishes CACHE_ONLY" \
    bash -c 'python3 -c "import json,sys; raise SystemExit(0 if json.load(open(sys.argv[1]))[\"phase\"] == \"CACHE_ONLY\" else 1)" "$1"' _ "$MEDIA_SYNC_FILE"
check "promoted manifest contains computed size and SHA-256" \
    python3 - "$PLAYLIST_ACTIVE_FILE" "$SOURCE_HASH" "$SOURCE_SIZE" <<'PY'
import json, sys
track = json.load(open(sys.argv[1], encoding="utf-8"))["tracks"][0]
raise SystemExit(0 if track["sha256"] == sys.argv[2] and track["size_bytes"] == int(sys.argv[3]) else 1)
PY

# shellcheck source=scripts/audio-player.sh
source "$ROOT/scripts/audio-player.sh"
set +e
DRY_RUN=true
LOG="$CASE_DIR/player.log"
PLAYLIST_ACTIVE_FILE="$CASE_DIR/state/no-active.json"
PLAYLIST_STAGING_FILE="$CASE_DIR/state/player-staging.json"
MEDIA_SYNC_FILE="$CASE_DIR/state/player-media.json"
MUSIC_STAGING="$CASE_DIR/player-staging"
MUSIC_ACTIVE="$CASE_DIR/player-active"
PLAYBACK_STATE_FILE="$CASE_DIR/state/playback.json"
NOW_PLAYING_FILE="$CASE_DIR/state/now-playing"
mkdir -p "$MUSIC_STAGING/tracks" "$MUSIC_ACTIVE/tracks"
cp "$CASE_DIR/source.mp3" "$MUSIC_STAGING/tracks/next.mp3"
python3 - "$PLAYLIST_STAGING_FILE" "$SOURCE_HASH" "$SOURCE_SIZE" <<'PY'
import json, sys
json.dump({
    "_schema_version": "1.0",
    "playlist_id": "warm",
    "version_hash": "warm-generation",
    "tracks": [
        {"id":"current","url":"/current.mp3","filename":"current.mp3","sha256":"0"*64,"size_bytes":10},
        {"id":"next","url":"/next.mp3","filename":"next.mp3","sha256":sys.argv[2],"size_bytes":int(sys.argv[3])},
    ],
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
printf '{"phase":"STREAM_WARMUP"}\n' > "$MEDIA_SYNC_FILE"
sink_available() { return 0; }
TRACK_INDEX=0
PLAYLIST_HASH=""
PLAYLIST_ID=""
SERVER_URL="https://media.invalid"
: > "$LOG"
radio_playback_cycle
check "current unavailable track streams during warm-up" \
    grep -q 'current.mp3 source=STREAM' "$LOG"
check "validated next track switches to staging cache only at its boundary" \
    grep -q 'next.mp3 source=STAGING_CACHE' "$LOG"

printf partial > "$MUSIC_STAGING/tracks/next.mp3.partial"
rm -f "$MUSIC_STAGING/tracks/next.mp3"
TRACK_INDEX=1
: > "$LOG"
radio_playback_cycle
check "partial next track is never selected as local media" \
    grep -q 'next.mp3 source=STREAM' "$LOG"

printf '\nHybrid warm-up: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
