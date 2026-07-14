#!/bin/bash
# audio-player.sh — Radio-first playback engine with local-cache fallback
#
# Responsibilities (architecture doc §2.2):
#   - Lee playlist.active.json (contrato de radio-fetcher) como fuente única
#   - RADIO: curl | mpg123 URL remota desde playlist.active.json
#   - LOCAL: reproduce tracks desde /home/sigil/music/active/tracks/
#   - Persiste playback_state.json atómicamente en cada cambio de track
#   - Escribe now_playing.txt para el panel web
#   - Detecta cambio de playlist en tiempo real (hash reload)
#   - Detecta fallos de reproducción y persiste eventos en playback_state.json
#   - NO descarga, NO escribe audio_mode.json, NO inicia wipe
#   - NO decide modo permanentemente (Phase 2C audio-manager owns that)
#   - TEMP_FALLBACK_ENABLED (audio.conf): compatibilidad temporal Phase 2B
#     Desactivar en Phase 2C cuando audio-manager maneje las transiciones.
#
# position_seconds: INFORMATIONAL ONLY. Mid-track resume no implementado.
#   mpg123 no expone interfaz de seek fiable. El campo se escribe como 0.
#   No agregar lógica de reanudación frágil sin validación del reproductor.
#
# Usage:
#   audio-player.sh              # normal mode
#   audio-player.sh --dry-run    # show what would be done
#   audio-player.sh --once       # single playback cycle, then exit
# =============================================================================
set -euo pipefail

# Keep production functions sourceable by focused tests without changing the
# harness working directory. Normal service execution still starts in /tmp.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd /tmp 2>/dev/null || true
fi

# --- Paths ---
LOG_DIR="/var/log/sigil"
LOG="${LOG_DIR}/audio-player.log"
LOCK_FILE="/var/lock/sigil-audio-player.lock"
AUDIO_CONF="/etc/sigil/audio.conf"
API_KEY_FILE="${SIGIL_API_KEY_FILE:-/etc/sigil/secrets/device-api-key}"
IDENTITY_HELPER="${SIGIL_IDENTITY_HELPER:-/home/sigil/device_identity.py}"
DEVICE_CONF="${SIGIL_DEVICE_CONF:-/etc/sigil/device.conf}"
AUDIO_MODE_FILE="/var/lib/sigil/audio_mode.json"
PLAYBACK_STATE_FILE="/var/lib/sigil/playback_state.json"
PLAYLIST_ACTIVE_FILE="/var/lib/sigil/playlist.active.json"
NOW_PLAYING_FILE="/home/sigil/now_playing.txt"
MUSIC_ACTIVE="/home/sigil/music/active"

# --- Config defaults (overridden by audio.conf) ---
SERVER_URL=""
API_KEY=""
AUTH_MODE="query"
FALLBACK_THRESHOLD=3
TEMP_FALLBACK_ENABLED=true
CONNECT_TIMEOUT_SECONDS=10
STREAM_PLAYBACK_TIMEOUT_SECONDS=300
AUDIO_OUTPUT_RETRY_INITIAL_SECONDS=2
AUDIO_OUTPUT_RETRY_MAX_SECONDS=30
# FUTURE: SERVER_CHECK_INTERVAL, PLAYLIST_SYNC_INTERVAL, CACHE_TTL_DAYS
# loaded from audio.conf for use by other components — declared here for shellcheck
# shellcheck disable=SC2034
SERVER_CHECK_INTERVAL=30
# shellcheck disable=SC2034
PLAYLIST_SYNC_INTERVAL=300
# shellcheck disable=SC2034
CACHE_TTL_DAYS=7
LOG_LEVEL="INFO"

# --- Authentication state (set by init_curl_auth) ---
CURL_CONFIG=""

# --- Flags ---
DRY_RUN=false
ONCE=false

# --- PulseAudio setup ---
SIGIL_UID=$(id -u sigil 2>/dev/null || echo 1000)
export XDG_RUNTIME_DIR="/run/user/${SIGIL_UID}"
export PULSE_SERVER="unix:/run/user/${SIGIL_UID}/pulse/native"
export PULSE_RUNTIME_PATH="/run/user/${SIGIL_UID}/pulse"

AUDIO_ROUTE_HELPER="${SIGIL_AUDIO_ROUTE_HELPER:-/usr/local/bin/sigil-audio-route.sh}"
if [ -r "$AUDIO_ROUTE_HELPER" ]; then
    # shellcheck source=scripts/sigil-audio-route.sh
    source "$AUDIO_ROUTE_HELPER"
else
    select_audio_route() { return 1; }
    AUDIO_ROUTE_REASON="audio_route_helper_missing"
fi

# --- Runtime state ---
MPG123_PID=""
CURRENT_MODE="RADIO"
RADIO_FAILURES=0
RADIO_DECODER_FAILURES=0
LOCAL_DECODER_FAILURES=0
TRACK_INDEX=0
TRACK_ID=""
TRACK_URL=""
PLAYLIST_HASH=""
STOP_REQUESTED=false
SINK=""
NO_AUDIO_OUTPUT_ACTIVE=false
AUDIO_OUTPUT_RETRY_SECONDS=$AUDIO_OUTPUT_RETRY_INITIAL_SECONDS

# ── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local level="${1:-INFO}"
    local msg="$2"
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "DEBUG" ]; then
        return
    fi
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    echo "$line" >> "$LOG"
    echo "$line" >&2
}

die() {
    log "ERROR" "FATAL: $*"
    exit 1
}

cleanup() {
    if [ -n "${CURL_CONFIG:-}" ] && [ -f "$CURL_CONFIG" ]; then
        rm -f "$CURL_CONFIG"
    fi
    log "DEBUG" "audio-player shutting down"
    STOP_REQUESTED=true
    kill_playback
    local children
    children=$(jobs -p 2>/dev/null || true)
    if [ -n "$children" ]; then
        # shellcheck disable=SC2086
        kill $children 2>/dev/null || true
        wait 2>/dev/null || true
    fi
    log "INFO" "audio-player stopped"
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    trap cleanup EXIT TERM INT
fi

# ── Argument parsing ────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --once)    ONCE=true ;;
            *)         die "Unknown argument: $arg" ;;
        esac
    done
fi

if $DRY_RUN; then
    log "INFO" "DRY RUN MODE — no files will be modified"
fi

# ── Config loading ──────────────────────────────────────────────────────────

init_curl_auth() {
    CURL_CONFIG=""
    [ -n "$API_KEY" ] || return 0
    CURL_CONFIG=$(mktemp /tmp/sigil-curl-config.XXXXXX)
    chmod 600 "$CURL_CONFIG"
    printf 'header = "x-api-key: %s"\n' "$API_KEY" > "$CURL_CONFIG"
}

load_config() {
    if [ ! -f "$AUDIO_CONF" ]; then
        die "Config not found: $AUDIO_CONF (run install.sh first)"
    fi
    # shellcheck source=conf/audio.conf
    source "$AUDIO_CONF"

    if [ -r "$API_KEY_FILE" ]; then
        IFS= read -r API_KEY < "$API_KEY_FILE" || true
    fi

    if [ -z "$SERVER_URL" ]; then
        die "SERVER_URL not set in $AUDIO_CONF"
    fi
    if [ -z "$API_KEY" ]; then
        log "WARN" "Device API key is not provisioned — server may reject requests"
    fi
    [ "${AUTH_MODE}" = "query" ] || die "Invalid AUTH_MODE='${AUTH_MODE}' (expected: query)"
    init_curl_auth
    log "DEBUG" "Config loaded: AUTH_MODE=${AUTH_MODE}"
}

# ── Device identity ─────────────────────────────────────────────────────────

get_device_id() {
    python3 "$IDENTITY_HELPER" --device-conf "$DEVICE_CONF" \
        --audio-conf "$AUDIO_CONF" --field device_id
}

# ── JSON helpers ────────────────────────────────────────────────────────────

read_json_field() {
    local file="$1"
    local field="$2"
    python3 - "$file" "$field" <<'PYEOF'
import json, sys

file_path  = sys.argv[1]
field_path = sys.argv[2]

try:
    with open(file_path) as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(1)

val = data
for key in field_path.split('.'):
    if not isinstance(val, dict) or key not in val:
        print("")
        sys.exit(0)
    val = val[key]

if val is True:
    print("true")
elif val is False:
    print("false")
elif val is None:
    print("null")
else:
    print(val)
PYEOF
}

write_json_file() {
    local file="$1"
    local content="$2"
    if $DRY_RUN; then
        log "DRY" "Would write: $file"
        return 0
    fi
    echo "$content" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

extract_tracks_json() {
    local file="$1"
    python3 - "$file" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if isinstance(data, list):
    tracks = data
else:
    tracks = data.get('tracks', [])
for t in tracks:
    print(json.dumps(t))
PYEOF
}

validate_playlist_filenames() {
    local file="$1"
    python3 - "$file" <<'PYEOF' || return 1
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

tracks = data if isinstance(data, list) else data.get('tracks', [])
if not tracks:
    print("ERROR: playlist has no tracks", file=sys.stderr)
    sys.exit(1)

seen = {}
errors = []
for i, t in enumerate(tracks):
    fname = t.get("filename", "") or ""
    if not fname:
        errors.append("tracks[{}]: missing filename".format(i))
        continue
    if "/" in fname or ".." in fname:
        errors.append("tracks[{}]: path traversal in filename '{}'".format(i, fname))
        continue
    if fname in seen:
        errors.append("duplicate filename '{}' at tracks[{}] and tracks[{}]".format(fname, seen[fname], i))
    seen[fname] = i

if errors:
    for e in errors:
        print("ERROR: " + e, file=sys.stderr)
    sys.exit(1)

print("OK: {} tracks, all filenames unique".format(len(tracks)))
sys.exit(0)
PYEOF
}

# ── Sink management ─────────────────────────────────────────────────────────

resolve_sink() {
    if select_audio_route; then
        SINK="$AUDIO_ROUTE_SINK"
        echo "$AUDIO_ROUTE_SINK"
        return 0
    fi
    echo "unknown"
    return 1
}

wait_for_sink() {
    local max_attempts="${1:-30}"
    local attempt=0
    while [ $attempt -lt "$max_attempts" ]; do
        local sink_name
        sink_name=$(resolve_sink || true)
        if [ "$sink_name" != "unknown" ] && [ -n "$sink_name" ]; then
            SINK="$sink_name"
            log "DEBUG" "Audio sink available: ${SINK}"
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $((attempt % 5)) -eq 0 ]; then
            log "DEBUG" "Waiting for audio sink... (attempt ${attempt}/${max_attempts})"
        fi
        sleep 2
    done
    log "WARN" "No usable audio output found after ${max_attempts} attempts"
    return 1
}

sink_available() {
    if select_audio_route; then
        SINK="$AUDIO_ROUTE_SINK"
        return 0
    fi
    SINK=""
    return 1
}

audio_output_gate() {
    if ! sink_available; then
        kill_playback
        if ! $NO_AUDIO_OUTPUT_ACTIVE; then
            log "WARN" "no_audio_output — Bluetooth A2DP and PCM5102A are unavailable"
            NO_AUDIO_OUTPUT_ACTIVE=true
        else
            log "DEBUG" "no_audio_output — retrying in ${AUDIO_OUTPUT_RETRY_SECONDS}s"
        fi
        sleep "$AUDIO_OUTPUT_RETRY_SECONDS"
        if [ "$AUDIO_OUTPUT_RETRY_SECONDS" -lt "$AUDIO_OUTPUT_RETRY_MAX_SECONDS" ]; then
            AUDIO_OUTPUT_RETRY_SECONDS=$((AUDIO_OUTPUT_RETRY_SECONDS * 2))
            if [ "$AUDIO_OUTPUT_RETRY_SECONDS" -gt "$AUDIO_OUTPUT_RETRY_MAX_SECONDS" ]; then
                AUDIO_OUTPUT_RETRY_SECONDS=$AUDIO_OUTPUT_RETRY_MAX_SECONDS
            fi
        fi
        return 1
    fi
    if $NO_AUDIO_OUTPUT_ACTIVE; then
        log "INFO" "Audio output available again: ${AUDIO_ROUTE_TYPE}/${SINK}"
    fi
    NO_AUDIO_OUTPUT_ACTIVE=false
    AUDIO_OUTPUT_RETRY_SECONDS=$AUDIO_OUTPUT_RETRY_INITIAL_SECONDS
    return 0
}

# ── State file management ───────────────────────────────────────────────────

read_playback_state() {
    if [ ! -f "$PLAYBACK_STATE_FILE" ]; then
        log "DEBUG" "playback_state.json not found, creating default"
        create_default_playback_state
        return
    fi

    local mode track_index track_id local_hash radio_decoder_failures local_decoder_failures
    mode=$(read_json_field "$PLAYBACK_STATE_FILE" "mode")
    CURRENT_MODE="${mode:-RADIO}"

    track_index=$(read_json_field "$PLAYBACK_STATE_FILE" "local.current_track_index")
    case "$track_index" in
        ''|*[!0-9]*) TRACK_INDEX=0 ;;
        *) TRACK_INDEX=$track_index ;;
    esac

    track_id=$(read_json_field "$PLAYBACK_STATE_FILE" "local.current_track_id")
    TRACK_ID="${track_id:-}"

    local_hash=$(read_json_field "$PLAYBACK_STATE_FILE" "local.playlist_hash")
    PLAYLIST_HASH="${local_hash:-}"

    radio_decoder_failures=$(read_json_field "$PLAYBACK_STATE_FILE" "radio.consecutive_failures" || true)
    local_decoder_failures=$(read_json_field "$PLAYBACK_STATE_FILE" "local.consecutive_failures" || true)
    case "$radio_decoder_failures" in ''|*[!0-9]*) radio_decoder_failures=0 ;; esac
    case "$local_decoder_failures" in ''|*[!0-9]*) local_decoder_failures=0 ;; esac
    RADIO_DECODER_FAILURES=$radio_decoder_failures
    LOCAL_DECODER_FAILURES=$local_decoder_failures
    # The fallback counter resumes from genuine persisted RADIO decoder failures.
    RADIO_FAILURES=$RADIO_DECODER_FAILURES

    log "DEBUG" "Loaded playback state: mode=${CURRENT_MODE}, track=${TRACK_INDEX}, hash=${PLAYLIST_HASH:0:12}, radio_decoder_failures=${RADIO_DECODER_FAILURES}, local_decoder_failures=${LOCAL_DECODER_FAILURES}"
}

# Atomically update playback_state.json while preserving unrelated state fields.
# action is one of: initialize, state, failure, success.
_write_playback_state() {
    local action="$1"
    local mode="${2:-$CURRENT_MODE}"
    local failure_source="${3:-}"
    local decoder_exit="${4:-}"
    local failed_track_id="${5:-}"
    local failed_track_url="${6:-}"
    local failed_local_path="${7:-}"
    local playing="${8:-false}"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if $DRY_RUN; then
        log "DRY" "Would update playback_state.json: action=${action}, mode=${mode}"
        return 0
    fi

    python3 - "$PLAYBACK_STATE_FILE" "$action" "$mode" "$now" \
        "${PLAYLIST_HASH:-}" "${TRACK_ID:-}" "${TRACK_INDEX:-0}" "${TRACK_URL:-}" \
        "$RADIO_DECODER_FAILURES" "$LOCAL_DECODER_FAILURES" "$failure_source" \
        "$decoder_exit" "$failed_track_id" "$failed_track_url" "$failed_local_path" "$playing" <<'PYEOF'
import json
import os
import sys
import tempfile

(
    out_file, action, mode, now, playlist_hash, current_track_id,
    track_index_raw, current_track_url, radio_failures_raw,
    local_failures_raw, failure_source, decoder_exit_raw,
    failed_track_id, failed_track_url, failed_local_path, playing_raw,
) = sys.argv[1:]

def nonnegative_int(value, default=0):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return default

try:
    with open(out_file, encoding="utf-8") as state_file:
        doc = json.load(state_file)
    if not isinstance(doc, dict):
        doc = {}
except (FileNotFoundError, json.JSONDecodeError, OSError):
    doc = {}

if action == "initialize":
    doc = {}

radio = doc.get("radio")
if not isinstance(radio, dict):
    radio = {}
local = doc.get("local")
if not isinstance(local, dict):
    local = {}
statistics = doc.get("statistics")
if not isinstance(statistics, dict):
    statistics = {}

radio.setdefault("last_check", None)
radio.setdefault("last_hash", None)
radio["consecutive_failures"] = nonnegative_int(radio_failures_raw)

local["playlist_hash"] = playlist_hash or None
local["current_track_index"] = nonnegative_int(track_index_raw)
local["current_track_id"] = current_track_id or None
local["current_track_url"] = current_track_url or None
local.setdefault("position_seconds", 0)
local["last_updated"] = now
local["consecutive_failures"] = nonnegative_int(local_failures_raw)

statistics.setdefault("total_plays", 0)
statistics.setdefault("mode_switches", 0)
statistics.setdefault("last_server_contact", None)

doc["_schema_version"] = "1.0"
doc["mode"] = mode
doc["playing"] = playing_raw.lower() == "true"
doc["radio"] = radio
doc["local"] = local
doc["statistics"] = statistics

if action == "failure":
    decoder_exit = nonnegative_int(decoder_exit_raw)
    consecutive = (
        radio["consecutive_failures"]
        if failure_source == "RADIO"
        else local["consecutive_failures"]
    )
    doc["playing"] = False
    doc["decoder_failure"] = {
        "last_error": f"{failure_source.lower()} decoder exited with status {decoder_exit}",
        "decoder_exit_code": decoder_exit,
        "failed_track_id": failed_track_id or None,
        "failed_track_url": failed_track_url or None,
        "failed_local_path": failed_local_path or None,
        "failure_source": failure_source,
        "consecutive_failures": consecutive,
        "failure_at": now,
        "playing": False,
    }
elif action == "success":
    prior_failure = doc.get("decoder_failure")
    if isinstance(prior_failure, dict) and prior_failure.get("failure_source") == failure_source:
        doc["decoder_failure"] = {}
    doc["playing"] = False
else:
    prior_failure = doc.get("decoder_failure")
    if not isinstance(prior_failure, dict):
        doc["decoder_failure"] = {}

directory = os.path.dirname(out_file) or "."
fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".playback-state.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as state_file:
        json.dump(doc, state_file, indent=2, ensure_ascii=False)
        state_file.write("\n")
        state_file.flush()
        os.fsync(state_file.fileno())
    os.replace(tmp_path, out_file)
    directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except BaseException:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise
PYEOF
}

create_default_playback_state() {
    RADIO_FAILURES=0
    RADIO_DECODER_FAILURES=0
    LOCAL_DECODER_FAILURES=0
    _write_playback_state "initialize" "RADIO"
}

save_playback_state() {
    local mode="${1:-$CURRENT_MODE}"
    local playing="${2:-false}"
    _write_playback_state "state" "$mode" "" "" "" "" "" "$playing"
}

record_decoder_failure() {
    local source="$1"
    local exit_code="$2"
    local failed_track_id="${3:-}"
    local failed_track_url="${4:-}"
    local failed_local_path="${5:-}"

    case "$exit_code" in ''|*[!0-9]*) return 2 ;; esac
    # A clean exit or the SIGTERM status generated by expected service shutdown
    # is not a decoder failure and must not alter persistent counters.
    if $STOP_REQUESTED || [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 143 ]; then
        return 0
    fi

    case "$source" in
        RADIO)
            RADIO_DECODER_FAILURES=$((RADIO_DECODER_FAILURES + 1))
            ;;
        LOCAL)
            LOCAL_DECODER_FAILURES=$((LOCAL_DECODER_FAILURES + 1))
            ;;
        *)
            return 2
            ;;
    esac

    _write_playback_state "failure" "$source" "$source" "$exit_code" \
        "$failed_track_id" "$failed_track_url" "$failed_local_path" false
}

record_playback_success() {
    local source="$1"
    case "$source" in
        RADIO)
            RADIO_FAILURES=0
            RADIO_DECODER_FAILURES=0
            ;;
        LOCAL)
            LOCAL_DECODER_FAILURES=0
            ;;
        *)
            return 2
            ;;
    esac
    _write_playback_state "success" "$source" "$source"
}

read_audio_mode() {
    # Phase 2B: player self-manages mode via playback_state.json.
    # Phase 2C: audio-manager will write audio_mode.json; player reads it here.
    # For now, playback_state.json is the single source of truth for player mode.
    if [ -f "$AUDIO_MODE_FILE" ]; then
        local mode
        mode=$(read_json_field "$AUDIO_MODE_FILE" "mode")
        if [ -n "$mode" ]; then
            CURRENT_MODE="$mode"
            return
        fi
    fi
    # Fallback: read from playback_state (self-managed in Phase 2B)
    local mode
    mode=$(read_json_field "$PLAYBACK_STATE_FILE" "mode" 2>/dev/null || true)
    if [ -n "$mode" ]; then
        CURRENT_MODE="$mode"
    fi
}

update_now_playing() {
    local track_id="$1"
    local filename="$2"
    local index="$3"
    local title="$4"

    if $DRY_RUN; then
        log "DRY" "Would write now_playing: ${filename} (track ${index})"
        return 0
    fi

    local content
    if [ -n "$title" ] && [ "$title" != "None" ]; then
        content="${title}"
    else
        content="${filename}"
    fi

    echo "$content" > "${NOW_PLAYING_FILE}.tmp" && mv "${NOW_PLAYING_FILE}.tmp" "$NOW_PLAYING_FILE"
}

# ── Legacy coexistence ─────────────────────────────────────────────────────

check_legacy_playback() {
    # Detect if radio-stream.sh or its mpg123 child owns the sink.
    # audio-player.service is disabled — this check prevents accidental
    # coexistence when the player is invoked manually for testing.
    #
    # Strategy: look for any mpg123 process that is NOT our own.
    local our_child=""
    if [ -n "$MPG123_PID" ]; then
        our_child="$MPG123_PID"
    fi

    local legacy_mpg123
    legacy_mpg123=$(pgrep -x mpg123 2>/dev/null | grep -v "${our_child}" | head -1 || true)

    if [ -n "$legacy_mpg123" ]; then
        if $DRY_RUN; then
            log "DRY" "Legacy mpg123 detected (PID: ${legacy_mpg123}) — would abort to avoid conflict"
            return 0
        fi
        log "WARN" "Legacy mpg123 detected (PID: ${legacy_mpg123}) — radio-stream.sh may own the sink"
        log "WARN" "Aborting to prevent concurrent playback. Stop radio-stream.sh first:"
        log "WARN" "  sudo systemctl stop radio-stream"
        return 1
    fi

    # Also check for the radio-stream service — use systemctl for accuracy
    # (pgrep -f "radio-stream.sh" matches SSH/terminal commands too)
    if systemctl is-active --quiet radio-stream.service 2>/dev/null; then
        local legacy_subshell
        legacy_subshell=true
    else
        legacy_subshell=""
    fi

    if [ -n "$legacy_subshell" ]; then
        if $DRY_RUN; then
            log "DRY" "radio-stream.sh detected (PID: ${legacy_subshell}) — would abort to avoid conflict"
            return 0
        fi
        log "WARN" "radio-stream.sh detected (PID: ${legacy_subshell}) — aborting to prevent conflict"
        log "WARN" "Stop it first: sudo systemctl stop radio-stream"
        return 1
    fi

    log "DEBUG" "No legacy playback detected"
    return 0
}

# ---- Safe track filename validation (H6) ---------------------------------
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if [ "${fname#/}" != "$fname" ]; then return 1; fi
    case "$fname" in */*|*\\*) return 1 ;; esac
    if [ "$fname" = "." ] || [ "$fname" = ".." ]; then return 1; fi
    case "$fname" in *\\.\\./*|*\\.\\.) return 1 ;; esac
    if echo "$fname" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null; then return 1; fi
    if [ "$(basename "$fname")" != "$fname" ]; then return 1; fi
    return 0
}

# ── Playback control ────────────────────────────────────────────────────────

kill_playback() {
    if [ -n "$MPG123_PID" ]; then
        if kill -0 "$MPG123_PID" 2>/dev/null; then
            log "DEBUG" "Killing mpg123 (PID: $MPG123_PID)"
            kill "$MPG123_PID" 2>/dev/null || true
            wait "$MPG123_PID" 2>/dev/null || true
        fi
        MPG123_PID=""
    fi
}

# ── Track matching on playlist change ──────────────────────────────────────

find_best_track_match() {
    local playlist_json="$1"
    local target_id="${TRACK_ID:-}"
    local target_index="${TRACK_INDEX:-0}"

    # Method 1: Find by track ID
    if [ -n "$target_id" ]; then
        local found
        found=$(python3 - "$playlist_json" "$target_id" <<'PYEOF' 2>/dev/null
import json, sys
data = json.loads(sys.argv[1])
target_id = sys.argv[2]
if isinstance(data, list): tracks = data
else: tracks = data.get('tracks', [])
for i, t in enumerate(tracks):
    if t.get('id') == target_id:
        print(i)
        sys.exit(0)
print(-1)
PYEOF
)
        if [ -n "$found" ] && [ "$found" -ge 0 ]; then
            echo "$found"
            return
        fi
    fi

    # Method 2: Find by URL (partial match from previous radio track)
    if [ -n "${TRACK_URL:-}" ]; then
        local found_url
        found_url=$(python3 - "$playlist_json" "${TRACK_URL}" <<'PYEOF' 2>/dev/null
import json, sys
data = json.loads(sys.argv[1])
target = sys.argv[2]
if isinstance(data, list): tracks = data
else: tracks = data.get('tracks', [])
for i, t in enumerate(tracks):
    if target in t.get('url', '') or target in t.get('filename', ''):
        print(i)
        sys.exit(0)
print(-1)
PYEOF
)
        if [ -n "$found_url" ] && [ "$found_url" -ge 0 ]; then
            echo "$found_url"
            return
        fi
    fi

    # Method 3: Use saved index if within bounds
    local max_index
    max_index=$(echo "$playlist_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list): tracks = data
else: tracks = data.get('tracks', [])
print(len(tracks) - 1)
" 2>/dev/null)

    if [ "$target_index" -le "$max_index" ] 2>/dev/null; then
        echo "$target_index"
        return
    fi

    # Fallback: start from 0
    echo "0"
}

# ── RADIO playback ──────────────────────────────────────────────────────────

radio_playback_cycle() {
    log "INFO" "=== RADIO playback cycle ==="

    # Ensure sink is available
    if ! sink_available; then
        log "WARN" "No audio sink — waiting in RADIO mode"
        wait_for_sink 30 || {
            log "WARN" "Sink not available after wait"
            RADIO_FAILURES=$((RADIO_FAILURES + 1))
            sleep 5
            return 1
        }
    fi

    # Read playlist from local contract (written by radio-fetcher)
    # RADIO mode does NOT fetch from the server — only radio-fetcher does.
    local playlist_json
    if [ ! -f "$PLAYLIST_ACTIVE_FILE" ]; then
        log "WARN" "playlist.active.json not found — no content to stream"
        RADIO_FAILURES=$((RADIO_FAILURES + 1))
        sleep 10
        return 1
    fi
    playlist_json=$(cat "$PLAYLIST_ACTIVE_FILE")

    local remote_hash
    remote_hash=$(echo "$playlist_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
h = data.get('version_hash', '')
if not h:
    import hashlib
    h = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
print(h)
" 2>/dev/null)

    # Detect playlist change — run continuity matching if hash differs
    if [ -n "$PLAYLIST_HASH" ] && [ -n "$remote_hash" ] && \
       [ "$remote_hash" != "$PLAYLIST_HASH" ] && [ "$remote_hash" != "null" ]; then
        log "INFO" "Playlist hash changed: ${PLAYLIST_HASH:0:12} → ${remote_hash:0:12}"
        local new_index
        new_index=$(find_best_track_match "$playlist_json")
        TRACK_INDEX=$new_index
        log "INFO" "Mapped to track index ${new_index}"
    fi
    PLAYLIST_HASH="$remote_hash"

    # Extract tracks to temp file
    local tracks_temp
    tracks_temp=$(mktemp /tmp/audio-player-radio.XXXXXX)
    extract_tracks_json "$PLAYLIST_ACTIVE_FILE" > "$tracks_temp"

    local track_count
    track_count=$(wc -l < "$tracks_temp" | tr -d ' ')

    if [ "$track_count" -eq 0 ]; then
        log "WARN" "Playlist has 0 tracks"
        rm -f "$tracks_temp"
        sleep 10
        return 1
    fi

    # A stale, malformed or out-of-range cursor must never consume the entire
    # playlist and leave RADIO in an empty retry loop.
    case "$TRACK_INDEX" in
        ''|*[!0-9]*) TRACK_INDEX=0 ;;
    esac
    if [ "$TRACK_INDEX" -ge "$track_count" ]; then
        log "WARN" "Saved RADIO track index ${TRACK_INDEX} is out of range; restarting at 0"
        TRACK_INDEX=0
    fi

    # Validate playlist-wide filename uniqueness before playback
    if ! validate_playlist_filenames "$PLAYLIST_ACTIVE_FILE"; then
        log "ERROR" "Playlist validation failed (duplicate/unsafe filenames) — rejecting"
        rm -f "$tracks_temp"
        sleep 10
        return 1
    fi

    log "INFO" "Radio playlist from active.json: ${track_count} tracks, starting at index ${TRACK_INDEX}"

    local track_num=0
    # Resume from saved track index on restart (e.g., after power loss)
    exec 3<"$tracks_temp"
    local skip=$TRACK_INDEX
    while [ "$skip" -gt 0 ] && IFS= read -r _ <&3; do
        skip=$((skip - 1))
        track_num=$((track_num + 1))
    done
    while IFS= read -r track_json <&3; do
        [ -z "$track_json" ] && continue

        if $STOP_REQUESTED; then
            log "INFO" "Stop requested, exiting RADIO cycle"
            exec 3<&-
            rm -f "$tracks_temp"
            return 0
        fi

        # Extract track metadata
        local track_id track_url track_filename track_title
        track_id=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
        track_url=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
        track_filename=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('filename',''))" 2>/dev/null)
        track_title=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)

        if [ -z "$track_filename" ]; then
            track_filename=$(basename "${track_url}")
        fi

        # H6: Validate filename before use
        if ! validate_track_filename "$track_filename"; then
            log "ERROR" "Invalid track filename in radio playlist: ${track_filename} — skipping"
            continue
        fi

        TRACK_INDEX=$track_num
        TRACK_ID="$track_id"
        TRACK_URL="$track_url"

        update_now_playing "$track_id" "$track_filename" "$track_num" "$track_title"
        save_playback_state "RADIO" true

        log "INFO" "Radio track [${track_num}/${track_count}]: ${track_filename}"

        if $DRY_RUN; then
            log "DRY" "Would curl ${SERVER_URL}${track_url} | mpg123 -"
            track_num=$((track_num + 1))
            continue
        fi

        # Build safe URL
        local safe_url
        safe_url="${track_url// /%20}"

        local stream_url="${SERVER_URL}${safe_url}"

        # Start playback: curl → mpg123 pipeline
        # Streams remote URL from playlist contract — does NOT fetch the playlist API
        if [ -n "$CURL_CONFIG" ]; then
            curl -s -L --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${STREAM_PLAYBACK_TIMEOUT_SECONDS}" \
                --config "$CURL_CONFIG" \
                "$stream_url" 2>/dev/null | mpg123 -a "${SINK}" - 2>/dev/null &
        else
            curl -s -L --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${STREAM_PLAYBACK_TIMEOUT_SECONDS}" \
                "$stream_url" 2>/dev/null | mpg123 -a "${SINK}" - 2>/dev/null &
        fi
        MPG123_PID=$!

        # Wait for this track to finish
        local exit_code=0
        wait "$MPG123_PID" 2>/dev/null || exit_code=$?
        MPG123_PID=""

        if $STOP_REQUESTED; then
            log "INFO" "Stop requested during track"
            exec 3<&-
            rm -f "$tracks_temp"
            return 0
        fi

        # Check if playback failed (non-zero exit, not SIGTERM 143)
        if [ $exit_code -ne 0 ] && [ $exit_code -ne 143 ]; then
            log "WARN" "Track playback failed (exit: ${exit_code})"
            RADIO_FAILURES=$((RADIO_FAILURES + 1))
            # Persist every genuine decoder failure immediately, including the
            # first failure, before evaluating any fallback policy.
            record_decoder_failure "RADIO" "$exit_code" "$track_id" "$stream_url" ""

            if [ "$RADIO_FAILURES" -ge "$FALLBACK_THRESHOLD" ]; then
                log "INFO" "Fallback threshold (${RADIO_FAILURES}/${FALLBACK_THRESHOLD})"
                if $TEMP_FALLBACK_ENABLED; then
                    log "INFO" "TEMP_FALLBACK_ENABLED=true — switching to LOCAL"
                    save_playback_state "LOCAL"
                    CURRENT_MODE="LOCAL"
                    exec 3<&-
                    rm -f "$tracks_temp"
                    return 2
                else
                    log "INFO" "TEMP_FALLBACK_ENABLED=false — continuing RADIO mode"
                fi
            fi
            log "INFO" "Radio failures: ${RADIO_FAILURES}/${FALLBACK_THRESHOLD}"
        elif [ $exit_code -eq 0 ]; then
            # A successful RADIO decode clears only RADIO's consecutive counter.
            record_playback_success "RADIO"
        else
            log "DEBUG" "RADIO decoder exited due to expected SIGTERM; failure state unchanged"
        fi

        track_num=$((track_num + 1))
    done

    exec 3<&-
    rm -f "$tracks_temp"

    # A completed playlist wraps to the beginning. During an interrupted track
    # the per-track state above remains intact, so a power-loss restart resumes
    # that track instead of starting from zero.
    TRACK_INDEX=0
    TRACK_ID=""
    TRACK_URL=""
    save_playback_state "RADIO"
    log "INFO" "=== RADIO cycle complete (looping) ==="
    return 0
}

# ── LOCAL playback ──────────────────────────────────────────────────────────

local_playback_cycle() {
    log "INFO" "=== LOCAL playback cycle ==="

    # Ensure sink is available
    if ! sink_available; then
        log "WARN" "No audio sink — waiting in LOCAL mode"
        wait_for_sink 30 || {
            log "WARN" "Sink not available, will retry"
            sleep 5
            return 1
        }
    fi

    # Read active playlist
    if [ ! -f "$PLAYLIST_ACTIVE_FILE" ]; then
        log "WARN" "playlist.active.json not found — no local content to play"
        sleep 10
        return 1
    fi

    local playlist_json
    playlist_json=$(cat "$PLAYLIST_ACTIVE_FILE")

    local playlist_hash
    playlist_hash=$(echo "$playlist_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
h = data.get('version_hash', '')
print(h)
" 2>/dev/null)

    # Detect playlist change
    if [ -n "$PLAYLIST_HASH" ] && [ -n "$playlist_hash" ] && \
       [ "$playlist_hash" != "$PLAYLIST_HASH" ] && [ "$playlist_hash" != "null" ]; then
        log "INFO" "Playlist hash changed: ${PLAYLIST_HASH:0:12} → ${playlist_hash:0:12}"
        local new_index
        new_index=$(find_best_track_match "$playlist_json")
        TRACK_INDEX=$new_index
        log "INFO" "Mapped to track index ${new_index}"
    fi
    PLAYLIST_HASH="$playlist_hash"

    # Extract tracks to temp
    local tracks_temp
    tracks_temp=$(mktemp /tmp/audio-player-local.XXXXXX)
    extract_tracks_json "$PLAYLIST_ACTIVE_FILE" > "$tracks_temp"

    local track_count
    track_count=$(wc -l < "$tracks_temp" | tr -d ' ')

    if [ "$track_count" -eq 0 ]; then
        log "WARN" "Local playlist has 0 tracks"
        rm -f "$tracks_temp"
        sleep 10
        return 1
    fi

    # Validate playlist-wide filename uniqueness before playback
    if ! validate_playlist_filenames "$PLAYLIST_ACTIVE_FILE"; then
        log "ERROR" "Playlist validation failed (duplicate/unsafe filenames) — rejecting"
        rm -f "$tracks_temp"
        sleep 10
        return 1
    fi

    log "INFO" "Local playlist: ${track_count} tracks, starting at index ${TRACK_INDEX}"

    # Play through tracks starting at current index
    local played=0
    while [ $played -lt "$track_count" ]; do
        if $STOP_REQUESTED; then
            log "INFO" "Stop requested, exiting LOCAL cycle"
            rm -f "$tracks_temp"
            return 0
        fi

        local idx=$(( (TRACK_INDEX + played) % track_count ))

        # Read track at line idx (0-indexed, line = idx + 1)
        local track_json
        track_json=$(sed -n "$((idx + 1))p" "$tracks_temp")

        if [ -z "$track_json" ]; then
            log "WARN" "Could not read track at index ${idx}"
            played=$((played + 1))
            continue
        fi

        local track_id track_filename track_title track_url
        track_id=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
        track_filename=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('filename',''))" 2>/dev/null)
        track_title=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)
        track_url=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)

        local track_path
        if [ -z "$track_filename" ]; then
            track_filename=$(basename "${track_url}")
        fi

        # H6: Validate filename before use
        if ! validate_track_filename "$track_filename"; then
            log "ERROR" "Invalid track filename in local playlist: ${track_filename} — skipping"
            played=$((played + 1))
            continue
        fi

        track_path="${MUSIC_ACTIVE}/tracks/${track_filename}"

        TRACK_INDEX=$idx
        TRACK_ID="$track_id"
        TRACK_URL="$track_url"

        update_now_playing "$track_id" "$track_filename" "$idx" "$track_title"
        save_playback_state "LOCAL" true

        log "INFO" "Local track [${idx}/${track_count}]: ${track_filename:-${track_url}}"

        if $DRY_RUN; then
            played=$((played + 1))
            continue
        fi

        # Check file exists
        if [ ! -f "$track_path" ]; then
            log "WARN" "Track file not found: ${track_path}"
            played=$((played + 1))
            continue
        fi

        # Play track
        mpg123 -a "${SINK}" "$track_path" 2>/dev/null &
        MPG123_PID=$!

        local exit_code=0
        wait "$MPG123_PID" 2>/dev/null || exit_code=$?
        MPG123_PID=""

        if $STOP_REQUESTED; then
            rm -f "$tracks_temp"
            return 0
        fi

        if [ $exit_code -ne 0 ] && [ $exit_code -ne 143 ]; then
            log "WARN" "Track playback failed (exit: ${exit_code}) — skipping"
            record_decoder_failure "LOCAL" "$exit_code" "$track_id" "" "$track_path"
        elif [ $exit_code -eq 0 ]; then
            # A successful LOCAL decode clears only LOCAL's consecutive counter.
            record_playback_success "LOCAL"
        else
            log "DEBUG" "LOCAL decoder exited due to expected SIGTERM; failure state unchanged"
        fi

        played=$((played + 1))

        # On each track boundary, check if playlist changed (hot reload)
        if [ -f "$PLAYLIST_ACTIVE_FILE" ]; then
            local new_hash
            new_hash=$(read_json_field "$PLAYLIST_ACTIVE_FILE" "version_hash")
            if [ -n "$new_hash" ] && [ "$new_hash" != "$PLAYLIST_HASH" ]; then
                log "INFO" "Playlist changed during playback — reloading"
                rm -f "$tracks_temp"
                return 0
            fi
        fi
    done

    rm -f "$tracks_temp"

    # Finished playlist — loop from beginning
    TRACK_INDEX=0
    save_playback_state "LOCAL"
    log "INFO" "=== LOCAL cycle complete (looping from track 0) ==="
    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    log "INFO" "audio-player starting"

    load_config
    AUDIO_OUTPUT_RETRY_SECONDS=$AUDIO_OUTPUT_RETRY_INITIAL_SECONDS

    local device_id
    device_id=$(get_device_id)
    log "INFO" "Device: ${device_id}"

    # Open lock file descriptor for the lifetime of this process
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        die "Another audio-player instance is already running (lock: ${LOCK_FILE})"
    fi
    log "DEBUG" "Lock acquired: ${LOCK_FILE}"

    # Check for legacy radio-stream.sh before starting
    if ! check_legacy_playback; then
        log "ERROR" "Legacy playback detected — audio-player cannot start"
        log "ERROR" "This player must not run concurrently with radio-stream.sh"
        log "ERROR" "See docs/ARCHITECTURE_PLAN_PHASE1.md for the migration plan"
        exit 1
    fi

    # Probe once at startup. Missing output is handled in the bounded main-loop
    # backoff below; systemd is not crashed/restarted for this condition.
    log "DEBUG" "Checking for a usable audio output..."
    wait_for_sink 1 || true

    # Load or create playback state
    read_playback_state

    log "INFO" "Initial mode from playback_state: ${CURRENT_MODE}"

    # ── Main loop ───────────────────────────────────────────────────────────
    # Phase 2B: player self-manages mode via playback_state.json.
    # Phase 2C: audio-manager writes audio_mode.json; player reads it here.
    while true; do
        if $STOP_REQUESTED; then
            log "INFO" "Stop requested"
            break
        fi

        # Re-read audio mode each cycle (Phase 2C: audio-manager writes audio_mode.json)
        read_audio_mode

        if ! audio_output_gate; then
            continue
        fi

        case "$CURRENT_MODE" in
            RADIO)
                if ! $TEMP_FALLBACK_ENABLED; then
                    log "DEBUG" "TEMP_FALLBACK_ENABLED=false — RADIO mode (manual fallback only)"
                fi
                radio_playback_cycle
                local rc=$?
                if $ONCE; then
                    log "INFO" "--once specified, exiting after RADIO cycle"
                    break
                fi
                # rc 2 means fallback triggered — loop picks up CURRENT_MODE
                if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
                    log "DEBUG" "RADIO cycle returned ${rc}, sleeping before retry"
                    sleep 5
                fi
                ;;

            LOCAL|CACHE_EXPIRED)
                if [ "$CURRENT_MODE" = "CACHE_EXPIRED" ]; then
                    log "WARN" "Playing from EXPIRED cache (TTL exceeded)"
                fi
                local_playback_cycle
                local rc=$?
                if $ONCE; then
                    log "INFO" "--once specified, exiting after LOCAL cycle"
                    break
                fi
                if [ $rc -ne 0 ]; then
                    sleep 5
                fi
                ;;

            IDLE|BLOCKED_NO_CACHE|BLOCKED_NO_SINK|BLOCKED_LEGACY|ERROR)
                if [ "$CURRENT_MODE" = "BLOCKED_NO_CACHE" ]; then
                    log "WARN" "Mode is BLOCKED_NO_CACHE — no cache available"
                elif [ "$CURRENT_MODE" = "BLOCKED_NO_SINK" ]; then
                    log "WARN" "Mode is BLOCKED_NO_SINK — no audio sink"
                elif [ "$CURRENT_MODE" = "BLOCKED_LEGACY" ]; then
                    log "WARN" "Mode is BLOCKED_LEGACY — radio-stream.sh owns sink"
                elif [ "$CURRENT_MODE" = "ERROR" ]; then
                    log "ERROR" "Mode is ERROR — manager in unexpected state"
                else
                    log "DEBUG" "Mode is IDLE — waiting for mode change"
                fi
                sleep 10
                ;;

            TRANSITIONING|TRANSITION_TO_LOCAL|TRANSITION_TO_RADIO)
                log "DEBUG" "Mode is ${CURRENT_MODE} — waiting for transition"
                sleep 5
                ;;

            *)
                log "WARN" "Unknown mode: ${CURRENT_MODE} — defaulting to RADIO"
                CURRENT_MODE="RADIO"
                ;;
        esac

        if ! $STOP_REQUESTED; then
            sleep 1
        fi
    done

    log "INFO" "audio-player main loop exited"
    cleanup
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
