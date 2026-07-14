#!/bin/bash
# firstboot.sh — One-shot provisioning for Sigil audio devices
#
# Responsibilities:
#   - Persists manufacturing identity in /etc/sigil/device.conf (idempotent)
#   - Creates initial state JSON files if missing (idempotent)
#   - Registers device with server once
#   - Creates /etc/logrotate.d/sigil
#   - All operations are idempotent: safe to re-run
#
# Usage:
#   firstboot.sh              # normal mode (full provisioning)
#   firstboot.sh --dry-run    # show what would be done
#   firstboot.sh --once       # same as no-flag (firstboot is always one-shot)
#   firstboot.sh --status     # show completion status and exit
# =============================================================================
set -euo pipefail

# --- Paths ---
SIGIL_STATE_DIR="/var/lib/sigil"
SIGIL_CONFIG_DIR="/etc/sigil"
LOG_DIR="/var/log/sigil"
AUDIO_CONF="${SIGIL_CONFIG_DIR}/audio.conf"
API_KEY_FILE="${SIGIL_API_KEY_FILE:-${SIGIL_CONFIG_DIR}/secrets/device-api-key}"

REGISTRATION_FILE="${SIGIL_STATE_DIR}/registration.json"
AUDIO_MODE_FILE="${SIGIL_STATE_DIR}/audio_mode.json"
PLAYBACK_STATE_FILE="${SIGIL_STATE_DIR}/playback_state.json"
PLAYLIST_ACTIVE_FILE="${SIGIL_STATE_DIR}/playlist.active.json"
PLAYLIST_STAGING_FILE="${SIGIL_STATE_DIR}/playlist.staging.json"
CACHE_META_FILE="${SIGIL_STATE_DIR}/cache_meta.json"
BT_STATE_FILE="${SIGIL_STATE_DIR}/bluetooth_state.json"
FIRSTBOOT_DONE_FILE="${SIGIL_STATE_DIR}/firstboot_completed.json"

LOGROTATE_FILE="/etc/logrotate.d/sigil"
DEVICE_CONF="${SIGIL_CONFIG_DIR}/device.conf"
IDENTITY_HELPER="${SIGIL_IDENTITY_HELPER:-/home/sigil/device_identity.py}"
PROVISION_TO_REMOVE=""

# --- Config defaults ---
SERVER_URL=""
API_KEY=""

# --- Flags ---
DRY_RUN=false
STATUS_ONLY=false

# ── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local level="${1:-INFO}"
    local msg="$2"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    echo "$line" >&2
}

die() {
    log "ERROR" "FATAL: $*"
    exit 1
}

load_config() {
    if [ ! -f "$AUDIO_CONF" ]; then
        log "WARN" "audio.conf not found at ${AUDIO_CONF} — using defaults"
        return 0
    fi
    while IFS='=' read -r key val; do
        key="${key// /}"
        val="${val//\"/}"
        val="${val//\'/}"
        case "$key" in
            SERVER_URL)      SERVER_URL="$val" ;;
        esac
    done < <(grep -v '^\s*#' "$AUDIO_CONF" | grep -v '^\s*$')
    if [ -r "$API_KEY_FILE" ]; then
        IFS= read -r API_KEY < "$API_KEY_FILE" || true
    fi
}

CURL_AUTH_CONFIG=""
init_curl_auth() {
    CURL_AUTH_CONFIG=""
    [ -n "$API_KEY" ] || return 0
    CURL_AUTH_CONFIG=$(mktemp /tmp/sigil-curl-auth.XXXXXX)
    chmod 600 "$CURL_AUTH_CONFIG"
    printf 'header = "x-api-key: %s"\n' "$API_KEY" > "$CURL_AUTH_CONFIG"
}
cleanup_curl_auth() {
    if [ -n "$CURL_AUTH_CONFIG" ] && [ -f "$CURL_AUTH_CONFIG" ]; then
        rm -f "$CURL_AUTH_CONFIG"
    fi
}

get_device_id() {
    python3 "$IDENTITY_HELPER" --device-conf "$DEVICE_CONF" \
        --audio-conf "$AUDIO_CONF" --field device_id
}

get_hostname() {
    hostname 2>/dev/null || echo "sigil"
}

ensure_state_dir() {
    if [ ! -d "$SIGIL_STATE_DIR" ]; then
        if $DRY_RUN; then
            log "DRY" "Would create: ${SIGIL_STATE_DIR}"
        else
            mkdir -p "$SIGIL_STATE_DIR"
            log "INFO" "Created state directory: ${SIGIL_STATE_DIR}"
        fi
    fi
}

apply_manufacturing_identity() {
    [ -r "$IDENTITY_HELPER" ] || die "Canonical identity helper missing: ${IDENTITY_HELPER}"
    local provision_file=""
    local candidate capability command
    for candidate in /boot/firmware/sigil_provision.json /boot/sigil_provision.json; do
        if [ -f "$candidate" ]; then
            provision_file="$candidate"
            break
        fi
    done

    if [ -n "$provision_file" ]; then
        command=(--validate-provision "$provision_file")
        if ! $DRY_RUN; then
            command=(--persist-provision "$provision_file")
        fi
        if ! capability=$(python3 "$IDENTITY_HELPER" --device-conf "$DEVICE_CONF" "${command[@]}"); then
            die "Invalid manufacturing provision; model_version and boolean capabilities.i2s_dac are required"
        fi
        if $DRY_RUN; then
            log "DRY" "Would atomically persist ${provision_file} to ${DEVICE_CONF} (root:sigil, 0640)"
        else
            local capability_helper="${SIGIL_AUDIO_CAPABILITY_HELPER:-/usr/local/bin/sigil-audio-capability.sh}"
            [ -r "$capability_helper" ] || die "Audio capability helper missing: ${capability_helper}"
            # shellcheck source=scripts/sigil-audio-capability.sh
            source "$capability_helper"
            sigil_write_i2s_capability "$AUDIO_CONF" "$capability" \
                || die "Could not persist capabilities.i2s_dac"
            chown root:sigil "$AUDIO_CONF"
            chmod 640 "$AUDIO_CONF"
            PROVISION_TO_REMOVE="$provision_file"
        fi
    elif ! python3 "$IDENTITY_HELPER" --device-conf "$DEVICE_CONF" \
        --audio-conf "$AUDIO_CONF" --field device_id >/dev/null; then
        die "Missing canonical manufacturing identity; legacy devices require explicit model_version migration"
    elif ! $DRY_RUN; then
        chown root:sigil "$DEVICE_CONF"
        chmod 640 "$DEVICE_CONF"
    fi
}

# Check if firstboot has already completed
is_firstboot_done() {
    if [ -f "$FIRSTBOOT_DONE_FILE" ]; then
        local completed
        completed=$(python3 -c "import json; print(json.load(open('${FIRSTBOOT_DONE_FILE}')).get('completed', 'false'))" 2>/dev/null || echo "false")
        [ "$completed" = "true" ] || [ "$completed" = "True" ]
        return $?
    fi
    return 1
}

# Mark firstboot as completed
mark_firstboot_done() {
    if $DRY_RUN; then
        log "DRY" "Would write: ${FIRSTBOOT_DONE_FILE}"
        return 0
    fi
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    python3 - "$FIRSTBOOT_DONE_FILE" "$now" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
now = sys.argv[2]
doc = {
    "_schema_version": "1.0",
    "completed": True,
    "at": now,
    "hostname": os.uname().nodename,
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    log "INFO" "Firstboot marked as completed"
}

# ── Step 1: registration state ───────────────────────────────────────────────

create_registration_state() {
    if [ -f "$REGISTRATION_FILE" ]; then
        log "INFO" "registration.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${REGISTRATION_FILE}"
        return 0
    fi
    log "INFO" "Creating registration state without duplicating identity"
    python3 - "$REGISTRATION_FILE" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "1.0",
    "registered": False,
    "registered_at": None,
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown root:sigil "$REGISTRATION_FILE"
    chmod 640 "$REGISTRATION_FILE"
    log "INFO" "registration state created at ${REGISTRATION_FILE}"
}

# ── Step 2: State files ─────────────────────────────────────────────────────

create_audio_mode_json() {
    if [ -f "$AUDIO_MODE_FILE" ]; then
        log "INFO" "audio_mode.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${AUDIO_MODE_FILE}"
        return 0
    fi
    log "INFO" "Creating initial audio_mode.json"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    python3 - "$AUDIO_MODE_FILE" "$now" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "1.0",
    "mode": "RADIO",
    "desired_mode": "RADIO",
    "reason": "firstboot",
    "since": sys.argv[2],
    "internet_available": False,
    "cache_status": "EMPTY",
    "active_playlist_version": None,
    "last_transition_at": sys.argv[2],
    "transition_count": 0,
    "last_error": None,
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown sigil:sigil "$AUDIO_MODE_FILE"
    chmod 644 "$AUDIO_MODE_FILE"
}

create_playback_state_json() {
    if [ -f "$PLAYBACK_STATE_FILE" ]; then
        log "INFO" "playback_state.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${PLAYBACK_STATE_FILE}"
        return 0
    fi
    log "INFO" "Creating initial playback_state.json"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    python3 - "$PLAYBACK_STATE_FILE" "$now" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "1.0",
    "mode": "RADIO",
    "radio": {
        "last_check": None,
        "last_hash": None,
    },
    "local": {
        "playlist_hash": None,
        "current_track_index": 0,
        "current_track_id": None,
        "position_seconds": 0,
        "last_updated": sys.argv[2],
    },
    "statistics": {
        "total_plays": 0,
        "mode_switches": 0,
        "last_server_contact": None,
    },
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown sigil:sigil "$PLAYBACK_STATE_FILE"
    chmod 644 "$PLAYBACK_STATE_FILE"
}

create_playlist_active_json() {
    if [ -f "$PLAYLIST_ACTIVE_FILE" ]; then
        log "INFO" "playlist.active.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${PLAYLIST_ACTIVE_FILE}"
        return 0
    fi
    log "INFO" "Creating initial playlist.active.json"
    python3 - "$PLAYLIST_ACTIVE_FILE" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "2.0",
    "playlist_id": None,
    "playlist_version": 0,
    "version_hash": None,
    "tracks": [],
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown sigil:sigil "$PLAYLIST_ACTIVE_FILE"
    chmod 644 "$PLAYLIST_ACTIVE_FILE"
}

create_playlist_staging_json() {
    if [ -f "$PLAYLIST_STAGING_FILE" ]; then
        log "INFO" "playlist.staging.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${PLAYLIST_STAGING_FILE}"
        return 0
    fi
    log "INFO" "Creating initial playlist.staging.json"
    python3 - "$PLAYLIST_STAGING_FILE" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "2.0",
    "playlist_id": None,
    "playlist_version": 0,
    "version_hash": None,
    "tracks": [],
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown sigil:sigil "$PLAYLIST_STAGING_FILE"
    chmod 644 "$PLAYLIST_STAGING_FILE"
}

create_cache_meta_json() {
    if [ -f "$CACHE_META_FILE" ]; then
        log "INFO" "cache_meta.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${CACHE_META_FILE}"
        return 0
    fi
    log "INFO" "Creating initial cache_meta.json"
    python3 - "$CACHE_META_FILE" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "1.0",
    "cache_policy": {
        "max_ttl_days": 7,
        "auto_renew": True,
        "delete_on_expire": True,
        "preserve_on_server_unavailable": False,
    },
    "active_cache": {
        "playlist_id": None,
        "version_hash": None,
        "downloaded_at": None,
        "expires_at": None,
        "tracks_count": 0,
        "total_size_bytes": 0,
        "last_verified_at": None,
        "last_hash_check": None,
        "integrity_verified": False,
    },
    "staging_cache": {
        "playlist_id": None,
        "version_hash": None,
        "download_started_at": None,
        "progress_percent": 0,
        "tracks_downloaded": 0,
        "tracks_total": 0,
        "failed_tracks": [],
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
        "last_runtime_check_uptime": 0
    },
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown sigil:sigil "$CACHE_META_FILE"
    chmod 644 "$CACHE_META_FILE"
}

create_bluetooth_state_json() {
    if [ -f "$BT_STATE_FILE" ]; then
        log "INFO" "bluetooth_state.json already exists — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${BT_STATE_FILE}"
        return 0
    fi
    log "INFO" "Creating initial bluetooth_state.json"
    python3 - "$BT_STATE_FILE" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
doc = {
    "_schema_version": "1.0",
    "preferred_device": {
        "mac": None,
        "name": None,
        "paired_at": None,
        "last_connected": None,
    },
    "connection_status": {
        "connected": False,
        "profile": None,
        "since": None,
    },
}

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    chown sigil:sigil "$BT_STATE_FILE"
    chmod 644 "$BT_STATE_FILE"
}

# ── Step 3: Device registration ─────────────────────────────────────────────

register_device() {
    if ! command -v curl &>/dev/null; then
        log "WARN" "curl not available — cannot register device"
        return 0
    fi

    if [ -z "$SERVER_URL" ]; then
        log "WARN" "SERVER_URL not configured — skipping registration"
        return 0
    fi
    if [ -z "$API_KEY" ]; then
        log "WARN" "Device API key not provisioned at ${API_KEY_FILE} — skipping registration"
        return 0
    fi

    # Check if already registered without duplicating identity metadata.
    if [ -f "$REGISTRATION_FILE" ]; then
        local registered
        registered=$(python3 -c "import json; print(json.load(open('${REGISTRATION_FILE}')).get('registered', False))" 2>/dev/null || echo "False")
        if [ "$registered" = "True" ] || [ "$registered" = "true" ]; then
            log "INFO" "Device already registered — skipping"
            return 0
        fi
    fi

    local payload
    if ! payload=$(python3 "$IDENTITY_HELPER" --device-conf "$DEVICE_CONF" \
        --audio-conf "$AUDIO_CONF" --registration); then
        log "ERROR" "Registration blocked: canonical identity is incomplete"
        return 1
    fi

    if $DRY_RUN; then
        log "DRY" "Would register device: POST ${SERVER_URL}/api/devices/register"
        log "DRY" "Payload: (redacted)"
        return 0
    fi

    log "INFO" "Registering device with server: ${SERVER_URL}/api/devices/register"
    local response
    response=$(curl -s -S -m 10 \
        -H "Content-Type: application/json" \
        --config "$CURL_AUTH_CONFIG" \
        -d "$payload" \
        "${SERVER_URL}/api/devices/register" 2>&1 || true)

    if echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') or d.get('registered') else 1)" 2>/dev/null; then
        log "INFO" "Device registered successfully"

        # Mark registration state without copying identity fields.
        python3 - "$REGISTRATION_FILE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" <<'PYEOF'
import json, os, sys, tempfile

file_path = sys.argv[1]
now = sys.argv[2]

with open(file_path) as f:
    doc = json.load(f)

doc['registered'] = True
doc['registered_at'] = now

dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
        log "INFO" "registration.json updated with registration status"
    else
        log "WARN" "Device registration failed or server unreachable"
        log "WARN" "Will retry on next firstboot run"
    fi
}

# ── Step 4: Logrotate ──────────────────────────────────────────────────────

create_logrotate() {
    if [ -f "$LOGROTATE_FILE" ]; then
        log "INFO" "logrotate config already exists at ${LOGROTATE_FILE} — skipping"
        return 0
    fi
    if $DRY_RUN; then
        log "DRY" "Would create: ${LOGROTATE_FILE}"
        return 0
    fi
    log "INFO" "Creating logrotate config at ${LOGROTATE_FILE}"
    cat > "$LOGROTATE_FILE" <<'EOF'
/var/log/sigil/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 640 sigil sigil
}

/var/log/bt-connect.log
/var/log/radio-stream.log
/var/log/audio-manager.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 644 sigil sigil
}
EOF
    chmod 644 "$LOGROTATE_FILE"
    log "INFO" "Logrotate config created at ${LOGROTATE_FILE}"
}

# ── Step 4b: Ensure ssh-monitor.service is active ───────────────────────────

ensure_run_sigil() {
    local dir="${SIGIL_RUN_DIR:-/run/sigil}"
    local wanted_owner="sigil"
    local wanted_group="sigil"
    local wanted_mode="0770"
    local wanted_stat_mode="${wanted_mode#0}"

    if $DRY_RUN; then
        log "DRY" "Would ensure ${dir} exists with mode ${wanted_mode} owner ${wanted_owner}:${wanted_group}"
        return 0
    fi

    # Create directory if it doesn't exist
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            log "ERROR" "Cannot create directory ${dir}"
            return 1
        }
        log "INFO" "Created ${dir}"
    fi

    # Always repair owner/group/mode — validate, repair, then verify.  This
    # directory owns the cross-service cache lock and SSH security markers, so
    # a best-effort repair would make the service state look healthy while the
    # sigil user is unable to coordinate cache operations.
    local fixed=false

    local current_owner current_group
    if ! current_owner=$(stat -c '%U' "$dir" 2>/dev/null); then
        log "ERROR" "Cannot stat owner for ${dir}"
        return 1
    fi
    if ! current_group=$(stat -c '%G' "$dir" 2>/dev/null); then
        log "ERROR" "Cannot stat group for ${dir}"
        return 1
    fi

    if [ "$current_owner" != "$wanted_owner" ]; then
        if ! chown "$wanted_owner" "$dir" 2>/dev/null; then
            log "ERROR" "Cannot chown ${dir} to ${wanted_owner}"
            return 1
        fi
        log "INFO" "Fixed owner: ${current_owner} → ${wanted_owner}"
        fixed=true
    fi
    if [ "$current_group" != "$wanted_group" ]; then
        if ! chgrp "$wanted_group" "$dir" 2>/dev/null; then
            log "ERROR" "Cannot chgrp ${dir} to ${wanted_group}"
            return 1
        fi
        log "INFO" "Fixed group: ${current_group} → ${wanted_group}"
        fixed=true
    fi

    local current_mode
    if ! current_mode=$(stat -c '%a' "$dir" 2>/dev/null); then
        log "ERROR" "Cannot stat mode for ${dir}"
        return 1
    fi
    if [ "$current_mode" != "$wanted_stat_mode" ]; then
        if ! chmod "$wanted_mode" "$dir" 2>/dev/null; then
            log "ERROR" "Cannot chmod ${dir} to ${wanted_mode}"
            return 1
        fi
        log "INFO" "Fixed mode: ${current_mode} → ${wanted_mode}"
        fixed=true
    fi

    # Do not trust successful repair commands alone: verify the effective
    # metadata that the services will observe.
    if ! current_owner=$(stat -c '%U' "$dir" 2>/dev/null); then
        log "ERROR" "Cannot verify owner for ${dir}"
        return 1
    fi
    if ! current_group=$(stat -c '%G' "$dir" 2>/dev/null); then
        log "ERROR" "Cannot verify group for ${dir}"
        return 1
    fi
    if ! current_mode=$(stat -c '%a' "$dir" 2>/dev/null); then
        log "ERROR" "Cannot verify mode for ${dir}"
        return 1
    fi
    if [ "$current_owner" != "$wanted_owner" ] || \
       [ "$current_group" != "$wanted_group" ] || \
       [ "$current_mode" != "$wanted_stat_mode" ]; then
        log "ERROR" "${dir} verification failed (owner=${current_owner}, group=${current_group}, mode=${current_mode}; expected ${wanted_owner}:${wanted_group} ${wanted_mode})"
        return 1
    fi

    if ! $fixed; then
        log "INFO" "${dir} already correct (owner=${wanted_owner}, group=${wanted_group}, mode=${wanted_mode})"
    else
        log "INFO" "Verified ${dir} (owner=${wanted_owner}, group=${wanted_group}, mode=${wanted_mode})"
    fi
    return 0
}

ensure_ssh_monitor() {
    if $DRY_RUN; then
        log "DRY" "Would enable and start ssh-monitor.service"
        return 0
    fi
    if systemctl is-enabled ssh-monitor.service &>/dev/null; then
        log "INFO" "ssh-monitor.service already enabled"
    else
        systemctl enable ssh-monitor.service 2>/dev/null || log "WARN" "Could not enable ssh-monitor.service"
        log "INFO" "ssh-monitor.service enabled"
    fi
    if ! systemctl is-active --quiet ssh-monitor.service &>/dev/null; then
        systemctl start ssh-monitor.service 2>/dev/null || log "WARN" "Could not start ssh-monitor.service"
        log "INFO" "ssh-monitor.service started"
    fi
}

# ── Step 5: Verify permissions ──────────────────────────────────────────────

verify_state_perms() {
    if $DRY_RUN; then
        log "DRY" "Would verify state file permissions"
        return 0
    fi
    local fix_count=0
    for f in "$AUDIO_MODE_FILE" "$PLAYBACK_STATE_FILE" "$PLAYLIST_ACTIVE_FILE" "$PLAYLIST_STAGING_FILE" "$CACHE_META_FILE" "$BT_STATE_FILE"; do
        if [ -f "$f" ]; then
            local owner
            owner=$(stat -c '%U:%G' "$f" 2>/dev/null || echo "")
            if [ "$owner" != "sigil:sigil" ]; then
                chown sigil:sigil "$f"
                fix_count=$((fix_count + 1))
            fi
        fi
    done
    if [ -f "$REGISTRATION_FILE" ]; then
        local owner
        owner=$(stat -c '%U:%G' "$REGISTRATION_FILE" 2>/dev/null || echo "")
        if [ "$owner" != "root:sigil" ]; then
            chown root:sigil "$REGISTRATION_FILE"
            fix_count=$((fix_count + 1))
        fi
    fi
    if [ $fix_count -gt 0 ]; then
        log "INFO" "Fixed permissions on ${fix_count} state file(s)"
    fi
}

# ── Step 5b: Enforce runtime permissions ─────────────────────────────────────

enforce_runtime_permissions() {
    if $DRY_RUN; then
        log "DRY" "Would enforce runtime permissions on key directories"
        return 0
    fi
    local fix_count=0

    # 1. /var/lib/sigil — state directory
    if [ -d "$SIGIL_STATE_DIR" ]; then
        local owner
        owner=$(stat -c '%U:%G' "$SIGIL_STATE_DIR" 2>/dev/null || echo "")
        if [ "$owner" != "sigil:sigil" ]; then
            chown sigil:sigil "$SIGIL_STATE_DIR"
            fix_count=$((fix_count + 1))
        fi
        local perms
        perms=$(stat -c '%a' "$SIGIL_STATE_DIR" 2>/dev/null || echo "")
        if [ "$perms" != "755" ]; then
            chmod 755 "$SIGIL_STATE_DIR"
            fix_count=$((fix_count + 1))
        fi
    fi

    # 2. /home/sigil/music — cache directories
    if [ -d "/home/sigil/music" ]; then
        owner=$(stat -c '%U:%G' "/home/sigil/music" 2>/dev/null || echo "")
        if [ "$owner" != "sigil:sigil" ]; then
            chown sigil:sigil "/home/sigil/music"
            fix_count=$((fix_count + 1))
        fi
        # Ensure correct ownership recursively (safe as music dir is owned by sigil)
        local wrong
        wrong=$(find /home/sigil/music -not -user sigil -o -not -group sigil 2>/dev/null | head -5)
        if [ -n "$wrong" ]; then
            chown -R sigil:sigil /home/sigil/music
            fix_count=$((fix_count + 1))
        fi
    fi

    # 3. /etc/sigil — config directory
    if [ -d "$SIGIL_CONFIG_DIR" ]; then
        owner=$(stat -c '%U:%G' "$SIGIL_CONFIG_DIR" 2>/dev/null || echo "")
        if [ "$owner" != "root:root" ]; then
            chown root:root "$SIGIL_CONFIG_DIR"
            fix_count=$((fix_count + 1))
        fi
        perms=$(stat -c '%a' "$SIGIL_CONFIG_DIR" 2>/dev/null || echo "")
        if [ "$perms" != "755" ]; then
            chmod 755 "$SIGIL_CONFIG_DIR"
            fix_count=$((fix_count + 1))
        fi
        # audio.conf — 640 root:sigil
        if [ -f "$AUDIO_CONF" ]; then
            owner=$(stat -c '%U:%G' "$AUDIO_CONF" 2>/dev/null || echo "")
            if [ "$owner" != "root:sigil" ]; then
                chown root:sigil "$AUDIO_CONF"
                fix_count=$((fix_count + 1))
            fi
            perms=$(stat -c '%a' "$AUDIO_CONF" 2>/dev/null || echo "")
            if [ "$perms" != "640" ]; then
                chmod 640 "$AUDIO_CONF"
                fix_count=$((fix_count + 1))
            fi
        fi
    fi

    # 4. /var/log/sigil — log directory
    if [ -d "$LOG_DIR" ]; then
        owner=$(stat -c '%U:%G' "$LOG_DIR" 2>/dev/null || echo "")
        if [ "$owner" != "sigil:sigil" ]; then
            chown sigil:sigil "$LOG_DIR"
            fix_count=$((fix_count + 1))
        fi
        perms=$(stat -c '%a' "$LOG_DIR" 2>/dev/null || echo "")
        if [ "$perms" != "750" ]; then
            chmod 750 "$LOG_DIR"
            fix_count=$((fix_count + 1))
        fi
        # Log files — 640 sigil:sigil
        local logfix
        logfix=$(find "$LOG_DIR" -type f \( -not -user sigil -o -not -group sigil \) 2>/dev/null | head -5)
        if [ -n "$logfix" ]; then
            chown sigil:sigil "$LOG_DIR"/*
            fix_count=$((fix_count + 1))
        fi
        logfix=$(find "$LOG_DIR" -type f ! -perm 640 2>/dev/null | head -5)
        if [ -n "$logfix" ]; then
            chmod 640 "$LOG_DIR"/*
            fix_count=$((fix_count + 1))
        fi
    fi

    if [ $fix_count -gt 0 ]; then
        log "INFO" "Fixed permissions on ${fix_count} runtime resource(s)"
    else
        log "INFO" "All runtime permissions correct"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--status]

Options:
  --dry-run   Show what would be done without making changes
  --status    Show firstboot completion status and exit
  --once      Same as no-flag (firstboot is always one-shot)
EOF
    exit 0
}

firstboot_main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --status)  STATUS_ONLY=true ;;
            --once)    ;;
            --help|-h) usage ;;
        esac
    done

if $STATUS_ONLY; then
    if is_firstboot_done; then
        echo "Firstboot: COMPLETED"
        if [ -f "$FIRSTBOOT_DONE_FILE" ]; then
            python3 -c "
import json
d = json.load(open('${FIRSTBOOT_DONE_FILE}'))
print(f\"  completed_at: {d.get('at', 'unknown')}\")
print(f\"  device_id:    {d.get('device_id', 'unknown')}\")
print(f\"  hostname:     {d.get('hostname', 'unknown')}\")
"
        fi
    else
        echo "Firstboot: NOT COMPLETED"
    fi
    for f in "$DEVICE_CONF" "$REGISTRATION_FILE" "$AUDIO_MODE_FILE" "$PLAYBACK_STATE_FILE" "$PLAYLIST_ACTIVE_FILE" "$PLAYLIST_STAGING_FILE" "$CACHE_META_FILE" "$BT_STATE_FILE" "$LOGROTATE_FILE"; do
        if [ -f "$f" ]; then
            echo "  EXISTS: $f"
        else
            echo "  MISSING: $f"
        fi
    done
    exit 0
fi

log "INFO" "=== firstboot starting ==="

# Load config
load_config
init_curl_auth
trap cleanup_curl_auth EXIT TERM INT

apply_manufacturing_identity

log "INFO" "Device ID: $(get_device_id)"
log "INFO" "Hostname: $(get_hostname)"

# Check if already completed
if is_firstboot_done; then
    log "INFO" "Firstboot already completed — verifying state files and runtime permissions"
    verify_state_perms
    enforce_runtime_permissions
    ensure_run_sigil
    ensure_ssh_monitor
    if ! $DRY_RUN; then
        register_device
    fi
    log "INFO" "=== firstboot complete (already done, state verified) ==="
    exit 0
fi

# Step 1: registration state (identity remains canonical in device.conf)
create_registration_state

# Step 2: State files
create_audio_mode_json
create_playback_state_json
create_playlist_active_json
create_playlist_staging_json
create_cache_meta_json
create_bluetooth_state_json

# Step 3: Logrotate
create_logrotate

# Step 4: Permissions
verify_state_perms
enforce_runtime_permissions
ensure_run_sigil
ensure_ssh_monitor

# Step 5: Device registration (only if not already registered)
if ! $DRY_RUN; then
    register_device
fi

# Mark firstboot as completed
mark_firstboot_done

if [ -n "$PROVISION_TO_REMOVE" ]; then
    rm -f -- "$PROVISION_TO_REMOVE"
    log "INFO" "Removed consumed manufacturing provision from boot"
fi

    log "INFO" "=== firstboot complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    firstboot_main "$@"
fi
