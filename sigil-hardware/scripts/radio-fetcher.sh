#!/bin/bash
# radio-fetcher.sh — Playlist downloader, hash verifier, atomic swap engine
#
# Responsibilities (architecture doc §2.2):
#   - Consulta /api/devices/{id}/playlist al servidor
#   - Detecta cambios de hash (playlist + tracks)
#   - SI playlist cambió: download to staging, verify, atomic swap
#   - SI playlist NO cambió: skip (ahorra bandwidth)
#   - Actualiza cache_meta.json con timestamps y TTL
#   - Reporta progreso via playlist.staging.json
#   - Verifica TTL de caché en cada ciclo
#
# Usage:
#   radio-fetcher.sh              # normal mode
#   radio-fetcher.sh --dry-run    # show what would be done
#   radio-fetcher.sh --once       # single cycle, then exit
#   radio-fetcher.sh --validate-active  # validate active cache, no fetch
# =============================================================================
# TODO(H5): Device registration removed from radio-fetcher.
# Migration plan:
#   Phase 2B: Implement sigil-firstboot.service that calls
#     POST /api/devices/register once at provisioning.
#   Until then, registration is handled by the legacy radio-stream.sh
#     (see scripts/radio-stream.sh line 116-119).
# =============================================================================
set -euo pipefail
# shellcheck source=./scripts/sigil-cache-meta-perms.sh
. "$(dirname "${BASH_SOURCE[0]}")/sigil-cache-meta-perms.sh"

# --- Paths ---
LOG_DIR="/var/log/sigil"
LOG="${LOG_DIR}/radio-fetcher.log"
LOCK_FILE="/var/lock/sigil-radio-fetcher.lock"
RUN_SIGIL_DIR="${SIGIL_RUN_DIR:-/run/sigil}"
CACHE_OP_LOCK="${RUN_SIGIL_DIR}/cache-operation.lock"
SSH_ACTIVE_MARKER="${RUN_SIGIL_DIR}/ssh-active"
LOGOUT_FETCH_MARKER="${RUN_SIGIL_DIR}/logout-fetch-active"
AUDIO_CONF="/etc/sigil/audio.conf"
API_KEY_FILE="${SIGIL_API_KEY_FILE:-/etc/sigil/secrets/device-api-key}"
IDENTITY_HELPER="${SIGIL_IDENTITY_HELPER:-/home/sigil/device_identity.py}"
DEVICE_CONF="${SIGIL_DEVICE_CONF:-/etc/sigil/device.conf}"
CACHE_META_FILE="${SIGIL_CACHE_META_FILE:-/var/lib/sigil/cache_meta.json}"
PLAYLIST_ACTIVE_FILE="/var/lib/sigil/playlist.active.json"
PLAYLIST_STAGING_FILE="/var/lib/sigil/playlist.staging.json"
MUSIC_ACTIVE="${SIGIL_MUSIC_ACTIVE:-/home/sigil/music/active}"
MUSIC_STAGING="/home/sigil/music/staging"
MUSIC_ARCHIVE="/home/sigil/music/archive"

# --- Config defaults (overridden by audio.conf) ---
SERVER_URL=""
API_KEY=""
AUTH_MODE="query"
PLAYLIST_SYNC_INTERVAL=300
CACHE_TTL_DAYS=7
CONNECT_TIMEOUT_SECONDS=10
PLAYLIST_FETCH_TIMEOUT_SECONDS=15
DOWNLOAD_TIMEOUT_SECONDS=300
LOG_LEVEL="INFO"

# --- Authentication state (set by init_curl_auth) ---
CURL_CONFIG=""
OPERATION_ID="none"

# --- Flags ---
DRY_RUN=false
ONCE=false
VALIDATE_ACTIVE_ONLY=false

# ── Helpers ─────────────────────────────────────────────────────────────────

# Build curl authentication arguments from AUTH_MODE and API_KEY.
# Credentials are written to a config file with mode 600 so they never
# appear on the command line (not visible via /proc/PID/cmdline on Linux).
init_curl_auth() {
    CURL_CONFIG=""
    [ -n "$API_KEY" ] || return 0
    CURL_CONFIG=$(mktemp /tmp/sigil-curl-config.XXXXXX)
    chmod 600 "$CURL_CONFIG"
    printf 'header = "x-api-key: %s"\n' "$API_KEY" > "$CURL_CONFIG"
}

log() {
    local level="${1:-INFO}"
    local msg="$2"
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "DEBUG" ]; then
        return
    fi
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    echo "$line" >> "$LOG"
    # Only print to stderr to avoid capturing in command substitutions
    echo "$line" >&2
}

log_event() {
    local event_id="$1"
    local phase="$2"
    local result="$3"
    local error_id="${4:-none}"
    shift 4 || true
    local uptime_seconds="0"
    if [ -r /proc/uptime ]; then
        IFS=' ' read -r uptime_seconds _ < /proc/uptime || uptime_seconds="0"
        uptime_seconds="${uptime_seconds%%.*}"
    fi
    log "INFO" "SIGIL_EVENT event_id=${event_id} operation_id=${OPERATION_ID} phase=${phase} result=${result} error_id=${error_id} monotonic_ms=$((uptime_seconds * 1000)) $*"
}

die() {
    log "ERROR" "FATAL: $*"
    exit 1
}

cleanup() {
    if [ -n "${CURL_CONFIG:-}" ] && [ -f "$CURL_CONFIG" ]; then
        rm -f "$CURL_CONFIG"
    fi
    log "DEBUG" "radio-fetcher shutting down"
}

handle_signal() {
    exit 143
}

# ── Argument parsing ────────────────────────────────────────────────────────

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --once)    ONCE=true ;;
            --validate-active) VALIDATE_ACTIVE_ONLY=true ;;
            *)         die "Unknown argument: $arg" ;;
        esac
    done
}

# ── Config loading ──────────────────────────────────────────────────────────

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
        log "WARN" "Device API key is not provisioned — fetcher may be rejected by server"
        log_event "API_AUTH_MATERIAL_MISSING" "credential_load" "failure" \
            "API_KEY_NOT_PROVISIONED"
    else
        log_event "API_AUTH_MATERIAL_READY" "credential_load" "success" "none"
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
#
# CONTRACT — update_cache_meta:
#   update_cache_meta <dotted.key.path> <json-value>
#
#   The second argument MUST be valid JSON text (NOT a Python literal):
#     null          → JSON null  (becomes Python None, stored as JSON null)
#     true            → JSON true
#     false           → JSON false
#     0               → JSON number 0
#     100             → JSON number 100
#     '"text"'        → JSON string "text" (note the single quotes are shell,
#                       the inner double quotes are JSON string delimiters)
#     '[]'            → JSON empty array
#     '[1, 2, 3]'     → JSON array of numbers
#     '{"a": 1}'      → JSON object
#
#   Use json_string() to wrap arbitrary Bash strings into valid JSON strings:
#     update_cache_meta "key" "$(json_string "$var")"
#
#   Values are passed as argv to Python — they are NEVER interpolated into
#   Python source code.  This eliminates shell→Python injection bugs.
#
#   Writes are atomic: data is serialized to a temp file in the same directory
#   and renamed via os.replace().  On failure, the existing file is preserved
#   and the function returns 1 (does NOT exit).
#
# CONTRACT — read_json_field:
#   read_json_field <file> <dotted.key.path>
#
#   Prints the value in a Bash-friendly normalized form:
#     JSON string  → the string content (no quotes)
#     JSON number  → the number
#     JSON true    → the literal text: true
#     JSON false   → the literal text: false
#     JSON null    → the literal text: null
#     missing key  → empty string AND return status 1
#   NEVER prints "None" — callers compare against "null", not "None".
# =============================================================================

# json_string <text>
#   Outputs a valid JSON string literal (including surrounding double quotes)
#   for the given Bash text.  Handles quotes, backslashes, newlines, Unicode.
json_string() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

read_json_field() {
    local file="$1"
    local field="$2"
    python3 - "$file" "$field" <<'PYEOF'
import json, sys

file_path = sys.argv[1]
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

read_playlist_active_hash() {
    if [ ! -f "$PLAYLIST_ACTIVE_FILE" ]; then
        echo ""
        return
    fi
    read_json_field "$PLAYLIST_ACTIVE_FILE" "version_hash"
}

get_track_count() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
        print(len(data.get('tracks', [])))
except Exception:
    print('0')
PYEOF
}

extract_tracks_json() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
tracks = data.get('tracks', [])
for t in tracks:
    print(json.dumps(t))
PYEOF
}

# ── File operations ─────────────────────────────────────────────────────────

ensure_dirs() {
    if $DRY_RUN; then
        log "DRY" "Would create: ${LOG_DIR}, ${MUSIC_STAGING}/tracks, ${MUSIC_ARCHIVE}"
        return 0
    fi
    mkdir -p "$LOG_DIR" "$MUSIC_STAGING/tracks" "$MUSIC_ARCHIVE"
}

clean_staging() {
    if $DRY_RUN; then
        log "DRY" "Would clean staging/: rm -rf ${MUSIC_STAGING:?}/*"
        return 0
    fi
    log "DEBUG" "Cleaning staging directory"
    rm -rf "${MUSIC_STAGING:?}/tracks"/* "${MUSIC_STAGING:?}/playlist.json" 2>/dev/null || true
    mkdir -p "$MUSIC_STAGING/tracks"
}

# ── Cache metadata management ───────────────────────────────────────────────

ensure_cache_meta() {
    if [ -f "$CACHE_META_FILE" ]; then
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create initial cache_meta.json at ${CACHE_META_FILE}"
        return 0
    fi
    log "INFO" "Creating initial cache_meta.json"
    local default_meta
    default_meta=$(cat <<'EOF'
{
  "_schema_version": "1.0",
  "cache_policy": {
    "max_ttl_days": 7,
    "auto_renew": true,
    "delete_on_expire": true,
    "preserve_on_server_unavailable": false
  },
  "active_cache": {
    "playlist_id": null,
    "version_hash": null,
    "downloaded_at": null,
    "expires_at": null,
    "tracks_count": 0,
    "total_size_bytes": 0,
    "last_verified_at": null,
    "last_hash_check": null,
    "integrity_verified": false
  },
  "staging_cache": {
    "playlist_id": null,
    "version_hash": null,
    "download_started_at": null,
    "progress_percent": 0,
    "tracks_downloaded": 0,
    "tracks_total": 0
  },
  "statistics": {
    "total_sync_operations": 0,
    "successful_syncs": 0,
    "failed_syncs": 0,
    "last_successful_sync": null,
    "last_failed_sync": null,
    "bytes_downloaded_total": 0,
    "bandwidth_saved_by_skipping": 0
  },
  "expiration_warning_sent": false,
    "expiration_warning_at": null,
    "runtime": {
        "runtime_seconds": 0,
        "runtime_limit_seconds": 604800,
        "runtime_remaining_seconds": 604800,
        "last_runtime_check_uptime": 0
    }
}
EOF
)
    echo "$default_meta" > "$CACHE_META_FILE"
    sigil_cache_meta_fix_permissions "$CACHE_META_FILE"
}

update_cache_meta() {
    local key="$1"
    local value="$2"
    if [ ! -f "$CACHE_META_FILE" ]; then
        log "DEBUG" "cache_meta.json not found — skipping update for $key"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would update cache_meta: ${key} = ${value}"
        return 0
    fi
    python3 - "$CACHE_META_FILE" "$key" "$value" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
key_path  = sys.argv[2]
raw_value = sys.argv[3]

# Parse the value as JSON — never interpolate it into Python source.
# This is the structural fix for the null-vs-None class of bug.
try:
    value = json.loads(raw_value)
except json.JSONDecodeError:
    sys.stderr.write(f"ERROR (update_cache_meta): value is not valid JSON: {raw_value!r}\n")
    sys.exit(1)

keys = key_path.split('.')
if not keys or any(k == '' for k in keys):
    sys.stderr.write(f"ERROR (update_cache_meta): invalid key path: {key_path!r}\n")
    sys.exit(1)

# Read current data
try:
    with open(file_path) as f:
        data = json.load(f)
except FileNotFoundError:
    sys.stderr.write(f"ERROR (update_cache_meta): file not found: {file_path}\n")
    sys.exit(1)
except json.JSONDecodeError as e:
    sys.stderr.write(f"ERROR (update_cache_meta): existing file is not valid JSON: {e}\n")
    sys.exit(1)

# Walk to parent, creating intermediate dicts only for safe, expected nesting
obj = data
for k in keys[:-1]:
    if k not in obj:
        obj[k] = {}
    elif not isinstance(obj[k], dict):
        sys.stderr.write(f"ERROR (update_cache_meta): key path segment {k!r} is not an object\n")
        sys.exit(1)
    obj = obj[k]

obj[keys[-1]] = value

# Atomic write: temp file in same directory, os.replace()
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, file_path)
except Exception:
    # Clean up temp on failure — original file untouched
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PYEOF
    sigil_cache_meta_fix_permissions "$CACHE_META_FILE"
    local rc=$?
    if [ $rc -ne 0 ]; then
        log "ERROR" "update_cache_meta failed (key='$key', rc=$rc) — cache_meta.json NOT modified"
        return 1
    fi
    return 0
}

reset_staging_cache() {
    update_cache_meta "staging_cache.playlist_id"        'null'
    update_cache_meta "staging_cache.version_hash"        'null'
    update_cache_meta "staging_cache.download_started_at" 'null'
    update_cache_meta "staging_cache.progress_percent"    '0'
    update_cache_meta "staging_cache.tracks_downloaded"   '0'
    update_cache_meta "staging_cache.tracks_total"        '0'
    update_cache_meta "staging_cache.failed_tracks"       '[]'
}

reset_cache_runtime() {
    if $DRY_RUN; then
        log "DRY" "Would reset cache runtime counter to 0"
        return 0
    fi
    local current_limit
    current_limit=$(read_json_field "$CACHE_META_FILE" "runtime.runtime_limit_seconds")
    current_limit="${current_limit:-604800}"
    update_cache_meta "runtime.runtime_seconds"          "0"
    update_cache_meta "runtime.runtime_remaining_seconds" "$current_limit"
    update_cache_meta "runtime.last_runtime_check_uptime" "0"
    log "DEBUG" "Reset cumulative runtime counter to 0 (fresh cache, limit=${current_limit})"
}

# ── TTL check ───────────────────────────────────────────────────────────────

check_cache_ttl() {
    local expires_at
    expires_at=$(read_json_field "$CACHE_META_FILE" "active_cache.expires_at")
    if [ -z "$expires_at" ] || [ "$expires_at" = "null" ]; then
        log "DEBUG" "No active cache TTL to check"
        return 1
    fi
    local now_epoch
    local expire_epoch
    now_epoch=$(date +%s)
    expire_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo "0")
    if [ "$expire_epoch" -eq 0 ]; then
        log "WARN" "Could not parse expires_at: $expires_at"
        return 1
    fi
    if [ "$now_epoch" -ge "$expire_epoch" ]; then
        log "INFO" "Cache expired at $expires_at"
        return 0
    fi
    local remaining_days
    remaining_days=$(( (expire_epoch - now_epoch) / 86400 ))
    log "DEBUG" "Cache valid — expires in ${remaining_days}d at $expires_at"
    return 1
}

# ── Server communication ────────────────────────────────────────────────────

http_get_to_file() {
    local endpoint_class="$1"
    local request_url="$2"
    local output_file="$3"
    local http_code="000"
    local curl_rc=0
    local -a curl_args=(
        --silent --show-error --location
        --connect-timeout "${CONNECT_TIMEOUT_SECONDS}"
        --max-time "${4}"
        --output "$output_file"
        --write-out '%{http_code}'
    )
    if [ -n "$CURL_CONFIG" ]; then
        curl_args+=(--config "$CURL_CONFIG")
    fi

    if http_code=$(curl "${curl_args[@]}" "$request_url" 2>/dev/null); then
        curl_rc=0
    else
        curl_rc=$?
    fi

    if [ "$curl_rc" -ne 0 ]; then
        local error_id="API_SERVER_UNREACHABLE"
        case "$curl_rc" in
            6) error_id="DNS_RESOLUTION_FAILED" ;;
            7) error_id="SERVER_CONNECT_FAILED" ;;
            28) error_id="SERVER_TIMEOUT" ;;
            35|51|58|60) error_id="TLS_VALIDATION_FAILED" ;;
        esac
        rm -f "$output_file"
        log_event "HTTP_REQUEST_FAILED" "${endpoint_class}" "failure" \
            "$error_id" "curl_exit=${curl_rc} http_status=000"
        return 1
    fi

    if ! [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
        rm -f "$output_file"
        log_event "HTTP_REQUEST_FAILED" "${endpoint_class}" "failure" \
            "HTTP_STATUS_INVALID" "curl_exit=0 http_status=invalid"
        return 1
    fi

    case "$http_code" in
        2??)
            log_event "HTTP_REQUEST_COMPLETED" "${endpoint_class}" "success" \
                "none" "curl_exit=0 http_status=${http_code}"
            return 0
            ;;
        401|403) error_id="API_AUTH_FAILED" ;;
        404) error_id="API_ENDPOINT_NOT_FOUND" ;;
        408) error_id="API_REQUEST_TIMEOUT" ;;
        429) error_id="API_RATE_LIMITED" ;;
        5??) error_id="API_SERVER_ERROR" ;;
        *) error_id="API_HTTP_ERROR" ;;
    esac
    rm -f "$output_file"
    log_event "HTTP_REQUEST_FAILED" "${endpoint_class}" "failure" \
        "$error_id" "curl_exit=0 http_status=${http_code}"
    return 1
}

fetch_remote_playlist() {
    local device_id="$1"
    if $DRY_RUN; then
        log "DRY" "Would fetch: GET ${SERVER_URL}/api/devices/${device_id}/playlist"
        echo '{"dry_run": true, "tracks": []}'
        return 0
    fi
    local response_file
    response_file=$(mktemp /tmp/sigil-playlist-response.XXXXXX)
    chmod 600 "$response_file"
    if ! http_get_to_file "playlist_request" \
        "${SERVER_URL}/api/devices/${device_id}/playlist" \
        "$response_file" "${PLAYLIST_FETCH_TIMEOUT_SECONDS}"; then
        return 1
    fi
    cat "$response_file"
    rm -f "$response_file"
}

# Compute a stable content hash from the playlist JSON.
# Hash is derived only from the sorted/normalized tracks array,
# so it is insensitive to server metadata (timestamps, pagination, etc.).
compute_playlist_hash() {
    echo "$1" | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
# Sort for deterministic hash across unordered inputs
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
" 2>/dev/null
}

# ── Remote playlist validation (H4) ─────────────────────────────────────────

validate_remote_playlist() {
    local json="$1"
    echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except:
    sys.exit(1)
if isinstance(data, list):
    if len(data) > 0:
        t = data[0]
        if 'url' not in t:
            sys.exit(1)
elif isinstance(data, dict):
    if 'tracks' not in data and '_schema_version' not in data:
        sys.exit(1)
    tracks = data.get('tracks', [])
    if len(tracks) > 0:
        t = tracks[0]
        if 'url' not in t and 'filename' not in t:
            sys.exit(1)
else:
    sys.exit(1)
print('valid')
" 2>/dev/null | grep -q 'valid'
}

# ── Track download and verification ─────────────────────────────────────────

download_track() {
    local track_url="$1"
    local output_path="$2"
    local expected_hash="${3:-}"

    if $DRY_RUN; then
        log "DRY" "Would download track from server"
        return 0
    fi

    # URL encode spaces
    local safe_url
    safe_url="${track_url// /%20}"

    local download_url="${SERVER_URL}${safe_url}"

    log "DEBUG" "Downloading track"
    if ! http_get_to_file "audio_request" "$download_url" "$output_path" \
        "${DOWNLOAD_TIMEOUT_SECONDS}"; then
        log "ERROR" "Audio request failed; classification logged"
        return 1
    fi

    if [ ! -s "$output_path" ]; then
        log "ERROR" "Downloaded file is empty"
        rm -f "$output_path"
        return 1
    fi

    # Verify hash if provided
    if [ -n "$expected_hash" ]; then
        local actual_hash
        actual_hash=$(sha256sum "$output_path" | cut -d' ' -f1)
        if [ "$actual_hash" != "$expected_hash" ]; then
            log "ERROR" "Hash mismatch for $(basename "$output_path"): expected $expected_hash, got $actual_hash"
            rm -f "$output_path"
            return 1
        fi
        log "DEBUG" "Hash verified for $(basename "$output_path")"
    fi

    local size
    size=$(stat -c%s "$output_path" 2>/dev/null || echo 0)
    log "DEBUG" "Downloaded $(basename "$output_path") ($size bytes)"
    echo "$size"
    return 0
}

link_unchanged_track() {
    local source="$1"
    local target="$2"
    local filename
    filename=$(basename "$source")
    if $DRY_RUN; then
        log "DRY" "Would hardlink: $source → $target"
        return 0
    fi
    if ln "$source" "$target" 2>/dev/null; then
        log "DEBUG" "Hardlinked unchanged track: ${filename}"
        return 0
    fi
    log "WARN" "Hardlink failed for ${filename} — falling back to copy"
    if cp "$source" "$target" 2>/dev/null; then
        log "INFO" "Copied unchanged track: ${filename}"
    else
        log "ERROR" "Both hardlink and copy failed for ${filename}"
        return 1
    fi
}

# ── Staging validation (C2) ─────────────────────────────────────────────────

validate_staging() {
    local expected_count="$1"

    if [ ! -f "$PLAYLIST_STAGING_FILE" ]; then
        log "ERROR" "Atomic swap blocked: staging playlist not found"
        return 1
    fi
    if [ ! -d "$MUSIC_STAGING/tracks" ]; then
        log "ERROR" "Atomic swap blocked: staging tracks directory missing"
        return 1
    fi

    local actual_count
    actual_count=$(find "$MUSIC_STAGING/tracks" -type f 2>/dev/null | wc -l)
    if [ "$actual_count" -ne "$expected_count" ]; then
        log "ERROR" "Atomic swap blocked: expected ${expected_count} tracks, staging has ${actual_count}"
        return 1
    fi

    local staging_valid=true
    python3 - "$PLAYLIST_STAGING_FILE" "$MUSIC_STAGING" <<'PYEOF' 2>/dev/null || staging_valid=false
import json, sys, os, hashlib

with open(sys.argv[1]) as f:
    data = json.load(f)

tracks = data.get('tracks', [])
staging_dir = sys.argv[2]

# Build set of expected filenames
expected_fnames = set()
for t in tracks:
    fname = t.get('filename', '') or os.path.basename(t.get('url', ''))
    expected_fnames.add(fname)

# Check no extra files in staging
actual_fnames = set(os.listdir(os.path.join(staging_dir, 'tracks')))
extra = actual_fnames - expected_fnames
if extra:
    print("ERROR: unexpected files in staging: " + ", ".join(sorted(extra)), file=sys.stderr)
    sys.exit(1)

# Verify every expected track: exists, non-zero size, matching sha256
for t in tracks:
    fname = t.get('filename', '') or os.path.basename(t.get('url', ''))
    path = os.path.join(staging_dir, 'tracks', fname)

    if not os.path.isfile(path):
        print("ERROR: missing track file: " + fname, file=sys.stderr)
        sys.exit(1)

    file_size = os.path.getsize(path)
    if file_size == 0:
        print("ERROR: zero-size track file: " + fname, file=sys.stderr)
        sys.exit(1)

    expected_hash = t.get('sha256', '')
    if expected_hash:
        with open(path, 'rb') as fh:
            actual_hash = hashlib.sha256(fh.read()).hexdigest()
        if actual_hash != expected_hash:
            print("ERROR: sha256 mismatch for " + fname, file=sys.stderr)
            sys.exit(1)
PYEOF

    if [ "$staging_valid" != "true" ]; then
        log "ERROR" "Atomic swap blocked: staging validation failed"
        return 1
    fi

    log "DEBUG" "Staging validated: ${expected_count} tracks complete (sizes + hashes verified)"
    return 0
}

# ── Atomic swap ─────────────────────────────────────────────────────────────

atomic_swap() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${MUSIC_ARCHIVE}/pl_${timestamp}"

    if $DRY_RUN; then
        log "DRY" "Would perform atomic swap:"
        log "DRY" "  1. mkdir -p ${backup_dir}"
        log "DRY" "  2. mv ${MUSIC_ACTIVE} → ${backup_dir}/old_active/"
        log "DRY" "  3. mv ${MUSIC_STAGING} → ${MUSIC_ACTIVE}"
        log "DRY" "  4. Keep old_active in archive (no delete)"
        return 0
    fi

    log "INFO" "Performing atomic swap"

    # 1. Backup current active to archive
    mkdir -p "$backup_dir"
    if [ -d "$MUSIC_ACTIVE/tracks" ]; then
        mv "$MUSIC_ACTIVE" "${backup_dir}/old_active/"
        log "INFO" "Backed up old active → ${backup_dir}/old_active/"
    fi

    # 2. Swap staging → active
    mv "$MUSIC_STAGING" "$MUSIC_ACTIVE"
    log "INFO" "Atomic swap complete: staging → active"

    # 3. Recreate staging for next cycle
    mkdir -p "$MUSIC_STAGING/tracks"

    # 4. Copy staging playlist to active dir for the player
    if [ -f "$PLAYLIST_STAGING_FILE" ]; then
        cp "$PLAYLIST_STAGING_FILE" "${MUSIC_ACTIVE}/playlist.json"
    fi

    log "INFO" "Archive preserved at ${backup_dir}/old_active/"

    # --- Phase 3A: Enforce archive retention (max 3) ---
    enforce_archive_retention
}

# ── Archive retention (Phase 3A) ────────────────────────────────────────────
# Keep at most 3 archived playlists in MUSIC_ARCHIVE. Removes oldest first.
enforce_archive_retention() {
    local max_archives=3

    if $DRY_RUN; then
        log "DRY" "Would enforce archive retention (max ${max_archives})"
        return 0
    fi

    if [ ! -d "$MUSIC_ARCHIVE" ]; then
        return 0
    fi

    local count
    count=$(find "$MUSIC_ARCHIVE" -maxdepth 1 -type d -name 'pl_*' 2>/dev/null | wc -l)

    if [ "$count" -le "$max_archives" ]; then
        return 0
    fi

    local to_remove
    to_remove=$((count - max_archives))
    log "INFO" "Archive retention: ${count} dirs found, removing ${to_remove} oldest"

    find "$MUSIC_ARCHIVE" -maxdepth 1 -type d -name 'pl_*' -printf '%T@ %p\0' 2>/dev/null \
        | sort -zn \
        | head -z -n "$to_remove" \
        | while IFS= read -r -d '' entry; do
            local dir
            dir=$(echo "$entry" | cut -d' ' -f2-)
            if [ -n "$dir" ]; then
                rm -rf "$dir"
                log "INFO" "Removed old archive: $(basename "$dir")"
            fi
        done
}

# ---- Safe track filename validation (H6) ---------------------------------
# Centralized function used by both fetcher and player.
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if [ "${fname#/}" != "$fname" ]; then return 1; fi
    case "$fname" in */*|*\\*) return 1 ;; esac
    if [ "$fname" = "." ] || [ "$fname" = ".." ]; then return 1; fi
    case "$fname" in *\.\./*|*\.\.) return 1 ;; esac
    if echo "$fname" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null; then return 1; fi
    if [ "$(basename "$fname")" != "$fname" ]; then return 1; fi
    return 0
}

# ---- validate_active ----------------------------------------------------
# Verify every track in active/ against the remote playlist.
# Called when the remote hash is unchanged -- catches silent file loss.
validate_active() {
    local tracks_dir="${MUSIC_ACTIVE}/tracks"
    local playlist_file="${MUSIC_ACTIVE}/playlist.json"

    # Must have tracks_count > 0 in cache_meta
    local active_count
    if ! active_count=$(read_json_field "$CACHE_META_FILE" "active_cache.tracks_count") ||
       ! [[ "$active_count" =~ ^[1-9][0-9]*$ ]]; then
        log "WARN" "validate_active: active_cache.tracks_count is 0"
        return 1
    fi

    # Must have playlist.active.json
    if [ ! -f "$playlist_file" ]; then
        log "WARN" "validate_active: playlist.json not found at ${playlist_file}"
        return 1
    fi

    # Must have tracks directory
    if [ ! -d "$tracks_dir" ]; then
        log "WARN" "validate_active: tracks dir not found at ${tracks_dir}"
        return 1
    fi

    # Full validation in Python
    python3 - "$playlist_file" "$tracks_dir" "$CACHE_META_FILE" "$active_count" <<'PYEOF' || return 1
import json, os, sys, re, hashlib

playlist_path = sys.argv[1]
tracks_dir = sys.argv[2]
cache_meta_path = sys.argv[3]
active_count = int(sys.argv[4])

# Load playlist
try:
    with open(playlist_path) as f:
        playlist = json.load(f)
except (FileNotFoundError, json.JSONDecodeError) as e:
    print("ERROR: cannot load playlist.json: " + str(e), file=sys.stderr)
    sys.exit(1)

tracks = playlist.get("tracks", [])
if not isinstance(tracks, list) or not tracks:
    print("ERROR: playlist has no tracks", file=sys.stderr)
    sys.exit(1)
if len(tracks) != active_count:
    print("ERROR: tracks_count mismatch: metadata {} playlist {}".format(active_count, len(tracks)), file=sys.stderr)
    sys.exit(1)

# Load cache_meta for size_bytes comparison
cache_meta = {}
try:
    with open(cache_meta_path) as f:
        cache_meta = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass

active_cache = cache_meta.get("active_cache", {})
expected_total_size = active_cache.get("total_size_bytes", 0) if isinstance(active_cache, dict) else 0
if not isinstance(expected_total_size, int) or isinstance(expected_total_size, bool) or expected_total_size < 0:
    print("ERROR: cache_meta active_cache.total_size_bytes is invalid", file=sys.stderr)
    sys.exit(1)
playlist_total_size = playlist.get("total_size_bytes", 0)
if not isinstance(playlist_total_size, int) or isinstance(playlist_total_size, bool) or playlist_total_size < 0:
    print("ERROR: playlist total_size_bytes is invalid", file=sys.stderr)
    sys.exit(1)

# Safe-filename regex: only allow alphanumeric, dot, hyphen, underscore
SAFE_RE = re.compile(r'^[a-zA-Z0-9._-]+$')

filenames_from_playlist = []
errors = []
limitations = []
all_tracks_have_size = True

for i, t in enumerate(tracks):
    if not isinstance(t, dict):
        errors.append("track[{}]: track object is invalid".format(i))
        filenames_from_playlist.append("")
        all_tracks_have_size = False
        continue
    raw_filename = t.get("filename", "")
    raw_url = t.get("url", "")
    if not isinstance(raw_filename, str) or not isinstance(raw_url, str):
        errors.append("track[{}]: filename/url metadata is invalid".format(i))
        filenames_from_playlist.append("")
        all_tracks_have_size = False
        continue
    fname = raw_filename or os.path.basename(raw_url)
    filenames_from_playlist.append(fname)

    # ---- 1) Safe filename ----
    if not fname:
        errors.append("track[{}]: empty filename".format(i))
        continue
    if "/" in fname or ".." in fname or not SAFE_RE.match(fname):
        errors.append("track[{}]: unsafe filename '{}'".format(i, fname))
        continue

    track_path = os.path.join(tracks_dir, fname)

    # ---- 2) File exists ----
    if not os.path.isfile(track_path):
        errors.append("track[{}]: file missing '{}'".format(i, fname))
        continue

    # ---- 3) Non-zero size ----
    file_size = os.path.getsize(track_path)
    if file_size == 0:
        errors.append("track[{}]: zero-size file '{}'".format(i, fname))
        continue

    # ---- 4) size_bytes comparison ----
    expected_size = t.get("size_bytes", 0)
    if not isinstance(expected_size, int) or isinstance(expected_size, bool) or expected_size < 0:
        errors.append("track[{}]: invalid size_bytes for '{}'".format(i, fname))
        continue
    if expected_size <= 0:
        all_tracks_have_size = False
    if expected_size > 0 and file_size != expected_size:
        errors.append("track[{}]: size mismatch for '{}' (expected {}, got {})".format(i, fname, expected_size, file_size))
        continue

    # ---- 5) SHA-256 comparison ----
    expected_hash = t.get("sha256", "")
    if expected_hash and (not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected_hash)):
        errors.append("track[{}]: invalid sha256 metadata for '{}'".format(i, fname))
        continue
    if expected_hash:
        with open(track_path, "rb") as fh:
            actual_hash = hashlib.sha256(fh.read()).hexdigest()
        if actual_hash != expected_hash:
            errors.append("track[{}]: sha256 mismatch for '{}'".format(i, fname))
            continue
    if expected_size <= 0 and not expected_hash:
        limitations.append("track[{}] '{}': backend supplied neither positive size_bytes nor sha256".format(i, fname))

# ---- 6) No duplicate filenames in playlist ----
seen = {}
for i, fname in enumerate(filenames_from_playlist):
    if fname in seen:
        errors.append("duplicate filename '{}' at tracks[{}] and tracks[{}]".format(fname, seen[fname], i))
    seen[fname] = i

# ---- 7) Exact filename-set equality ----
disk_files = set()
if os.path.isdir(tracks_dir):
    for entry in os.listdir(tracks_dir):
        entry_path = os.path.join(tracks_dir, entry)
        if os.path.isfile(entry_path):
            disk_files.add(entry)

playlist_files = set(filenames_from_playlist)

extra_files = disk_files - playlist_files
missing_files = playlist_files - disk_files

for f in sorted(extra_files):
    errors.append("extra file on disk not in playlist: '{}'".format(f))
for f in sorted(missing_files):
    errors.append("missing file from playlist on disk: '{}'".format(f))

# ---- 8) Reject malformed - reject if any track lacks required fields
# (already handled above by checking filename, size_bytes, sha256)

actual_total = sum(os.path.getsize(os.path.join(tracks_dir, f)) for f in disk_files if os.path.isfile(os.path.join(tracks_dir, f)))
if expected_total_size > 0 and actual_total != expected_total_size:
    errors.append("total_size_bytes mismatch: expected {} got {}".format(expected_total_size, actual_total))
if playlist_total_size > 0 and actual_total != playlist_total_size:
    errors.append("playlist total_size_bytes mismatch: expected {} got {}".format(playlist_total_size, actual_total))
if all_tracks_have_size:
    declared_total = sum(t["size_bytes"] for t in tracks)
    if actual_total != declared_total:
        errors.append("aggregate per-track size mismatch: expected {} got {}".format(declared_total, actual_total))

if errors:
    for err in errors:
        print("ERROR: " + err, file=sys.stderr)
    sys.exit(1)

for limitation in limitations:
    print("LIMITATION: " + limitation, file=sys.stderr)

print("OK: {} tracks validated (sizes, sha256, filename-set)".format(len(tracks)))
sys.exit(0)
PYEOF
    local result=$?
    if [ "$result" -eq 0 ]; then
        log "DEBUG" "validate_active: ${active_count} tracks fully validated"
        return 0
    else
        log "WARN" "validate_active: full-track validation FAILED"
        return 1
    fi
}

# ── Main sync cycle ─────────────────────────────────────────────────────────

logout_fetch_requested() {
    [ "${SIGIL_LOGOUT_FETCH:-0}" = "1" ]
}

cache_fetch_coordination_allowed() {
    local phase="${1:-cache operation}"

    if [ -f "$SSH_ACTIVE_MARKER" ]; then
        log "INFO" "SSH active during ${phase} — refusing cache reconstruction"
        return 1
    fi

    if [ -f "$LOGOUT_FETCH_MARKER" ]; then
        if logout_fetch_requested && $ONCE; then
            return 0
        fi
        log "INFO" "SSH logout fetch owns cache reconstruction during ${phase} — scheduled cycle skipped"
        return 1
    fi

    if logout_fetch_requested; then
        log "ERROR" "Authorized SSH logout fetch lost its coordination marker during ${phase}"
        return 1
    fi
    return 0
}

sync_cycle() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        IFS= read -r OPERATION_ID < /proc/sys/kernel/random/uuid || OPERATION_ID="none"
    else
        OPERATION_ID="none"
    fi
    log_event "MEDIA_SYNC_REQUESTED" "sync_cycle" "started" "none"
    # Normal continuous cycles check before taking the component lock so they
    # cannot briefly starve the explicit SSH-logout fetch.  The authorized
    # one-shot waits for a pre-existing cycle to release the component lock.
    if ! cache_fetch_coordination_allowed "pre-lock check"; then
        return 2
    fi

    # --- C1: Acquire component lock — prevent concurrent fetcher ---
    if logout_fetch_requested; then
        if ! flock -w 30 200; then
            log "ERROR" "Could not acquire fetcher component lock for SSH logout rebuild"
            return 1
        fi
    elif ! flock -n 200; then
        log "WARN" "Another sync cycle is already running — skipping this cycle"
        return 1
    fi
    # --- Acquire shared cache-operation lock ---
    # Prevents concurrent wipe/expiration during the fetch transaction.
    exec 201>"$CACHE_OP_LOCK"
    if ! flock -w 30 201; then
        log "ERROR" "Could not acquire cache-operation lock — another cache op is in progress"
        flock -u 200
        return 1
    fi
    # Locks released at end of function in reverse order: flock -u 201; flock -u 200

    log "INFO" "=== Sync cycle started ==="
    log_event "MEDIA_SYNC_LOCKS_ACQUIRED" "sync_cycle" "success" "none"

    # Recheck both SSH markers after acquiring both locks.  This closes the
    # race between the pre-lock check and lock acquisition.
    if ! cache_fetch_coordination_allowed "post-lock check"; then
        flock -u 201
        flock -u 200
        return 2
    fi

    # Capture pre-sync active tracks count to decide whether runtime may reset
    local prev_tracks_count
    prev_tracks_count=$(read_json_field "$CACHE_META_FILE" "active_cache.tracks_count" 2>/dev/null || echo "0")
    prev_tracks_count="${prev_tracks_count:-0}"

    # --- C3: Recover from incomplete staging left by previous crash ---
    if [ -d "$MUSIC_STAGING/tracks" ] && [ -n "$(ls -A "$MUSIC_STAGING/tracks/" 2>/dev/null)" ]; then
        log "WARN" "Incomplete staging from previous run detected — cleaning"
        clean_staging
    fi
    if [ -f "$PLAYLIST_STAGING_FILE" ]; then
        if $DRY_RUN; then
            log "DRY" "Would remove stale playlist.staging.json"
        else
            log "WARN" "Stale playlist.staging.json from previous run — removing"
            rm -f "$PLAYLIST_STAGING_FILE"
        fi
    fi

    # --- Ensure state files exist ---
    ensure_cache_meta

    # --- Get device identity ---
    local device_id
    device_id=$(get_device_id)
    log "DEBUG" "Device identity loaded"

    # --- Fetch remote playlist ---
    local remote_json
    remote_json=$(fetch_remote_playlist "$device_id") || {
        log "WARN" "Playlist request failed; classified HTTP event logged"
        local failed
        failed=$(read_json_field "$CACHE_META_FILE" "statistics.failed_syncs")
        failed=$((failed + 1))
        update_cache_meta "statistics.failed_syncs" "$failed"
        flock -u 201
        flock -u 200
        log_event "MEDIA_SYNC_FAILED" "playlist_request" "failure" \
            "PLAYLIST_REQUEST_FAILED"
        return 1
    }

    if [ -z "$remote_json" ] || [ "$remote_json" = "null" ]; then
        log "WARN" "Empty response from server"
        local failed
        failed=$(read_json_field "$CACHE_META_FILE" "statistics.failed_syncs")
        failed=$((failed + 1))
        update_cache_meta "statistics.failed_syncs" "$failed"
        flock -u 201
        flock -u 200
        return 1
    fi

    # --- H4: Validate remote playlist before processing ---
    if ! validate_remote_playlist "$remote_json"; then
        log "ERROR" "Remote playlist failed schema validation — rejecting"
        local failed
        failed=$(read_json_field "$CACHE_META_FILE" "statistics.failed_syncs")
        failed=$((failed + 1))
        update_cache_meta "statistics.failed_syncs" "$failed"
        flock -u 201
        flock -u 200
        return 1
    fi

    # --- Compute remote hash ---
    local remote_hash
    remote_hash=$(compute_playlist_hash "$remote_json")
    log "DEBUG" "Remote playlist hash: $remote_hash"

    # --- Read local active playlist ---
    local local_hash
    local_hash=$(read_playlist_active_hash)
    log "DEBUG" "Local active hash: ${local_hash:-<none>}"

    local total_sync
    total_sync=$(read_json_field "$CACHE_META_FILE" "statistics.total_sync_operations")
    total_sync=$((total_sync + 1))
    update_cache_meta "statistics.total_sync_operations" "$total_sync"

    # --- Compare hashes ---
    if [ -n "$local_hash" ] && [ "$remote_hash" = "$local_hash" ]; then
        if validate_active; then
            log "INFO" "Playlist unchanged (hash: ${remote_hash:0:12}) — skipping download"
            local saved_bandwidth
            saved_bandwidth=$(read_json_field "$CACHE_META_FILE" "statistics.bandwidth_saved_by_skipping")
            saved_bandwidth=$((saved_bandwidth + 1))
            update_cache_meta "statistics.bandwidth_saved_by_skipping" "$saved_bandwidth"
            # Reset staging_cache in case it was left from a previous failed sync
            reset_staging_cache
            update_cache_meta "active_cache.last_hash_check" "$(json_string "$remote_hash")"
            log "INFO" "=== Sync cycle complete (skipped) ==="
            flock -u 201
            flock -u 200
            return 0
        fi
        log "INFO" "Playlist hash unchanged but active cache is empty — forcing rebuild"
    fi

    log "INFO" "Playlist changed — syncing new content"

    # --- Extract tracks from remote playlist (handle both object and array) ---
    local remote_playlist_id
    remote_playlist_id=$(echo "$remote_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        print('remote_array')
    else:
        print(data.get('playlist_id', 'unknown'))
except: print('unknown')
" 2>/dev/null)

    # Write remote playlist as staging playlist with stable content hash
    local staging_playlist
    staging_playlist=$(echo "$remote_json" | python3 -c "
import json, sys
raw = json.load(sys.stdin)
# Normalize tracks
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm_json = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
import hashlib
version_hash = hashlib.sha256(norm_json.encode()).hexdigest()
if isinstance(raw, list):
    result = {'_schema_version': '1.0', 'playlist_id': 'remote_' + str(hash(norm_json)), 'version_hash': version_hash, 'source': 'server', 'tracks': tracks}
elif isinstance(raw, dict):
    raw['version_hash'] = version_hash
    raw.setdefault('_schema_version', '1.0')
    result = raw
else:
    result = {'_schema_version': '1.0', 'playlist_id': 'unknown', 'version_hash': version_hash, 'tracks': []}
print(json.dumps(result, indent=2))
" 2>/dev/null) || staging_playlist="$remote_json"

    if $DRY_RUN; then
        log "DRY" "Would write: ${PLAYLIST_STAGING_FILE}"
    else
        echo "$staging_playlist" > "$PLAYLIST_STAGING_FILE"
    fi

    # --- Extract tracks (handle both array and object formats) ---
    local track_count
    track_count=$(echo "$remote_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        tracks = data
    else:
        tracks = data.get('tracks', [])
    print(len(tracks))
except:
    print('0')
" 2>/dev/null)

    log "INFO" "Remote playlist: ${remote_playlist_id} (${track_count} tracks)"

    if [ "$track_count" -eq 0 ]; then
        log "WARN" "Remote playlist has 0 tracks — skipping sync"
        local failed
        failed=$(read_json_field "$CACHE_META_FILE" "statistics.failed_syncs")
        failed=$((failed + 1))
        update_cache_meta "statistics.failed_syncs" "$failed"
        flock -u 201
        flock -u 200
        return 1
    fi

    log "INFO" "Remote playlist: ${remote_playlist_id} (${track_count} tracks)"

    # --- Update staging metadata in cache_meta ---
    update_cache_meta "staging_cache.playlist_id"        "$(json_string "$remote_playlist_id")"
    update_cache_meta "staging_cache.version_hash"       "$(json_string "$remote_hash")"
    update_cache_meta "staging_cache.download_started_at" "$(json_string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
    update_cache_meta "staging_cache.tracks_total"       "$track_count"
    update_cache_meta "staging_cache.tracks_downloaded"  "0"
    update_cache_meta "staging_cache.progress_percent"   "0"

    # --- Clean and prepare staging ---
    clean_staging
    ensure_dirs

    # --- Download each track (using temp file to avoid subshell from pipe) ---
    local downloaded=0
    local verified=0
    local failed=0
    local total_bytes=0
    local failed_list=""
    local seen_fnames=""
    local tracks_temp
    tracks_temp=$(mktemp /tmp/radio-fetcher-tracks.XXXXXX)
    echo "$remote_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    tracks = data
else:
    tracks = data.get('tracks', [])
for t in tracks:
    print(json.dumps(t))
" 2>/dev/null > "$tracks_temp"

    while IFS= read -r track_json <&3; do
        [ -z "$track_json" ] && continue

        local track_id track_url track_filename track_hash
        track_id=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
        track_url=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
        track_filename=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('filename',''))" 2>/dev/null)
        track_hash=$(echo "$track_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha256',''))" 2>/dev/null)

        if [ -z "$track_filename" ]; then
            track_filename=$(basename "${track_url}")
        fi

        # --- H6: Safe filename validation (centralized) ---
        if ! validate_track_filename "$track_filename"; then
            log "ERROR" "Invalid track filename rejected: ${track_filename} — skipping"
            failed=$((failed + 1))
            continue
        fi
        # Duplicate check within this playlist
        case ":${seen_fnames}:" in
            *:${track_filename}:*)
                log "ERROR" "Duplicate filename: ${track_filename} — skipping"
                failed=$((failed + 1))
                continue
                ;;
        esac
        seen_fnames="${seen_fnames}:${track_filename}"

        local staging_path="${MUSIC_STAGING}/tracks/${track_filename}"
        local active_path="${MUSIC_ACTIVE}/tracks/${track_filename}"

        log "INFO" "Track $((downloaded + 1))/${track_count}: ${track_filename}"

        # Check if track already exists in active with same hash
        if [ -f "$active_path" ] && [ -n "$track_hash" ]; then
            local active_hash
            active_hash=$(sha256sum "$active_path" 2>/dev/null | cut -d' ' -f1)
            if [ "$active_hash" = "$track_hash" ]; then
                log "DEBUG" "Track unchanged in active — hardlinking"
                link_unchanged_track "$active_path" "$staging_path"
                local fsize
                fsize=$(stat -c%s "$active_path" 2>/dev/null || echo 0)
                total_bytes=$((total_bytes + fsize))
                downloaded=$((downloaded + 1))
                verified=$((verified + 1))
                continue
            fi
        fi

        # Download track
        if ! download_track "$track_url" "$staging_path" "$track_hash" > /dev/null; then
            failed=$((failed + 1))
            local track_id_json
            track_id_json=$(json_string "$track_id")
            if [ -n "$failed_list" ]; then failed_list="${failed_list},"; fi
            failed_list="${failed_list}${track_id_json}"
            log "ERROR" "Failed to download track: ${track_filename}"
            continue
        fi

        downloaded=$((downloaded + 1))
        verified=$((verified + 1))
        local fsize
        fsize=$(stat -c%s "$staging_path" 2>/dev/null || echo 0)
        total_bytes=$((total_bytes + fsize))

        # Update progress
        local pct=$((downloaded * 100 / track_count))
        update_cache_meta "staging_cache.tracks_downloaded" "$downloaded"
        update_cache_meta "staging_cache.progress_percent" "$pct"
        log "DEBUG" "Progress: ${pct}% (${downloaded}/${track_count})"
    done 3< "$tracks_temp"
    rm -f "$tracks_temp"

    # --- Check if any track failed ---
    if [ "$failed" -gt 0 ]; then
        log "ERROR" "${failed} track(s) failed to download — aborting sync"
        update_cache_meta "staging_cache.failed_tracks" "[${failed_list}]"
        local failed_total
        failed_total=$(read_json_field "$CACHE_META_FILE" "statistics.failed_syncs")
        failed_total=$((failed_total + 1))
        update_cache_meta "statistics.failed_syncs" "$failed_total"
        clean_staging
        reset_staging_cache
        log "INFO" "=== Sync cycle failed (${failed} failed tracks) ==="
        flock -u 201
        flock -u 200
        return 1
    fi

    # --- C2: Validate staging completeness before atomic swap ---
    if ! validate_staging "$track_count"; then
        log "ERROR" "Staging validation failed — aborting sync, active playlist intact"
        clean_staging
        reset_staging_cache
        local failed_total
        failed_total=$(read_json_field "$CACHE_META_FILE" "statistics.failed_syncs")
        failed_total=$((failed_total + 1))
        update_cache_meta "statistics.failed_syncs" "$failed_total"
        flock -u 201
        flock -u 200
        return 1
    fi

    # --- Recheck SSH/logout coordination immediately before atomic swap ---
    if ! cache_fetch_coordination_allowed "pre-swap check"; then
        log "INFO" "SSH coordination changed during download — aborting swap"
        clean_staging
        reset_staging_cache
        flock -u 201
        flock -u 200
        return 2
    fi

    # --- All tracks downloaded and verified — perform atomic swap ---
    log "INFO" "All ${downloaded} tracks downloaded and verified (${total_bytes} bytes)"

    # Update cache_meta staging as complete
    update_cache_meta "staging_cache.tracks_downloaded" "$downloaded"
    update_cache_meta "staging_cache.progress_percent" "100"

    # Atomic swap
    atomic_swap

    # --- Update cache_meta for active cache ---
    local now_8601
    now_8601=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local expires_8601
    expires_8601=$(date -u -d "+${CACHE_TTL_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)

    update_cache_meta "active_cache.playlist_id"     "$(json_string "$remote_playlist_id")"
    update_cache_meta "active_cache.version_hash"    "$(json_string "$remote_hash")"
    update_cache_meta "active_cache.downloaded_at"   "$(json_string "$now_8601")"
    update_cache_meta "active_cache.expires_at"      "$(json_string "$expires_8601")"
    update_cache_meta "active_cache.tracks_count"    "$downloaded"
    update_cache_meta "active_cache.total_size_bytes" "$total_bytes"
    update_cache_meta "active_cache.last_verified_at" "$(json_string "$now_8601")"
    update_cache_meta "active_cache.last_hash_check" "$(json_string "$remote_hash")"
    update_cache_meta "active_cache.integrity_verified" 'true'

    # Reset staging in cache_meta
    reset_staging_cache

    # Update statistics
    local successful
    successful=$(read_json_field "$CACHE_META_FILE" "statistics.successful_syncs")
    successful=$((successful + 1))
    update_cache_meta "statistics.successful_syncs" "$successful"
    update_cache_meta "statistics.last_successful_sync" "$(json_string "$now_8601")"

    local total_bytes_dl
    total_bytes_dl=$(read_json_field "$CACHE_META_FILE" "statistics.bytes_downloaded_total")
    total_bytes_dl=$((total_bytes_dl + total_bytes))
    update_cache_meta "statistics.bytes_downloaded_total" "$total_bytes_dl"

    # --- Copy updated playlist.active.json ---
    if [ -f "$PLAYLIST_STAGING_FILE" ]; then
        if $DRY_RUN; then
            log "DRY" "Would cp ${PLAYLIST_STAGING_FILE} → ${PLAYLIST_ACTIVE_FILE}"
        else
            cp "$PLAYLIST_STAGING_FILE" "$PLAYLIST_ACTIVE_FILE"
            log "INFO" "Updated ${PLAYLIST_ACTIVE_FILE}"
        fi
    fi

    # Reset cumulative runtime counter only when cache was previously empty
    # (expiration rebuild, SSH wipe recovery, or firstboot).  A content update
    # during normal operation must not extend the powered-on runtime budget.
    if [ "${prev_tracks_count:-0}" -eq 0 ]; then
        reset_cache_runtime
    else
        log "INFO" "Cache content updated — runtime counter preserved (prev_tracks=${prev_tracks_count})"
    fi

    log "INFO" "=== Sync cycle complete (new cache: ${downloaded} tracks, expires ${expires_8601}) ==="
    log_event "MEDIA_SYNC_COMPLETED" "cache_commit" "success" "none" \
        "tracks=${downloaded}"
    flock -u 201
    flock -u 200
    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    cd /tmp 2>/dev/null || true
    parse_args "$@"
    trap cleanup EXIT
    trap handle_signal TERM INT

    if $VALIDATE_ACTIVE_ONLY; then
        # Validation mode is deliberately independent of runtime
        # initialization: no config/auth, network, mkdir, metadata update, or
        # cache mutation is permitted. Logs go only to stderr.
        LOG=/dev/null
        if validate_active; then
            log "INFO" "Active cache validation succeeded"
            exit 0
        fi
        log "ERROR" "Active cache validation failed"
        exit 65
    fi

    if $DRY_RUN; then
        log "INFO" "DRY RUN MODE — no files will be modified"
    fi

    log "INFO" "radio-fetcher starting"

    load_config

    local device_id
    device_id=$(get_device_id)
    log "INFO" "Device identity loaded"

    # Open lock file descriptor for the lifetime of this process
    exec 200>"$LOCK_FILE"

    # Ensure directories
    ensure_dirs

    # Main loop
    while true; do
        _sc_exit=0
        sync_cycle || _sc_exit=$?
        if $ONCE; then
            log "INFO" "--once specified, exiting after single cycle"
            exit $_sc_exit
        fi
        log "DEBUG" "Sleeping ${PLAYLIST_SYNC_INTERVAL}s until next sync"
        sleep "$PLAYLIST_SYNC_INTERVAL"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
