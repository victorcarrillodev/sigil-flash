#!/bin/bash
# audio-manager.sh — Audio mode orchestration for Sigil
# Phase 2C — sole owner of mode transitions, coordination, state interpretation
#
# Responsibilities:
#   - Evaluate desired vs. current audio mode every cycle
#   - Write audio_mode.json atomically for audio-player to consume
#   - Detect internet availability (direct check, not via player)
#   - Read cache_meta.json for cache health
#   - Detect audio sink availability
#   - Detect legacy radio-stream.sh coexistence
#   - Track playlist version changes
#   - Implement recovery timer for LOCAL→RADIO transitions
#
# Does NOT:
#   - Play audio (delegated to audio-player)
#   - Download tracks (delegated to radio-fetcher)
#   - Parse backend playlist API (delegated to radio-fetcher)
#   - Pair/reconnect Bluetooth (delegated to bt-connect)
#   - Modify playlist files, delete cache, register device, control WiFi
#   - Touch Flask/panel
#
# Usage:
#   audio-manager.sh              # normal mode
#   audio-manager.sh --dry-run    # show what would be done
#   audio-manager.sh --once       # single evaluation cycle, then exit
# =============================================================================
set -euo pipefail

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd /tmp 2>/dev/null || true
fi

# --- Paths ---
LOG_DIR="/var/log/sigil"
LOG="${LOG_DIR}/audio-manager.log"
LOCK_FILE="/var/lock/sigil-audio-manager.lock"
AUDIO_CONF="/etc/sigil/audio.conf"
API_KEY_FILE="${SIGIL_API_KEY_FILE:-/etc/sigil/secrets/device-api-key}"
AUDIO_MODE_FILE="/var/lib/sigil/audio_mode.json"
CACHE_META_FILE="/var/lib/sigil/cache_meta.json"
PLAYLIST_ACTIVE_FILE="/var/lib/sigil/playlist.active.json"

# --- Config defaults (overridden by audio.conf) ---
SERVER_URL=""
API_KEY=""
AUTH_MODE="query"
PLAYBACK_MODE="radio-first"
# shellcheck disable=SC2034 # loaded from audio.conf for other services
FALLBACK_THRESHOLD=3
# shellcheck disable=SC2034 # loaded from audio.conf for other services
PLAYLIST_SYNC_INTERVAL=300
# shellcheck disable=SC2034 # loaded from audio.conf for other services
CACHE_TTL_DAYS=7
SERVER_CHECK_INTERVAL=30
AUTO_RETURN_TO_RADIO=true
RECOVERY_INTERVAL_MINUTES=30
LOG_LEVEL="INFO"
# shellcheck disable=SC2034
TEMP_FALLBACK_ENABLED=false
CONNECT_TIMEOUT_SECONDS=10
HEALTHCHECK_TIMEOUT_SECONDS=10

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
CURRENT_MODE="RADIO"
CURRENT_DESIRED="RADIO"
INTERNET_AVAILABLE=false
CACHE_STATUS="UNKNOWN"
SINK_AVAILABLE=false
AUDIO_OUTPUT_TYPE=""
AUDIO_OUTPUT_SINK=""
LEGACY_ACTIVE=false
ACTIVE_PLAYLIST_VERSION=""
LAST_TRANSITION_AT=""
TRANSITION_COUNT=0
LAST_ERROR=""
# shellcheck disable=SC2034 # set for state tracking, available for debugging
MODE_SINCE=""
INTERNET_RESTORED_AT=""
INTERNET_RESTORE_CHECKED=false
LAST_INTERNET_CHECK_EPOCH=0
RECOVERY_ELIGIBLE=false
# shellcheck disable=SC2034 # set for state tracking, available for debugging
CURRENT_REASON="startup"
STOP_REQUESTED=false

# Runtime-based cache expiration
RUNTIME_SECONDS=0
RUNTIME_LIMIT_SECONDS=604800
RUNTIME_REMAINING_SECONDS=604800
LAST_RUNTIME_CHECK_UPTIME=0
RUNTIME_EXPIRED_HANDLED=false

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
    log "DEBUG" "audio-manager shutting down"
    STOP_REQUESTED=true
    local children
    children=$(jobs -p 2>/dev/null || true)
    if [ -n "$children" ]; then
        # shellcheck disable=SC2086
        kill $children 2>/dev/null || true
        wait 2>/dev/null || true
    fi
    log "INFO" "audio-manager stopped"
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    trap cleanup EXIT TERM INT
fi

# ── Argument parsing ────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --once)    ONCE=true ;;
        *)         die "Unknown argument: $arg" ;;
    esac
done

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
        log "WARN" "Device API key is not provisioned — server health checks may fail"
    fi
    [ "${AUTH_MODE}" = "query" ] || die "Invalid AUTH_MODE='${AUTH_MODE}' (expected: query)"
    init_curl_auth

    # Phase 2C invariant: TEMP_FALLBACK_ENABLED must be false
    if [ "$TEMP_FALLBACK_ENABLED" = "true" ]; then
        log "WARN" "TEMP_FALLBACK_ENABLED=true in config — must be false for Phase 2C"
        log "WARN" "audio-manager will operate but player may self-manage mode"
    fi

    log "DEBUG" "Config loaded: AUTH_MODE=${AUTH_MODE}"
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

write_audio_mode() {
    local mode="$1"
    local desired="$2"
    local reason="$3"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local internet_str="false"
    if $INTERNET_AVAILABLE; then internet_str="true"; fi

    local pv="${ACTIVE_PLAYLIST_VERSION:-}"
    local le="${LAST_ERROR:-}"
    local lta="${LAST_TRANSITION_AT:-}"

    if $DRY_RUN; then
        log "DRY" "Would write audio_mode.json: mode=${mode}, desired=${desired}, reason=${reason}"
        return 0
    fi

    # Build JSON safely via Python — values passed as argv, never interpolated.
    python3 - "$AUDIO_MODE_FILE" "$mode" "$desired" "$reason" "$now" \
        "$internet_str" "$CACHE_STATUS" "$pv" "$le" "$lta" "$TRANSITION_COUNT" <<'PYEOF'
import json, os, sys, tempfile

out_file      = sys.argv[1]
mode          = sys.argv[2]
desired       = sys.argv[3]
reason        = sys.argv[4]
now           = sys.argv[5]
internet_str  = sys.argv[6]
cache_status  = sys.argv[7]
pv            = sys.argv[8]  # may be empty → null
le            = sys.argv[9]  # may be empty → null
lta           = sys.argv[10] # may be empty → null
transition_count = int(sys.argv[11]) if sys.argv[11].isdigit() else 0

doc = {
    "_schema_version": "1.0",
    "mode": mode,
    "desired_mode": desired,
    "reason": reason,
    "since": now,
    "internet_available": (internet_str == "true"),
    "cache_status": cache_status,
    "active_playlist_version": pv if pv else None,
    "last_transition_at": lta if lta else None,
    "transition_count": transition_count,
    "last_error": le if le else None,
}

dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    log "INFO" "audio_mode.json: ${mode} (desired: ${desired}, reason: ${reason}, internet: ${internet_str}, cache: ${CACHE_STATUS})"
}

# ── Internet check ──────────────────────────────────────────────────────────

check_internet() {
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$(( now_epoch - LAST_INTERNET_CHECK_EPOCH ))

    # Rate-limit: only check every SERVER_CHECK_INTERVAL seconds
    if [ $elapsed -lt "$SERVER_CHECK_INTERVAL" ] && [ "$LAST_INTERNET_CHECK_EPOCH" -gt 0 ]; then
        return
    fi

    LAST_INTERNET_CHECK_EPOCH="$now_epoch"

    # Method: HEAD against SERVER_URL with short timeout
    # Using GET instead of HEAD because some servers reject HEAD
    local health_url="${SERVER_URL}/api/health"
    local health_rc
    if [ -n "$CURL_CONFIG" ]; then
        curl -s -o /dev/null --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${HEALTHCHECK_TIMEOUT_SECONDS}" \
            --config "$CURL_CONFIG" \
            "$health_url" 2>/dev/null; health_rc=$?
    else
        curl -s -o /dev/null --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${HEALTHCHECK_TIMEOUT_SECONDS}" \
            "$health_url" 2>/dev/null; health_rc=$?
    fi
    if [ "$health_rc" -eq 0 ]; then
        if ! $INTERNET_AVAILABLE; then
            log "INFO" "Internet restored — server reachable"
            INTERNET_RESTORED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            INTERNET_RESTORE_CHECKED=false
        fi
        INTERNET_AVAILABLE=true
        log "DEBUG" "Internet check: OK"
    else
        if $INTERNET_AVAILABLE; then
            log "WARN" "Internet lost — server unreachable"
        fi
        INTERNET_AVAILABLE=false
        log "DEBUG" "Internet check: FAIL"
    fi
}

# ── Cache status ────────────────────────────────────────────────────────────

read_cache_status() {
    # Runtime-based expiration check (highest priority)
    if [ "$RUNTIME_SECONDS" -ge "$RUNTIME_LIMIT_SECONDS" ] && [ "$RUNTIME_LIMIT_SECONDS" -gt 0 ]; then
        CACHE_STATUS="RUNTIME_EXPIRED"
        log "DEBUG" "Cache status: RUNTIME_EXPIRED (${RUNTIME_SECONDS}s >= ${RUNTIME_LIMIT_SECONDS}s)"
        return
    fi

    if [ ! -f "$CACHE_META_FILE" ]; then
        CACHE_STATUS="EMPTY"
        log "DEBUG" "Cache status: EMPTY (no cache_meta.json)"
        return
    fi

    local tracks_count expires_at
    tracks_count=$(read_json_field "$CACHE_META_FILE" "active_cache.tracks_count")
    expires_at=$(read_json_field "$CACHE_META_FILE" "active_cache.expires_at")

    if [ -z "$tracks_count" ] || [ "$tracks_count" = "" ] || [ "$tracks_count" = "0" ]; then
        CACHE_STATUS="EMPTY"
        log "DEBUG" "Cache status: EMPTY (tracks_count=${tracks_count:-0})"
        return
    fi

    if [ -n "$expires_at" ] && [ "$expires_at" != "" ] && [ "$expires_at" != "null" ]; then
        local now_epoch expires_epoch
        now_epoch=$(date +%s)
        expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo "0")
        if [ "$expires_epoch" -gt 0 ] && [ "$now_epoch" -gt "$expires_epoch" ]; then
            CACHE_STATUS="EXPIRED"
            log "DEBUG" "Cache status: EXPIRED (expired at ${expires_at})"
            return
        fi
    fi

    CACHE_STATUS="COMPLETE"
    log "DEBUG" "Cache status: COMPLETE (${tracks_count} tracks)"
}

# ── Sink check ──────────────────────────────────────────────────────────────

check_sink() {
    if select_audio_route; then
        if ! $SINK_AVAILABLE; then
            log "INFO" "Usable audio output detected: ${AUDIO_ROUTE_TYPE}/${AUDIO_ROUTE_SINK}"
        fi
        SINK_AVAILABLE=true
        AUDIO_OUTPUT_TYPE="$AUDIO_ROUTE_TYPE"
        AUDIO_OUTPUT_SINK="$AUDIO_ROUTE_SINK"
    else
        if $SINK_AVAILABLE; then
            log "WARN" "Usable audio output lost"
        fi
        SINK_AVAILABLE=false
        AUDIO_OUTPUT_TYPE=""
        AUDIO_OUTPUT_SINK=""
    fi
    log "DEBUG" "Output check: usable=${SINK_AVAILABLE}, type=${AUDIO_OUTPUT_TYPE:-none}, sink=${AUDIO_OUTPUT_SINK:-none}"
}

# ── Legacy coexistence ──────────────────────────────────────────────────────

check_legacy() {
    local legacy_mpg123
    legacy_mpg123=$(pgrep -x mpg123 2>/dev/null | head -1 || true)

    local legacy_subshell
    # Use systemctl for accuracy — pgrep -f "radio-stream.sh" matches SSH/terminal commands
    if systemctl is-active --quiet radio-stream.service 2>/dev/null; then
        legacy_subshell="active"
    else
        legacy_subshell=""
    fi

    if [ -n "$legacy_mpg123" ] || [ -n "$legacy_subshell" ]; then
        if ! $LEGACY_ACTIVE; then
            log "WARN" "Legacy playback detected (mpg123: ${legacy_mpg123:--}, radio-stream.sh: ${legacy_subshell:--})"
            log "WARN" "MIGRATION_BLOCKED_BY_LEGACY — audio-mode set to BLOCKED_LEGACY"
        fi
        LEGACY_ACTIVE=true
    else
        if $LEGACY_ACTIVE; then
            log "INFO" "Legacy playback no longer detected — sink may be free"
        fi
        LEGACY_ACTIVE=false
    fi
    log "DEBUG" "Legacy check: ${LEGACY_ACTIVE}"
}

# ── Playlist version ────────────────────────────────────────────────────────

read_playlist_version() {
    if [ ! -f "$PLAYLIST_ACTIVE_FILE" ]; then
        ACTIVE_PLAYLIST_VERSION=""
        return
    fi
    local hash
    hash=$(read_json_field "$PLAYLIST_ACTIVE_FILE" "version_hash")
    ACTIVE_PLAYLIST_VERSION="${hash:-}"
}

# ── Runtime-based cache expiration ───────────────────────────────────────────

load_runtime_state() {
    if [ ! -f "$CACHE_META_FILE" ]; then
        log "DEBUG" "Runtime: no cache_meta.json — using defaults"
        return
    fi
    local rs rl rr lru eh
    rs=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_seconds")
    rl=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_limit_seconds")
    rr=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_remaining_seconds")
    lru=$(read_json_field "$CACHE_META_FILE" "runtime.last_runtime_check_uptime")
    eh=$(read_json_field "$CACHE_META_FILE" "runtime.expired_handled_uptime")
    RUNTIME_SECONDS="${rs:-$RUNTIME_SECONDS}"
    RUNTIME_LIMIT_SECONDS="${rl:-$RUNTIME_LIMIT_SECONDS}"
    RUNTIME_REMAINING_SECONDS="${rr:-$RUNTIME_REMAINING_SECONDS}"
    LAST_RUNTIME_CHECK_UPTIME="${lru:-$LAST_RUNTIME_CHECK_UPTIME}"
    if [ "${eh:-0}" -gt 0 ] && [ "$RUNTIME_SECONDS" -ge "$RUNTIME_LIMIT_SECONDS" ]; then
        RUNTIME_EXPIRED_HANDLED=true
    fi
    log "DEBUG" "Runtime state: ${RUNTIME_SECONDS}/${RUNTIME_LIMIT_SECONDS}s used, ${RUNTIME_REMAINING_SECONDS}s remaining"
}

_write_runtime_state() {
    if $DRY_RUN; then
        return
    fi
    exec 201>"$CACHE_OP_LOCK"
    if ! flock -w 30 201; then
        log "ERROR" "Could not acquire cache-operation lock for runtime write — another op in progress"
        return 1
    fi
    python3 - "$CACHE_META_FILE" \
        "$RUNTIME_SECONDS" "$RUNTIME_LIMIT_SECONDS" \
        "$RUNTIME_REMAINING_SECONDS" "$LAST_RUNTIME_CHECK_UPTIME" <<'PYEOF'
import json, os, sys, tempfile

file_path  = sys.argv[1]
rt_sec     = int(sys.argv[2])
rt_limit   = int(sys.argv[3])
rt_rem     = int(sys.argv[4])
last_up    = int(float(sys.argv[5]))

with open(file_path) as f:
    data = json.load(f)

data.setdefault("runtime", {})
data["runtime"]["runtime_seconds"]          = rt_sec
data["runtime"]["runtime_limit_seconds"]    = rt_limit
data["runtime"]["runtime_remaining_seconds"] = rt_rem
data["runtime"]["last_runtime_check_uptime"] = last_up

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local _rc=$?
    flock -u 201
    return $_rc
}

update_runtime_counter() {
    local current_uptime
    current_uptime=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)

    # Reload persisted state — radio-fetcher may have reset it externally
    local persisted_rs persisted_rl persisted_rr persisted_lru
    persisted_rs=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_seconds")
    persisted_rl=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_limit_seconds")
    persisted_rr=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_remaining_seconds")
    persisted_lru=$(read_json_field "$CACHE_META_FILE" "runtime.last_runtime_check_uptime")
    RUNTIME_SECONDS="${persisted_rs:-$RUNTIME_SECONDS}"
    RUNTIME_LIMIT_SECONDS="${persisted_rl:-$RUNTIME_LIMIT_SECONDS}"
    RUNTIME_REMAINING_SECONDS="${persisted_rr:-$RUNTIME_REMAINING_SECONDS}"
    LAST_RUNTIME_CHECK_UPTIME="${persisted_lru:-$LAST_RUNTIME_CHECK_UPTIME}"

    if [ "$LAST_RUNTIME_CHECK_UPTIME" -eq 0 ]; then
        LAST_RUNTIME_CHECK_UPTIME="$current_uptime"
        RUNTIME_REMAINING_SECONDS=$((RUNTIME_LIMIT_SECONDS - RUNTIME_SECONDS))
        if [ "$RUNTIME_REMAINING_SECONDS" -lt 0 ]; then RUNTIME_REMAINING_SECONDS=0; fi
        _write_runtime_state
        return
    fi

    local delta=$((current_uptime - LAST_RUNTIME_CHECK_UPTIME))
    if [ "$delta" -lt 0 ]; then
        delta=0
        log "DEBUG" "Runtime: reboot (uptime ${current_uptime} < ${LAST_RUNTIME_CHECK_UPTIME})"
    fi

    if [ "$delta" -gt 0 ]; then
        RUNTIME_SECONDS=$((RUNTIME_SECONDS + delta))
        RUNTIME_REMAINING_SECONDS=$((RUNTIME_LIMIT_SECONDS - RUNTIME_SECONDS))
        if [ "$RUNTIME_REMAINING_SECONDS" -lt 0 ]; then RUNTIME_REMAINING_SECONDS=0; fi
        log "DEBUG" "Runtime: +${delta}s → ${RUNTIME_SECONDS}/${RUNTIME_LIMIT_SECONDS}s"
    fi

    LAST_RUNTIME_CHECK_UPTIME="$current_uptime"
    _write_runtime_state

    # Re-enable expiration handling if counter was externally reset below limit
    if [ "$RUNTIME_SECONDS" -lt "$RUNTIME_LIMIT_SECONDS" ] && $RUNTIME_EXPIRED_HANDLED; then
        log "INFO" "Runtime counter externally reset — cache refresh succeeded, expiration handled"
        RUNTIME_EXPIRED_HANDLED=false
        exec 201>"$CACHE_OP_LOCK"
        if flock -w 30 201; then
            python3 - "$CACHE_META_FILE" <<'PYEOF'
import json, os, sys, tempfile
fp = sys.argv[1]
with open(fp) as f:
    data = json.load(f)
data.setdefault("runtime", {})
data["runtime"].pop("expired_handled_uptime", None)
dirn = os.path.dirname(fp) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, fp)
PYEOF
            flock -u 201
        else
            log "WARN" "Could not acquire lock for expired_handled_uptime removal — will retry next cycle"
        fi
    fi
}

CACHE_OP_LOCK="/run/sigil/cache-operation.lock"

handle_cache_expiration() {
    if $RUNTIME_EXPIRED_HANDLED; then
        return
    fi
    if [ "$RUNTIME_SECONDS" -lt "$RUNTIME_LIMIT_SECONDS" ]; then
        return
    fi

    # Acquire shared cache-operation lock for the metadata update only
    exec 201>"$CACHE_OP_LOCK"
    if ! flock -w 30 201; then
        log "ERROR" "Could not acquire cache-operation lock for expiration — another cache op in progress"
        return
    fi

    RUNTIME_EXPIRED_HANDLED=true
    python3 - "$CACHE_META_FILE" "$LAST_RUNTIME_CHECK_UPTIME" <<'PYEOF'
import json, os, sys, tempfile
fp = sys.argv[1]
uptime = int(float(sys.argv[2]))
with open(fp) as f:
    data = json.load(f)
data.setdefault("runtime", {})
data["runtime"]["expired_handled_uptime"] = uptime
dirn = os.path.dirname(fp) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, fp)
PYEOF
    flock -u 201
    log "DEBUG" "Released cache-operation lock before wipe/fetch"

    log "WARN" "Cache runtime expired (${RUNTIME_SECONDS}s) — initiating expiration flow"

    # 1. Stop audio-player so it doesn't access stale cache during wipe
    if systemctl is-active --quiet audio-player.service 2>/dev/null; then
        log "INFO" "Stopping audio-player.service for cache wipe"
        if $DRY_RUN; then
            log "DRY" "Would stop audio-player.service"
        else
            systemctl stop audio-player.service 2>/dev/null || true
        fi
    fi

    # 2. Wipe cache — sigil-cache-wipe.sh acquires its own CACHE_OP_LOCK
    local wipe_ok=true
    log "INFO" "Running sigil-cache-wipe.sh"
    if $DRY_RUN; then
        log "DRY" "Would run /usr/local/bin/sigil-cache-wipe.sh"
    else
        if [ -x /usr/local/bin/sigil-cache-wipe.sh ]; then
            /usr/local/bin/sigil-cache-wipe.sh || { log "ERROR" "Cache wipe returned non-zero"; wipe_ok=false; }
        else
            log "ERROR" "sigil-cache-wipe.sh not found or not executable"
            wipe_ok=false
        fi
    fi

    # 3. Try refetch if internet is available and wipe succeeded
    if $wipe_ok && $INTERNET_AVAILABLE; then
        log "INFO" "Internet available — running radio-fetcher --once to rebuild cache"
        if $DRY_RUN; then
            log "DRY" "Would run /usr/local/bin/radio-fetcher.sh --once"
        else
            /usr/local/bin/radio-fetcher.sh --once >> "$LOG" 2>&1
            local fetch_exit=$?
            if [ "$fetch_exit" -eq 0 ]; then
                log "INFO" "radio-fetcher succeeded — runtime counter reset (handled by radio-fetcher)"
            else
                log "ERROR" "radio-fetcher failed (exit ${fetch_exit}) — cache empty, device stays BLOCKED_NO_CACHE"
            fi
        fi
    elif ! $wipe_ok; then
        log "ERROR" "Cache wipe failed — not running fetch (expiration NOT fully handled)"
        RUNTIME_EXPIRED_HANDLED=false
    else
        log "WARN" "No internet — cache wiped, cannot refetch until online"
    fi
}

# ── Recovery interval ───────────────────────────────────────────────────────

check_recovery_eligible() {
    if [ "$AUTO_RETURN_TO_RADIO" != "true" ]; then
        RECOVERY_ELIGIBLE=false
        return
    fi
    if [ -z "$INTERNET_RESTORED_AT" ]; then
        RECOVERY_ELIGIBLE=false
        return
    fi

    local restored_epoch now_epoch interval_sec
    restored_epoch=$(date -d "$INTERNET_RESTORED_AT" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    interval_sec=$(( RECOVERY_INTERVAL_MINUTES * 60 ))

    if [ "$restored_epoch" -gt 0 ] && [ $(( now_epoch - restored_epoch )) -ge "$interval_sec" ]; then
        if ! $RECOVERY_ELIGIBLE; then
            log "INFO" "Recovery interval (${RECOVERY_INTERVAL_MINUTES}min) elapsed — eligible for RADIO return"
        fi
        RECOVERY_ELIGIBLE=true
    else
        local remaining=0
        if [ "$restored_epoch" -gt 0 ]; then
            remaining=$(( interval_sec - (now_epoch - restored_epoch) ))
        fi
        if [ $remaining -gt 0 ] && [ $(( remaining % 60 )) -eq 0 ]; then
            log "DEBUG" "Recovery in ~${remaining}s — not yet eligible"
        fi
        RECOVERY_ELIGIBLE=false
    fi
}

# ── State evaluation ────────────────────────────────────────────────────────

evaluate_state() {
    # Determine desired mode from configuration
    if [ "$PLAYBACK_MODE" = "local-first" ]; then
        CURRENT_DESIRED="LOCAL"
    else
        CURRENT_DESIRED="RADIO"
    fi

    local new_mode=""
    local new_reason=""

    # --- Blocked conditions (highest priority) ---
    if $LEGACY_ACTIVE; then
        LAST_ERROR="Legacy radio-stream.sh is active — cannot take sink"
        new_mode="BLOCKED_LEGACY"
        new_reason="legacy_active"
        log "DEBUG" "Eval: BLOCKED_LEGACY"
        apply_mode "$new_mode" "$CURRENT_DESIRED" "$new_reason"
        return
    fi

    if ! $SINK_AVAILABLE; then
        LAST_ERROR="no_audio_output: no connected A2DP or writable PCM5102A output"
        new_mode="BLOCKED_NO_SINK"
        new_reason="no_audio_output"
        log "DEBUG" "Eval: BLOCKED_NO_SINK"
        apply_mode "$new_mode" "$CURRENT_DESIRED" "$new_reason"
        return
    fi

    # --- Desired mode: RADIO ---
    if [ "$CURRENT_DESIRED" = "RADIO" ]; then
        if ! $INTERNET_AVAILABLE; then
            # Internet is down — try LOCAL if cache available
            if [ "$CACHE_STATUS" = "COMPLETE" ] || [ "$CACHE_STATUS" = "PARTIAL" ] || [ "$CACHE_STATUS" = "EXPIRED" ]; then
                # Only transition if not already LOCAL
                if [ "$CURRENT_MODE" = "RADIO" ] || [ "$CURRENT_MODE" = "TRANSITION_TO_RADIO" ]; then
                    new_mode="TRANSITION_TO_LOCAL"
                    new_reason="server_unreachable"
                    log "INFO" "Eval: RADIO → TRANSITION_TO_LOCAL (no internet, cache: ${CACHE_STATUS})"
                elif [ "$CURRENT_MODE" = "TRANSITION_TO_LOCAL" ]; then
                    # Complete the transition
                    log "INFO" "Eval: TRANSITION_TO_LOCAL → LOCAL"
                    new_mode="LOCAL"
                    new_reason="server_unreachable"
                else
                    new_mode="LOCAL"
                    new_reason="network_lost"
                    log "INFO" "Eval: staying LOCAL (no internet, cache: ${CACHE_STATUS})"
                fi
            else
                # No cache and no internet — blocked
                if [ "$CURRENT_MODE" != "BLOCKED_NO_CACHE" ]; then
                    log "WARN" "Eval: BLOCKED_NO_CACHE (no internet, cache: ${CACHE_STATUS})"
                fi
                new_mode="BLOCKED_NO_CACHE"
                new_reason="cache_empty"
            fi
        else
            # Internet is available
            if [ "$CURRENT_MODE" = "LOCAL" ] || [ "$CURRENT_MODE" = "BLOCKED_NO_CACHE" ] || \
               [ "$CURRENT_MODE" = "TRANSITION_TO_LOCAL" ]; then
                # Currently in LOCAL or blocked — can we return to RADIO?
                if [ "$AUTO_RETURN_TO_RADIO" = "true" ] && [ "$RECOVERY_INTERVAL_MINUTES" -gt 0 ]; then
                    if ! $INTERNET_RESTORE_CHECKED; then
                        # First check — start recovery timer
                        if [ -z "$INTERNET_RESTORED_AT" ]; then
                            INTERNET_RESTORED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                        fi
                        INTERNET_RESTORE_CHECKED=true
                        # Don't transition yet — wait for recovery interval
                        new_mode="$CURRENT_MODE"
                        new_reason="internet_restored"
                        log "INFO" "Eval: internet restored, waiting ${RECOVERY_INTERVAL_MINUTES}min recovery timer"
                    else
                        # Check if recovery timer elapsed
                        check_recovery_eligible
                        if $RECOVERY_ELIGIBLE; then
                            new_mode="TRANSITION_TO_RADIO"
                            new_reason="recovery_timer_expired"
                            log "INFO" "Eval: recovery timer elapsed → TRANSITION_TO_RADIO"
                        else
                            new_mode="$CURRENT_MODE"
                            new_reason="internet_restored"
                            log "DEBUG" "Eval: still in recovery window — staying ${CURRENT_MODE}"
                        fi
                    fi
                else
                    # Auto-return disabled or no recovery interval — immediate return
                    new_mode="TRANSITION_TO_RADIO"
                    new_reason="internet_restored"
                    log "INFO" "Eval: internet restored → TRANSITION_TO_RADIO"
                fi
            elif [ "$CURRENT_MODE" = "TRANSITION_TO_RADIO" ]; then
                # Complete the transition
                log "INFO" "Eval: TRANSITION_TO_RADIO → RADIO"
                new_mode="RADIO"
                new_reason="server_available"
            else
                new_mode="RADIO"
                new_reason="server_available"
                log "DEBUG" "Eval: RADIO (internet OK)"
            fi
            # Reset internet restored tracking once we're back in RADIO
            if [ "$new_mode" = "RADIO" ]; then
                INTERNET_RESTORED_AT=""
                INTERNET_RESTORE_CHECKED=false
            fi
        fi
    fi

    # --- Desired mode: LOCAL ---
    if [ "$CURRENT_DESIRED" = "LOCAL" ]; then
        if [ "$CACHE_STATUS" = "COMPLETE" ] || [ "$CACHE_STATUS" = "PARTIAL" ] || [ "$CACHE_STATUS" = "EXPIRED" ]; then
            if [ "$CURRENT_MODE" = "RADIO" ] || [ "$CURRENT_MODE" = "TRANSITION_TO_RADIO" ]; then
                new_mode="TRANSITION_TO_LOCAL"
                new_reason="manual_switch"
                log "INFO" "Eval: RADIO → TRANSITION_TO_LOCAL (local-first mode)"
            elif [ "$CURRENT_MODE" = "TRANSITION_TO_LOCAL" ]; then
                new_mode="LOCAL"
                new_reason="manual_switch"
                log "INFO" "Eval: TRANSITION_TO_LOCAL → LOCAL"
            else
                new_mode="LOCAL"
                new_reason="manual_switch"
                log "DEBUG" "Eval: staying LOCAL (local-first mode)"
            fi
        else
            if [ "$CURRENT_MODE" != "BLOCKED_NO_CACHE" ]; then
                log "WARN" "Eval: BLOCKED_NO_CACHE (local-first but cache: ${CACHE_STATUS})"
            fi
            new_mode="BLOCKED_NO_CACHE"
            new_reason="cache_empty"
        fi
    fi

    # --- Fallback ---
    if [ -z "$new_mode" ]; then
        log "WARN" "Eval: no transition determined — defaulting to ERROR"
        LAST_ERROR="No valid state transition determined"
        new_mode="ERROR"
        new_reason="error"
    fi

    apply_mode "$new_mode" "$CURRENT_DESIRED" "$new_reason"
}

# ── Apply mode change ───────────────────────────────────────────────────────

apply_mode() {
    local new_mode="$1"
    local new_desired="$2"
    local new_reason="$3"

    # Check if anything actually changed
    if [ "$new_mode" = "$CURRENT_MODE" ] \
        && [ "$new_desired" = "$CURRENT_DESIRED" ] \
        && [ "$new_reason" = "$CURRENT_REASON" ]; then
        return
    fi

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Update transition tracking
    if [ "$new_mode" != "$CURRENT_MODE" ]; then
        LAST_TRANSITION_AT="$now"
        TRANSITION_COUNT=$((TRANSITION_COUNT + 1))
    fi

    CURRENT_MODE="$new_mode"
    CURRENT_DESIRED="$new_desired"
    # shellcheck disable=SC2034 # set for state tracking
    CURRENT_REASON="$new_reason"
    # shellcheck disable=SC2034 # set for state tracking
    MODE_SINCE="$now"

    write_audio_mode "$new_mode" "$new_desired" "$new_reason"
}

# ── Load current audio_mode on startup ──────────────────────────────────────

load_audio_mode() {
    if [ ! -f "$AUDIO_MODE_FILE" ]; then
        log "INFO" "No audio_mode.json found — initializing with RADIO"
        write_audio_mode "RADIO" "RADIO" "startup"
        CURRENT_MODE="RADIO"
        CURRENT_DESIRED="RADIO"
        # shellcheck disable=SC2034 # set for state tracking
        MODE_SINCE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        return
    fi

    local mode desired reason since tc
    mode=$(read_json_field "$AUDIO_MODE_FILE" "mode")
    desired=$(read_json_field "$AUDIO_MODE_FILE" "desired_mode")
    since=$(read_json_field "$AUDIO_MODE_FILE" "since")
    tc=$(read_json_field "$AUDIO_MODE_FILE" "transition_count")

    CURRENT_MODE="${mode:-RADIO}"
    CURRENT_DESIRED="${desired:-RADIO}"
    # shellcheck disable=SC2034 # set for state tracking
    MODE_SINCE="${since:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
    TRANSITION_COUNT="${tc:-0}"

    # Re-read transition_at
    local lta
    lta=$(read_json_field "$AUDIO_MODE_FILE" "last_transition_at")
    LAST_TRANSITION_AT="${lta:-}"

    log "INFO" "Loaded audio_mode.json: mode=${CURRENT_MODE}, desired=${CURRENT_DESIRED}, transitions=${TRANSITION_COUNT}"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    log "INFO" "audio-manager starting"

    load_config

    # Acquire lock
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        die "Another audio-manager instance is already running (lock: ${LOCK_FILE})"
    fi
    log "DEBUG" "Lock acquired: ${LOCK_FILE}"

    # Load previous mode state
    load_audio_mode

    # Load runtime-based cache expiration state
    load_runtime_state

    # Quick initial assessment
    check_legacy
    check_sink
    check_internet
    update_runtime_counter
    handle_cache_expiration
    read_cache_status
    read_playlist_version

    # Initial evaluation
    evaluate_state

    if $ONCE; then
        log "INFO" "--once specified, exiting after initial evaluation"
        cleanup
    fi

    # ── Main loop ───────────────────────────────────────────────────────────
    # Loop interval: 10 seconds. Full evaluation each cycle.
    while true; do
        if $STOP_REQUESTED; then
            log "INFO" "Stop requested"
            break
        fi

        check_legacy
        check_sink
        check_internet
        update_runtime_counter
        handle_cache_expiration
        read_cache_status
        read_playlist_version
        evaluate_state

        if $ONCE; then
            log "INFO" "--once specified, exiting after evaluation cycle"
            break
        fi

        sleep 10
    done

    log "INFO" "audio-manager main loop exited"
    cleanup
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
