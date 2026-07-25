#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/sigil-empty-playlist.XXXXXX)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok() { echo "ok: $1"; PASS=$((PASS + 1)); }
not_ok() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=scripts/radio-fetcher.sh
source "$ROOT/scripts/radio-fetcher.sh"

explicit_empty='{"ok":true,"version_hash":"empty-v1","stop_playback":true,"tracks":[]}'
accidental_empty='{"ok":true,"version_hash":"empty-v1","tracks":[]}'

if validate_remote_playlist "$explicit_empty"; then
    ok "fetcher accepts explicit intentional silence"
else
    not_ok "fetcher accepts explicit intentional silence"
fi

if ! validate_remote_playlist "$accidental_empty"; then
    ok "fetcher rejects ambiguous empty playlist"
else
    not_ok "fetcher rejects ambiguous empty playlist"
fi

MUSIC_ACTIVE="$TMP/music/active"
CACHE_META_FILE="$TMP/cache_meta.json"
mkdir -p "$MUSIC_ACTIVE/tracks"
printf '%s\n' "$explicit_empty" > "$MUSIC_ACTIVE/playlist.json"
printf '%s\n' '{"active_cache":{"tracks_count":0,"total_size_bytes":0}}' > "$CACHE_META_FILE"

if validate_active >/dev/null 2>&1; then
    ok "active intentional silence validates with zero files"
else
    not_ok "active intentional silence validates with zero files"
fi

printf '%s\n' "$accidental_empty" > "$MUSIC_ACTIVE/playlist.json"
if ! validate_active >/dev/null 2>&1; then
    ok "active ambiguous empty playlist remains invalid"
else
    not_ok "active ambiguous empty playlist remains invalid"
fi

if (
    # shellcheck source=scripts/audio-manager.sh
    source "$ROOT/scripts/audio-manager.sh"
    # shellcheck disable=SC2034 # consumed by sourced logging helper
    LOG="$TMP/audio-manager.log"
    PLAYLIST_ACTIVE_FILE="$TMP/playlist.active.json"
    CACHE_META_FILE="$TMP/cache_meta.manager.json"
    printf '%s\n' "$explicit_empty" > "$PLAYLIST_ACTIVE_FILE"
    printf '%s\n' '{"active_cache":{"tracks_count":0}}' > "$CACHE_META_FILE"
    read_cache_status
    [ "$CACHE_STATUS" = "INTENTIONAL_EMPTY" ]
); then
    ok "audio manager distinguishes intentional silence from missing cache"
else
    not_ok "audio manager distinguishes intentional silence from missing cache"
fi

if (
    # shellcheck source=scripts/audio-player.sh
    source "$ROOT/scripts/audio-player.sh"
    # shellcheck disable=SC2034 # consumed by sourced logging helper
    LOG="$TMP/audio-player.log"
    PLAYLIST_ACTIVE_FILE="$TMP/player-playlist.json"
    printf '%s\n' "$explicit_empty" > "$PLAYLIST_ACTIVE_FILE"
    playlist_requests_stop
); then
    ok "audio player recognizes the stop contract"
else
    not_ok "audio player recognizes the stop contract"
fi

if (
    # shellcheck source=scripts/audio-player.sh
    source "$ROOT/scripts/audio-player.sh"
    PLAYLIST_ACTIVE_FILE="$TMP/live-player-playlist.json"
    printf '%s\n' '{"tracks":[{"id":"one","filename":"one.mp3"}]}' > "$PLAYLIST_ACTIVE_FILE"
    sleep 30 &
    MPG123_PID=$!
    owned_pid=$MPG123_PID
    (
        sleep 0.2
        printf '%s\n' "$explicit_empty" > "$PLAYLIST_ACTIVE_FILE"
    ) &
    wait_for_owned_playback || true
    playlist_requests_stop && ! kill -0 "$owned_pid" 2>/dev/null
); then
    ok "audio player stops only its owned playback process"
else
    not_ok "audio player stops only its owned playback process"
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
