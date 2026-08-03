#!/bin/bash
# audio-manager.sh — Audio mode orchestration for Sigil
# Phase 2C — sole owner of mode transitions, coordination, state interpretation
#
# Responsibilities:
#   - Evaluate desired vs. current audio mode every cycle
#   - Write audio_mode.json atomically for audio-player to consume
#   - Detect SIGIL API server availability (direct check, not via player)
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
# shellcheck source=./scripts/sigil-cache-meta-perms.sh
. "$(dirname "${BASH_SOURCE[0]}")/sigil-cache-meta-perms.sh"

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
PLAYBACK_STATE_FILE="${SIGIL_PLAYBACK_STATE_FILE:-/var/lib/sigil/playback_state.json}"
CACHE_META_FILE="/var/lib/sigil/cache_meta.json"
PLAYLIST_ACTIVE_FILE="/var/lib/sigil/playlist.active.json"
MEDIA_SYNC_FILE="${SIGIL_MEDIA_SYNC_FILE:-/var/lib/sigil/media_sync_state.json}"
LICENSE_STATE_FILE="${SIGIL_LICENSE_STATE_FILE:-/var/lib/sigil/license_state.json}"
LICENSE_HELPER="${SIGIL_LICENSE_HELPER:-/usr/local/bin/sigil-license-state.py}"
LICENSE_PURGE="${SIGIL_LICENSE_PURGE:-/usr/local/bin/sigil-license-purge.sh}"
if [ ! -f "$LICENSE_HELPER" ]; then
    LICENSE_HELPER="$(dirname "${BASH_SOURCE[0]}")/sigil-license-state.py"
fi
if [ ! -f "$LICENSE_PURGE" ]; then
    LICENSE_PURGE="$(dirname "${BASH_SOURCE[0]}")/sigil-license-purge.sh"
fi

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
PULSE_RUNTIME_ENV="${SIGIL_PULSE_RUNTIME_ENV:-/etc/sigil/pulse-runtime.env}"
if [ -r "$PULSE_RUNTIME_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$PULSE_RUNTIME_ENV"
    set +a
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/sigil-pulse}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/run/sigil-pulse}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"

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
LAST_INTERNET_CHECK_EPOCH=0
# shellcheck disable=SC2034 # set for state tracking, available for debugging
CURRENT_REASON="startup"
STOP_REQUESTED=false

# License entitlement is independent from cache freshness.  The helper owns
# persistence; this process is its only normal writer.
LICENSE_PHASE="LICENSE_REAUTHORIZING"
LICENSE_USED_SECONDS=0
LICENSE_LIMIT_SECONDS=604800
LICENSE_LAST_EVENT_ID=""
LICENSE_BLOCK_REASON="no_successful_authorization"
MEDIA_SYNC_PHASE="UNKNOWN"
MEDIA_TARGET_HASH=""

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
    local status="${1:-0}"
    if [ -n "${CURL_CONFIG:-}" ] && [ -f "$CURL_CONFIG" ]; then
        rm -f "$CURL_CONFIG"
    fi
    log "DEBUG" "audio-manager shutting down"
    STOP_REQUESTED=true
    # Only a controlled, successful service stop is a clean checkpoint.  A
    # failed manager must retain clean_shutdown=false so a reboot cannot gain
    # offline grace merely because Bash ran an EXIT trap.
    if [ "$status" -eq 0 ] && [ -f "$LICENSE_HELPER" ] && ! $DRY_RUN; then
        python3 "$LICENSE_HELPER" clean-shutdown >/dev/null 2>&1 || true
    fi
    local children
    children=$(jobs -p 2>/dev/null || true)
    if [ -n "$children" ]; then
        # shellcheck disable=SC2086
        kill $children 2>/dev/null || true
        wait 2>/dev/null || true
    fi
    log "INFO" "audio-manager stopped (status=${status})"
    return "$status"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    on_exit() { local status=$?; trap - EXIT TERM INT; cleanup "$status"; return "$status"; }
    on_signal() { trap - EXIT TERM INT; STOP_REQUESTED=true; cleanup 0; exit 0; }
    trap on_exit EXIT
    trap on_signal TERM INT
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
    # Kept for state-schema compatibility; this boolean now means the SIGIL
    # API health endpoint returned HTTP 2xx, not generic Internet reachability.
    "internet_available": (internet_str == "true"),
    "server_reachable": (internet_str == "true"),
    "connectivity_scope": "sigil_api_server",
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

    log "INFO" "audio_mode.json: ${mode} (desired: ${desired}, reason: ${reason}, server_reachable: ${internet_str}, cache: ${CACHE_STATUS})"
}

# ── SIGIL server health check ───────────────────────────────────────────────

check_internet() {
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$(( now_epoch - LAST_INTERNET_CHECK_EPOCH ))

    # Rate-limit: only check every SERVER_CHECK_INTERVAL seconds
    if [ $elapsed -lt "$SERVER_CHECK_INTERVAL" ] && [ "$LAST_INTERNET_CHECK_EPOCH" -gt 0 ]; then
        return
    fi

    LAST_INTERNET_CHECK_EPOCH="$now_epoch"

    # This checks the SIGIL API server, not generic public Internet.  Capture
    # both curl transport status and HTTP status so DNS/connect/TLS/auth/server
    # failures remain distinguishable after reboot.
    local health_url="${SERVER_URL}/api/health"
    local health_rc=0
    local http_code="000"
    if [ -n "$CURL_CONFIG" ]; then
        http_code=$(curl -s --proto '=https' --proto-redir '=https' --max-redirs 0 -o /dev/null -w '%{http_code}' --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${HEALTHCHECK_TIMEOUT_SECONDS}" \
            --config "$CURL_CONFIG" \
            "$health_url" 2>/dev/null) || health_rc=$?
    else
        http_code=$(curl -s --proto '=https' --proto-redir '=https' --max-redirs 0 -o /dev/null -w '%{http_code}' --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${HEALTHCHECK_TIMEOUT_SECONDS}" \
            "$health_url" 2>/dev/null) || health_rc=$?
    fi
    if [ "$health_rc" -eq 0 ] && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        if ! $INTERNET_AVAILABLE; then
            log "INFO" "SIGIL server reachability restored"
        fi
        INTERNET_AVAILABLE=true
        log "INFO" "SIGIL_EVENT event_id=SERVER_HEALTH_RESULT operation_id=audio-manager phase=server_health result=success error_id=none curl_exit=0 http_status=${http_code}"
    else
        local error_id="API_SERVER_UNREACHABLE"
        if [ "$health_rc" -eq 0 ]; then
            case "$http_code" in
                401|403) error_id="API_AUTH_FAILED" ;;
                404) error_id="API_ENDPOINT_NOT_FOUND" ;;
                429) error_id="API_RATE_LIMITED" ;;
                5??) error_id="API_SERVER_ERROR" ;;
                *) error_id="API_HTTP_ERROR" ;;
            esac
        else
            case "$health_rc" in
                6) error_id="DNS_RESOLUTION_FAILED" ;;
                7) error_id="SERVER_CONNECT_FAILED" ;;
                28) error_id="SERVER_TIMEOUT" ;;
                35|51|58|60) error_id="TLS_VALIDATION_FAILED" ;;
            esac
            http_code="000"
        fi
        if $INTERNET_AVAILABLE; then
            log "WARN" "SIGIL server became unavailable (${error_id})"
        fi
        INTERNET_AVAILABLE=false
        log "INFO" "SIGIL_EVENT event_id=SERVER_HEALTH_RESULT operation_id=audio-manager phase=server_health result=failure error_id=${error_id} curl_exit=${health_rc} http_status=${http_code:-invalid}"
    fi
}

# ── Cache status ────────────────────────────────────────────────────────────

read_cache_status() {
    if [ ! -f "$CACHE_META_FILE" ]; then
        CACHE_STATUS="EMPTY"
        log "DEBUG" "Cache status: EMPTY (no cache_meta.json)"
        return
    fi

    local tracks_count expires_at
    tracks_count=$(read_json_field "$CACHE_META_FILE" "active_cache.tracks_count")
    expires_at=$(read_json_field "$CACHE_META_FILE" "active_cache.expires_at")

    if [ -z "$tracks_count" ] || [ "$tracks_count" = "" ] || [ "$tracks_count" = "0" ]; then
        if [ -f "$PLAYLIST_ACTIVE_FILE" ] && python3 - "$PLAYLIST_ACTIVE_FILE" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    playlist = json.load(f)
raise SystemExit(0 if playlist.get("stop_playback") is True and playlist.get("tracks") == [] else 1)
PYEOF
        then
            CACHE_STATUS="INTENTIONAL_EMPTY"
            log "INFO" "Cache status: INTENTIONAL_EMPTY (server requested silence)"
            return
        fi
        CACHE_STATUS="EMPTY"
        log "DEBUG" "Cache status: EMPTY (tracks_count=${tracks_count:-0})"
        return
    fi

    if [ -n "$expires_at" ] && [ "$expires_at" != "" ] && [ "$expires_at" != "null" ]; then
        local now_epoch expires_epoch
        now_epoch=$(date +%s)
        expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo "0")
        if [ "$expires_epoch" -gt 0 ] && [ "$now_epoch" -gt "$expires_epoch" ]; then
            CACHE_STATUS="STALE"
            log "DEBUG" "Cache status: STALE (freshness timestamp ${expires_at})"
            return
        fi
    fi

    CACHE_STATUS="COMPLETE"
    log "DEBUG" "Cache status: COMPLETE (${tracks_count} tracks)"
}

read_media_sync_status() {
    MEDIA_SYNC_PHASE=$(read_json_field "$MEDIA_SYNC_FILE" "phase" 2>/dev/null || true)
    MEDIA_TARGET_HASH=$(read_json_field "$MEDIA_SYNC_FILE" "generation_id" 2>/dev/null || true)
    MEDIA_SYNC_PHASE="${MEDIA_SYNC_PHASE:-UNKNOWN}"
    MEDIA_TARGET_HASH="${MEDIA_TARGET_HASH:-}"
}

# ── License state ──────────────────────────────────────────────────────────

read_license_document() {
    local document="${1:-}"
    [ -n "$document" ] || return 1
    eval "$(printf '%s' "$document" | python3 -c '
import json, shlex, sys
value = json.load(sys.stdin)
mapping = {
    "LICENSE_PHASE": value.get("phase", "LICENSE_REAUTHORIZING"),
    "LICENSE_USED_SECONDS": value.get("offline_grace_used_seconds", 0),
    "LICENSE_LIMIT_SECONDS": value.get("grace_limit_seconds", 604800),
    "LICENSE_LAST_EVENT_ID": value.get("last_authorization_event_id") or "",
    "LICENSE_BLOCK_REASON": value.get("block_reason") or "",
}
for key, item in mapping.items(): print(f"{key}={shlex.quote(str(item))}")
')"
}

license_status() {
    local document
    document=$(SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" status 2>/dev/null || true)
    read_license_document "$document" || return 1
}

license_tick() {
    local document rc=0
    document=$(SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" tick 2>/dev/null) || rc=$?
    read_license_document "$document" || return 1
    if [ "$rc" -eq 2 ]; then
        log "WARN" "License grace reached ${LICENSE_USED_SECONDS}/${LICENSE_LIMIT_SECONDS}s; waiting for current track boundary"
    fi
    return 0
}

license_initialize() {
    local document
    document=$(SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" init 2>/dev/null) || return 1
    read_license_document "$document"
}

consume_authorization_event() {
    local event_id event_result event_code event_boot event_http current_boot document
    event_id=$(read_json_field "$MEDIA_SYNC_FILE" "authorization_event.operation_id" 2>/dev/null || true)
    event_result=$(read_json_field "$MEDIA_SYNC_FILE" "authorization_event.result" 2>/dev/null || true)
    event_code=$(read_json_field "$MEDIA_SYNC_FILE" "authorization_event.protocol_code" 2>/dev/null || true)
    event_boot=$(read_json_field "$MEDIA_SYNC_FILE" "authorization_event.boot_id" 2>/dev/null || true)
    event_http=$(read_json_field "$MEDIA_SYNC_FILE" "authorization_event.http_status" 2>/dev/null || true)
    [ -n "$event_id" ] && [ "$event_id" != "null" ] || return 0
    [ "$event_id" != "$LICENSE_LAST_EVENT_ID" ] || return 0
    current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    if [ -z "$event_boot" ] || [ "$event_boot" != "$current_boot" ]; then
        SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" \
            ack-event --event-id "$event_id" --result "AUTH_EVENT_STALE_BOOT" >/dev/null || return 0
        license_status || true
        log "WARN" "Ignoring stale authorization event from a different boot"
        return 0
    fi

    case "$event_result" in
        AUTHENTICATED_PLAYLIST_OK)
            if [ "$event_http" != "200" ]; then
                SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" \
                    ack-event --event-id "$event_id" --result "AUTH_EVENT_INVALID" >/dev/null || return 0
                license_status || true
                log "WARN" "Ignoring malformed authorization success event without HTTP 200"
                return 0
            fi
            # A response received while purge is pending cannot resurrect old
            # media.  A terminal purge requires a new response afterwards.
            case "$LICENSE_PHASE" in
                LICENSE_EXPIRY_PENDING_TRACK_END|LICENSE_DENIAL_PENDING_TRACK_END)
                    SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" \
                        ack-event --event-id "$event_id" --result "AUTH_IGNORED_DURING_PURGE" >/dev/null || return 0
                    license_status || true
                    log "INFO" "Authenticated playlist observed during irreversible license pending; waiting for post-purge validation"
                    return 0
                    ;;
                LICENSE_EXPIRED_PURGED|LICENSE_DENIED_PURGED)
                    SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" reauthorizing >/dev/null || return 0
                    document=$(SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" authorize --post-purge --event-id "$event_id" 2>/dev/null) || return 0
                    ;;
                *)
                    document=$(SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" authorize --event-id "$event_id" 2>/dev/null) || return 0
                    ;;
            esac
            read_license_document "$document" || return 0
            log "INFO" "Authenticated playlist validation reset the offline grace counter"
            ;;
        AUTHORITATIVE_DENIAL)
            SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" denied \
                --reason "${event_code:-SERVER_POLICY_DENIED}" --event-id "$event_id" >/dev/null || true
            license_status || true
            log "WARN" "Authoritative playlist denial (${event_code:-unknown}); blocking at track boundary"
            ;;
        TRANSIENT_FAILURE)
            document=$(SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" tick \
                --transient-failure "${event_code:-SERVER_UNREACHABLE}" --event-id "$event_id" 2>/dev/null || true)
            read_license_document "$document" || true
            ;;
    esac
}

owned_decoder_is_live() {
    python3 - "$PLAYBACK_STATE_FILE" <<'PYEOF'
import json, pathlib, sys
try:
    state = json.load(open(sys.argv[1], encoding='utf-8'))
    process = state.get('process') if state.get('playing') is True else None
    pid = process.get('pid') if isinstance(process, dict) else None
    ticks = process.get('start_ticks') if isinstance(process, dict) else None
    if not isinstance(pid, int) or not isinstance(ticks, int): raise SystemExit(1)
    actual = int(pathlib.Path(f'/proc/{pid}/stat').read_text(encoding='ascii').split()[21])
    raise SystemExit(0 if actual == ticks else 1)
except Exception:
    raise SystemExit(1)
PYEOF
}

process_license_purge() {
    case "$LICENSE_PHASE" in
        LICENSE_EXPIRY_PENDING_TRACK_END|LICENSE_DENIAL_PENDING_TRACK_END) ;;
        *) return 0 ;;
    esac
    if owned_decoder_is_live; then
        return 0
    fi
    SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" request-purge >/dev/null 2>&1 || return 0
    if SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" \
        SIGIL_PLAYBACK_STATE_FILE="$PLAYBACK_STATE_FILE" "$LICENSE_PURGE"; then
        SIGIL_LICENSE_STATE_FILE="$LICENSE_STATE_FILE" python3 "$LICENSE_HELPER" purge-complete >/dev/null || return 0
        license_status || true
        log "WARN" "Licensed media purged after natural track boundary"
    fi
}

# ── Sink check ──────────────────────────────────────────────────────────────

check_sink() {
    local available route_type route_sink route_reason
    available=$(read_json_field "$PLAYBACK_STATE_FILE" "output.available" 2>/dev/null || true)
    route_type=$(read_json_field "$PLAYBACK_STATE_FILE" "output.type" 2>/dev/null || true)
    route_sink=$(read_json_field "$PLAYBACK_STATE_FILE" "output.sink" 2>/dev/null || true)
    route_reason=$(read_json_field "$PLAYBACK_STATE_FILE" "output.reason" 2>/dev/null || true)

    if [ "$available" = "true" ] && [ -n "$route_type" ] && [ "$route_type" != "null" ] \
        && [ -n "$route_sink" ] && [ "$route_sink" != "null" ]; then
        if ! $SINK_AVAILABLE; then
            log "INFO" "Usable audio output published: ${route_type}/${route_sink}"
        fi
        SINK_AVAILABLE=true
        AUDIO_OUTPUT_TYPE="$route_type"
        AUDIO_OUTPUT_SINK="$route_sink"
    else
        if $SINK_AVAILABLE; then
            log "WARN" "Usable audio output lost (${route_reason:-not_published})"
        fi
        SINK_AVAILABLE=false
        AUDIO_OUTPUT_TYPE=""
        AUDIO_OUTPUT_SINK=""
    fi
    log "DEBUG" "Output check: usable=${SINK_AVAILABLE}, type=${AUDIO_OUTPUT_TYPE:-none}, sink=${AUDIO_OUTPUT_SINK:-none}"
}

# ── Legacy coexistence ──────────────────────────────────────────────────────

check_legacy() {
    local legacy_subshell=""
    # radio-stream.service is the rollback owner.  Do not classify the
    # audio-player's owned mpg123 child as legacy playback.
    if systemctl is-active --quiet radio-stream.service 2>/dev/null; then
        legacy_subshell="active"
    fi

    if [ -n "$legacy_subshell" ]; then
        if ! $LEGACY_ACTIVE; then
            log "WARN" "Legacy playback detected (radio-stream.service: ${legacy_subshell})"
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

evaluate_hybrid_state() {
    CURRENT_DESIRED="LOCAL"
    local new_mode="" new_reason="" active_hash=""
    active_hash=$(read_json_field "$PLAYLIST_ACTIVE_FILE" "version_hash" 2>/dev/null || true)

    if [ "$LICENSE_PHASE" != "LICENSE_AUTHORIZED" ] && [ "$LICENSE_PHASE" != "LICENSE_GRACE_OFFLINE" ]; then
        LAST_ERROR="license_blocked:${LICENSE_BLOCK_REASON:-$LICENSE_PHASE}"
        apply_mode "BLOCKED_LICENSE" "$CURRENT_DESIRED" "license_blocked"
        return
    fi

    if $LEGACY_ACTIVE; then
        LAST_ERROR="Legacy radio-stream.sh is active — cannot take sink"
        apply_mode "BLOCKED_LEGACY" "$CURRENT_DESIRED" "legacy_active"
        return
    fi
    if [ "$CACHE_STATUS" = "INTENTIONAL_EMPTY" ]; then
        LAST_ERROR=""
        apply_mode "IDLE" "$CURRENT_DESIRED" "server_stop_playback"
        return
    fi
    if ! $SINK_AVAILABLE; then
        LAST_ERROR="no_audio_output: no connected A2DP or writable PCM5102A output"
        apply_mode "BLOCKED_NO_SINK" "$CURRENT_DESIRED" "no_audio_output"
        return
    fi

    # A complete generation is always cache-first. Streaming is only selected
    # for a different, authenticated target generation or when no cache exists.
    if [ "$MEDIA_SYNC_PHASE" = "STREAM_WARMUP" ] \
        && [ -n "$MEDIA_TARGET_HASH" ] \
        && [ "$MEDIA_TARGET_HASH" != "$active_hash" ]; then
        if $INTERNET_AVAILABLE; then
            CURRENT_DESIRED="RADIO"
            new_mode="RADIO"
            new_reason="playlist_updated"
        elif [ "$CACHE_STATUS" = "COMPLETE" ] || [ "$CACHE_STATUS" = "STALE" ]; then
            new_mode="LOCAL"
            new_reason="server_unreachable"
        else
            new_mode="BLOCKED_NO_CACHE"
            new_reason="cache_empty"
        fi
    elif [ "$CACHE_STATUS" = "COMPLETE" ] || [ "$CACHE_STATUS" = "STALE" ]; then
        new_mode="LOCAL"
        new_reason="cache_ready"
    elif $INTERNET_AVAILABLE && [ -f "/var/lib/sigil/playlist.staging.json" ]; then
        CURRENT_DESIRED="RADIO"
        new_mode="RADIO"
        new_reason="server_available"
    else
        new_mode="BLOCKED_NO_CACHE"
        new_reason="cache_empty"
    fi

    LAST_ERROR=""
    apply_mode "$new_mode" "$CURRENT_DESIRED" "$new_reason"
}

# ── State evaluation ────────────────────────────────────────────────────────

evaluate_state() {
    evaluate_hybrid_state
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

    # The persistent entitlement state is initialized before any mode can
    # select cache or streaming media.  A missing/invalid state fails closed.
    license_initialize || die "Cannot initialize license state"

    # Quick initial assessment
    check_legacy
    check_sink
    check_internet
    consume_authorization_event
    license_tick
    read_cache_status
    read_media_sync_status
    read_playlist_version

    process_license_purge

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
        consume_authorization_event
        license_tick
        read_cache_status
        read_media_sync_status
        read_playlist_version
        process_license_purge
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
