#!/bin/bash
# Behavioral tests for the production playback failure functions.
# The player is sourced through its production source guard; no function logic
# is copied into this test.
# The source path is computed at runtime, globals are consumed by sourced
# functions, and the EXIT cleanup is invoked indirectly by the shell.
# shellcheck disable=SC1091,SC2034,SC2317
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLAYER_SCRIPT="${ROOT_DIR}/scripts/audio-player.sh"
TMP_DIR=$(mktemp -d /tmp/sigil-playback-remediation.XXXXXX)

cleanup_test() {
    rm -rf "$TMP_DIR"
}
trap cleanup_test EXIT

# shellcheck source=../scripts/audio-player.sh
source "$PLAYER_SCRIPT"
# audio-player.sh deliberately enables errexit for production. The test runner
# collects every assertion, so disable only errexit after sourcing.
set +e

PLAYBACK_STATE_FILE="${TMP_DIR}/playback_state.json"
LOG="${TMP_DIR}/audio-player.log"
DRY_RUN=false
STOP_REQUESTED=false
CURRENT_MODE="RADIO"
PLAYLIST_HASH="test-playlist-hash"
TRACK_INDEX=0
TRACK_ID=""
TRACK_URL=""
RADIO_FAILURES=0
RADIO_DECODER_FAILURES=0
LOCAL_DECODER_FAILURES=0

PASSED=0
FAILED=0

pass() {
    printf 'PASS: %s\n' "$1"
    PASSED=$((PASSED + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

assert_json() {
    local description="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual=$(python3 - "$PLAYBACK_STATE_FILE" "$path" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    value = json.load(state_file)
for component in sys.argv[2].split("."):
    value = value[component]
if value is None:
    print("null")
elif value is True:
    print("true")
elif value is False:
    print("false")
else:
    print(value)
PYEOF
)
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected '${expected}', got '${actual}')"
    fi
}

assert_file_content() {
    local description="$1"
    local file="$2"
    local expected="$3"
    local actual
    actual=$(cat "$file")
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description (file content changed)"
    fi
}

assert_value() {
    local description="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected '${expected}', got '${actual}')"
    fi
}

create_default_playback_state
assert_json "default RADIO decoder counter is zero" "radio.consecutive_failures" "0"
assert_json "default LOCAL decoder counter is zero" "local.consecutive_failures" "0"

# The sentinel proves production failure handling never treats cache_meta.json as
# generic playback state.
CACHE_META_FILE="${TMP_DIR}/cache_meta.json"
printf '%s\n' '{"sentinel":"must-remain-unchanged"}' > "$CACHE_META_FILE"
CACHE_META_SENTINEL=$(cat "$CACHE_META_FILE")

# First RADIO failure is persisted immediately, before FALLBACK_THRESHOLD.
TRACK_ID="radio-001"
TRACK_URL="/audio/radio-001.mp3"
record_decoder_failure "RADIO" 7 "$TRACK_ID" "$TRACK_URL" ""
assert_json "first RADIO failure increments to one" "radio.consecutive_failures" "1"
assert_json "first RADIO failure records exit code" "decoder_failure.decoder_exit_code" "7"
assert_json "first RADIO failure records track ID" "decoder_failure.failed_track_id" "radio-001"
assert_json "first RADIO failure records URL" "decoder_failure.failed_track_url" "/audio/radio-001.mp3"
assert_json "RADIO failure source is persisted" "decoder_failure.failure_source" "RADIO"
assert_json "RADIO failure records playing=false" "decoder_failure.playing" "false"

# Repeated RADIO failure increments rather than overwriting with a constant.
record_decoder_failure "RADIO" 8 "$TRACK_ID" "$TRACK_URL" ""
assert_json "repeated RADIO failure increments to two" "radio.consecutive_failures" "2"
assert_json "event exposes repeated RADIO count" "decoder_failure.consecutive_failures" "2"
assert_json "repeated RADIO failure updates exit code" "decoder_failure.decoder_exit_code" "8"

# LOCAL has an independent counter and records a local path, not a URL.
TRACK_ID="local-001"
TRACK_URL=""
record_decoder_failure "LOCAL" 9 "$TRACK_ID" "" "/music/active/tracks/local-001.mp3"
assert_json "first LOCAL failure increments to one" "local.consecutive_failures" "1"
assert_json "LOCAL failure does not reset RADIO count" "radio.consecutive_failures" "2"
assert_json "LOCAL failure records local path" "decoder_failure.failed_local_path" "/music/active/tracks/local-001.mp3"
assert_json "LOCAL failure source is persisted" "decoder_failure.failure_source" "LOCAL"

record_decoder_failure "LOCAL" 10 "$TRACK_ID" "" "/music/active/tracks/local-001.mp3"
assert_json "repeated LOCAL failure increments to two" "local.consecutive_failures" "2"
assert_json "event exposes repeated LOCAL count" "decoder_failure.consecutive_failures" "2"

# Successful playback clears only the matching source's consecutive counter.
record_playback_success "RADIO"
assert_json "RADIO success clears RADIO counter" "radio.consecutive_failures" "0"
assert_json "RADIO success leaves LOCAL counter intact" "local.consecutive_failures" "2"
assert_json "RADIO success leaves latest LOCAL event intact" "decoder_failure.failure_source" "LOCAL"

record_playback_success "LOCAL"
assert_json "LOCAL success clears LOCAL counter" "local.consecutive_failures" "0"
decoder_failure_size=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))["decoder_failure"]))' "$PLAYBACK_STATE_FILE")
if [ "$decoder_failure_size" = "0" ]; then
    pass "LOCAL success clears matching decoder failure event"
else
    fail "LOCAL success clears matching decoder failure event"
fi

# Expected SIGTERM must neither increment nor overwrite the last real failure.
TRACK_ID="radio-termination-test"
TRACK_URL="/audio/termination-test.mp3"
record_decoder_failure "RADIO" 11 "$TRACK_ID" "$TRACK_URL" ""
record_decoder_failure "RADIO" 143 "$TRACK_ID" "$TRACK_URL" ""
assert_json "SIGTERM status does not increment RADIO counter" "radio.consecutive_failures" "1"
assert_json "SIGTERM status does not overwrite real exit code" "decoder_failure.decoder_exit_code" "11"

# STOP_REQUESTED protects shutdown even if wait reports a non-143 status.
STOP_REQUESTED=true
record_decoder_failure "RADIO" 12 "$TRACK_ID" "$TRACK_URL" ""
STOP_REQUESTED=false
assert_json "requested shutdown does not increment counter" "radio.consecutive_failures" "1"
assert_json "requested shutdown does not overwrite event" "decoder_failure.decoder_exit_code" "11"

assert_file_content "decoder failures never write cache_meta.json" "$CACHE_META_FILE" "$CACHE_META_SENTINEL"

# RADIO resume uses the production cycle. Dry-run avoids network/audio while
# retaining the real cursor, playlist parsing and wrap behavior.
DRY_RUN=true
PLAYLIST_ACTIVE_FILE="${ROOT_DIR}/tests/fixtures/playlist-with-tracks.json"
PLAYLIST_HASH="sha256:abcdef123456"
SERVER_URL="http://fixture.invalid"
TRACK_INDEX=1
TRACK_ID="tr_002"
TRACK_URL="/audio/track2.mp3"
: > "$LOG"
sink_available() { return 0; }

radio_playback_cycle
first_cycle_tracks=$(grep -c 'Radio track ' "$LOG")
if grep -q 'Radio track \[1/3\]: track2.mp3' "$LOG" \
    && ! grep -q 'Radio track \[0/3\]' "$LOG"; then
    pass "RADIO restart resumes the saved second track"
else
    fail "RADIO restart resumes the saved second track"
fi
assert_value "resumed RADIO cycle plays the remaining two tracks" "$first_cycle_tracks" "2"
assert_value "completed RADIO cycle wraps cursor to zero" "$TRACK_INDEX" "0"

: > "$LOG"
radio_playback_cycle
second_cycle_tracks=$(grep -c 'Radio track ' "$LOG")
if grep -q 'Radio track \[0/3\]: track1.mp3' "$LOG"; then
    pass "next RADIO cycle starts from the first track"
else
    fail "next RADIO cycle starts from the first track"
fi
assert_value "normal RADIO loop plays every track" "$second_cycle_tracks" "3"

TRACK_INDEX=99
: > "$LOG"
radio_playback_cycle
if grep -q 'out of range; restarting at 0' "$LOG" \
    && grep -q 'Radio track \[0/3\]: track1.mp3' "$LOG"; then
    pass "out-of-range RADIO cursor safely restarts at zero"
else
    fail "out-of-range RADIO cursor safely restarts at zero"
fi

TRACK_INDEX="not-a-number"
: > "$LOG"
if radio_playback_cycle \
    && grep -q 'Radio track \[0/3\]: track1.mp3' "$LOG"; then
    pass "malformed RADIO cursor safely restarts at zero"
else
    fail "malformed RADIO cursor safely restarts at zero"
fi
DRY_RUN=false

printf '\nPlayback remediation totals: %d passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
exit 0
