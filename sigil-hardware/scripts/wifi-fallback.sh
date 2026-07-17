#!/bin/bash
# SIGIL single-radio WiFi fallback state machine.
set -uo pipefail
IFS=$'\n\t'

VERSION="3.1.0"
LOG_TAG="[wifi-fallback]"
AP_INTERFACE="${SIGIL_WIFI_INTERFACE:-wlan0}"
AP_IP="${SIGIL_WIFI_AP_IP:-192.168.4.1}"
STATE_FILE="${SIGIL_WIFI_STATE_FILE:-/var/lib/sigil/wifi-fallback-state}"
INHIBIT_FILE="${SIGIL_WIFI_INHIBIT_FILE:-/run/sigil/wifi-fallback-inhibit.json}"
TRANSITION_LOCK="${SIGIL_WIFI_TRANSITION_LOCK:-/run/sigil/wifi-transition.lock}"
SERVICE_LOCK="${SIGIL_WIFI_SERVICE_LOCK:-/run/sigil/wifi-fallback.lock}"
NM_CONNECTION_DIR="${SIGIL_NM_CONNECTION_DIR:-/etc/NetworkManager/system-connections}"

CHECK_INTERVAL="${SIGIL_WIFI_CHECK_INTERVAL:-30}"
FAIL_THRESHOLD="${SIGIL_WIFI_FAIL_THRESHOLD:-4}"
SUCCESS_THRESHOLD="${SIGIL_WIFI_SUCCESS_THRESHOLD:-2}"
CONNECTION_GRACE_SECONDS="${SIGIL_WIFI_CONNECTION_GRACE_SECONDS:-90}"
AP_RECOVERY_INTERVAL="${SIGIL_WIFI_AP_RECOVERY_INTERVAL:-120}"
MAX_RECOVERY_BACKOFF="${SIGIL_WIFI_MAX_RECOVERY_BACKOFF:-1800}"
LOCAL_PROBE_INITIAL_BACKOFF="${SIGIL_WIFI_LOCAL_PROBE_INITIAL_BACKOFF:-30}"
LOCAL_PROBE_MAX_BACKOFF="${SIGIL_WIFI_LOCAL_PROBE_MAX_BACKOFF:-300}"
PROBE_TIMEOUT="${SIGIL_WIFI_PROBE_TIMEOUT:-4}"
RECOVERY_STABILIZATION_SECONDS="${SIGIL_WIFI_RECOVERY_STABILIZATION_SECONDS:-60}"
RECOVERY_CHECK_INTERVAL="${SIGIL_WIFI_RECOVERY_CHECK_INTERVAL:-5}"
CLIENT_OWNERSHIP_TIMEOUT="${SIGIL_WIFI_CLIENT_OWNERSHIP_TIMEOUT:-10}"
DNS_HOST_1="${SIGIL_WIFI_DNS_HOST_1:-deb.debian.org}"
DNS_HOST_2="${SIGIL_WIFI_DNS_HOST_2:-www.raspberrypi.com}"
HTTPS_ENDPOINT_1="${SIGIL_WIFI_HTTPS_ENDPOINT_1:-https://connectivitycheck.gstatic.com/generate_204}"
HTTPS_ENDPOINT_2="${SIGIL_WIFI_HTTPS_ENDPOINT_2:-https://www.debian.org/}"

DRY_RUN=0
ONE_SHOT=0
EXTERNAL_CLIENT_HANDOFF=0
PREPARE_EXTERNAL_CLIENT=0
RESTORE_EXTERNAL_AP=0
PERSIST_CLIENT_SECRET=0
PERSIST_PROFILE=""
PERSIST_PASSWORD_FILE=""
PROBE_STATE="CLIENT_CONNECTING"
PROBE_REASON="not_checked"
PROBE_GATEWAY=""
PROBE_FAMILY=""

declare -A WIFI_STATE=()

log() {
    printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_TAG" "$*"
}

state_defaults() {
    WIFI_STATE[STATE]="CLIENT_CONNECTING"
    WIFI_STATE[CLIENT_STATE]="CLIENT_CONNECTING"
    WIFI_STATE[REASON]="startup"
    WIFI_STATE[FAIL_COUNT]="0"
    WIFI_STATE[SUCCESS_COUNT]="0"
    WIFI_STATE[FAIL_STARTED_AT]="0"
    WIFI_STATE[AP_ACTIVE]="0"
    WIFI_STATE[NEXT_RETRY_AT]="0"
    WIFI_STATE[RECOVERY_BACKOFF]="$AP_RECOVERY_INTERVAL"
    WIFI_STATE[LOCAL_PROBE_BACKOFF]="$LOCAL_PROBE_INITIAL_BACKOFF"
    WIFI_STATE[NEXT_PROBE_AT]="0"
    WIFI_STATE[DEAD_PROFILE]=""
    WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="0"
    WIFI_STATE[UPDATED_AT]="0"
}

load_state() {
    state_defaults
    [ -f "$STATE_FILE" ] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            STATE|CLIENT_STATE|REASON|FAIL_COUNT|SUCCESS_COUNT|FAIL_STARTED_AT|AP_ACTIVE|NEXT_RETRY_AT|RECOVERY_BACKOFF|LOCAL_PROBE_BACKOFF|NEXT_PROBE_AT|DEAD_PROFILE|DEAD_PROFILE_DEACTIVATED|UPDATED_AT)
                WIFI_STATE[$key]="$value"
                ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    [ "$DRY_RUN" -eq 0 ] || return 0
    local directory temporary
    directory=$(dirname "$STATE_FILE")
    mkdir -p "$directory" || return 1
    temporary=$(mktemp "${directory}/.wifi-fallback-state.XXXXXX") || return 1
    chmod 640 "$temporary" || { rm -f "$temporary"; return 1; }
    if [ "$(id -u)" -eq 0 ] && getent group sigil >/dev/null 2>&1; then
        chown root:sigil "$temporary" || { rm -f "$temporary"; return 1; }
    fi
    {
        printf 'STATE=%s\n' "${WIFI_STATE[STATE]}"
        printf 'CLIENT_STATE=%s\n' "${WIFI_STATE[CLIENT_STATE]}"
        printf 'REASON=%s\n' "${WIFI_STATE[REASON]//$'\n'/ }"
        printf 'FAIL_COUNT=%s\n' "${WIFI_STATE[FAIL_COUNT]}"
        printf 'SUCCESS_COUNT=%s\n' "${WIFI_STATE[SUCCESS_COUNT]}"
        printf 'FAIL_STARTED_AT=%s\n' "${WIFI_STATE[FAIL_STARTED_AT]}"
        printf 'AP_ACTIVE=%s\n' "${WIFI_STATE[AP_ACTIVE]}"
        printf 'NEXT_RETRY_AT=%s\n' "${WIFI_STATE[NEXT_RETRY_AT]}"
        printf 'RECOVERY_BACKOFF=%s\n' "${WIFI_STATE[RECOVERY_BACKOFF]}"
        printf 'LOCAL_PROBE_BACKOFF=%s\n' "${WIFI_STATE[LOCAL_PROBE_BACKOFF]}"
        printf 'NEXT_PROBE_AT=%s\n' "${WIFI_STATE[NEXT_PROBE_AT]}"
        printf 'DEAD_PROFILE=%s\n' "${WIFI_STATE[DEAD_PROFILE]}"
        printf 'DEAD_PROFILE_DEACTIVATED=%s\n' "${WIFI_STATE[DEAD_PROFILE_DEACTIVATED]}"
        printf 'UPDATED_AT=%s\n' "${WIFI_STATE[UPDATED_AT]}"
    } > "$temporary" || { rm -f "$temporary"; return 1; }
    mv -f "$temporary" "$STATE_FILE"
}

persist_state() {
    local state="$1" reason="$2" now="$3"
    WIFI_STATE[STATE]="$state"
    WIFI_STATE[REASON]="$reason"
    WIFI_STATE[UPDATED_AT]="$now"
    save_state || {
        log "state persistence failed for state=${state} reason=${reason}"
        return 1
    }
    log "state=${state} reason=${reason} fail=${WIFI_STATE[FAIL_COUNT]} success=${WIFI_STATE[SUCCESS_COUNT]} next_retry=${WIFI_STATE[NEXT_RETRY_AT]}"
}

panel_transition_context_active() {
    local lock_probe_fd
    inhibit_active || {
        log "panel ownership request rejected: no active panel inhibit"
        return 1
    }

    # The panel must still own the canonical transition lock.  A successful
    # non-blocking acquisition proves it does not, so reject the handoff.
    if acquire_transition_lock lock_probe_fd; then
        release_transition_lock "$lock_probe_fd"
        log "panel ownership request rejected: transition lock not held"
        return 1
    fi
}

prepare_external_client_ownership() {
    panel_transition_context_active || return 1
    stop_ap_services || {
        log "panel client preparation failed: NetworkManager did not take ${AP_INTERFACE}"
        return 1
    }
    log "panel client preparation complete: NetworkManager owns ${AP_INTERFACE}"
}

restore_external_ap_ownership() {
    local now
    panel_transition_context_active || return 1
    load_state
    start_ap_services || {
        log "panel rollback failed: AP ownership could not be restored"
        return 1
    }
    if [ "${WIFI_STATE[AP_ACTIVE]}" != "1" ]; then
        now=$(date +%s)
        WIFI_STATE[AP_ACTIVE]="1"
        WIFI_STATE[CLIENT_STATE]="CLIENT_CONNECTING"
        WIFI_STATE[FAIL_COUNT]="0"
        WIFI_STATE[SUCCESS_COUNT]="0"
        WIFI_STATE[NEXT_RETRY_AT]="$((now + AP_RECOVERY_INTERVAL))"
        persist_state "AP_ACTIVE" "panel_client_rollback" "$now"
    fi
    log "panel rollback complete: AP ownership restored"
}

record_external_client_handoff() {
    local now
    panel_transition_context_active || return 1

    now=$(date +%s)
    load_state
    WIFI_STATE[STATE]="CLIENT_CONNECTING"
    WIFI_STATE[CLIENT_STATE]="CLIENT_CONNECTING"
    WIFI_STATE[REASON]="panel_client_handoff"
    WIFI_STATE[FAIL_COUNT]="0"
    WIFI_STATE[SUCCESS_COUNT]="0"
    WIFI_STATE[FAIL_STARTED_AT]="0"
    WIFI_STATE[AP_ACTIVE]="0"
    WIFI_STATE[NEXT_RETRY_AT]="0"
    WIFI_STATE[RECOVERY_BACKOFF]="$AP_RECOVERY_INTERVAL"
    WIFI_STATE[LOCAL_PROBE_BACKOFF]="$LOCAL_PROBE_INITIAL_BACKOFF"
    WIFI_STATE[NEXT_PROBE_AT]="0"
    WIFI_STATE[DEAD_PROFILE]=""
    WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="0"
    persist_state "CLIENT_CONNECTING" "panel_client_handoff" "$now"
}

persist_external_client_secret() {
    local profile="$1" password_file="$2" uuid connection_file run_dir sigil_uid
    panel_transition_context_active || return 1
    [ -n "$profile" ] && [ -n "$password_file" ] || return 2
    run_dir=$(dirname "$INHIBIT_FILE")
    sigil_uid=$(id -u sigil 2>/dev/null || id -u)
    uuid=$(nmcli -g connection.uuid connection show "$profile" 2>/dev/null | head -n 1) \
        || return 1
    [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1

    connection_file=$(python3 - "$password_file" "$run_dir" "$sigil_uid" \
        "$NM_CONNECTION_DIR" "$uuid" <<'PYEOF'
import os
import re
import stat
import sys
import tempfile

password_path, run_dir, expected_uid, connection_dir, expected_uuid = sys.argv[1:]
expected_uid = int(expected_uid)

def fail():
    raise SystemExit(1)

try:
    password_real = os.path.realpath(password_path)
    if os.path.dirname(password_real) != os.path.realpath(run_dir):
        fail()
    if not os.path.basename(password_real).startswith('.nmcli-password.'):
        fail()
    metadata = os.lstat(password_path)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != expected_uid
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or not 1 <= metadata.st_size <= 1024
    ):
        fail()
    flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(password_path, flags)
    try:
        raw = os.read(fd, 1025)
    finally:
        os.close(fd)
    prefix = b'802-11-wireless-security.psk:'
    if len(raw) > 1024 or not raw.startswith(prefix) or not raw.endswith(b'\n'):
        fail()
    password = raw[len(prefix):-1].decode('utf-8')
    encoded_length = len(password.encode('utf-8'))
    if '\x00' in password or '\r' in password or '\n' in password:
        fail()
    if not (8 <= encoded_length <= 63 or re.fullmatch(r'[0-9A-Fa-f]{64}', password)):
        fail()

    matches = []
    for name in os.listdir(connection_dir):
        if not name.endswith('.nmconnection'):
            continue
        path = os.path.join(connection_dir, name)
        item = os.lstat(path)
        if (
            not stat.S_ISREG(item.st_mode)
            or item.st_size > 65536
            or item.st_uid != os.geteuid()
            or item.st_gid != os.getegid()
        ):
            continue
        file_fd = os.open(path, flags)
        try:
            text = os.read(file_fd, 65537).decode('utf-8')
        finally:
            os.close(file_fd)
        section = None
        found_uuid = None
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith('[') and stripped.endswith(']'):
                section = stripped[1:-1]
            elif section == 'connection' and '=' in line:
                key, value = line.split('=', 1)
                if key.strip() == 'uuid':
                    found_uuid = value.strip()
        if found_uuid == expected_uuid:
            matches.append((path, item, text))
    if len(matches) != 1:
        fail()

    path, item, text = matches[0]
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.strip() == '[wifi-security]'), None)
    if start is None:
        fail()
    end = next(
        (i for i in range(start + 1, len(lines))
         if lines[i].strip().startswith('[') and lines[i].strip().endswith(']')),
        len(lines),
    )
    retained = []
    for line in lines[start + 1:end]:
        key = line.split('=', 1)[0].strip() if '=' in line else ''
        if key not in {'psk', 'psk-flags'}:
            retained.append(line)
    escaped = password.replace('\\', '\\\\').replace('\t', '\\t')
    replacement = retained + [f'psk={escaped}', 'psk-flags=0']
    output = '\n'.join(lines[:start + 1] + replacement + lines[end:]) + '\n'

    temporary_fd, temporary = tempfile.mkstemp(prefix='.sigil-wifi.', dir=connection_dir)
    try:
        os.fchmod(temporary_fd, 0o600)
        with os.fdopen(temporary_fd, 'w', encoding='utf-8', newline='\n') as handle:
            temporary_fd = -1
            handle.write(output)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = ''
        directory_fd = os.open(connection_dir, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    print(path)
except (OSError, UnicodeError, ValueError):
    fail()
PYEOF
    ) || return 1
    [ -n "$connection_file" ] || return 1
    nmcli connection load "$connection_file" >/dev/null 2>&1 || return 1
    log "panel client secret persisted for selected profile"
}

remove_stale_inhibit() {
    [ -e "$INHIBIT_FILE" ] || return 0
    rm -f "$INHIBIT_FILE" 2>/dev/null || true
}

inhibit_active() {
    [ -f "$INHIBIT_FILE" ] || return 1
    local record now pid start_time expires current_start
    record=$(python3 - "$INHIBIT_FILE" <<'PYEOF' 2>/dev/null
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
print(value.get("pid", ""), value.get("process_start_time", ""), value.get("expires_at", ""))
PYEOF
    ) || { remove_stale_inhibit; return 1; }
    IFS=' ' read -r pid start_time expires <<< "$record"
    now=$(date +%s)
    [[ "$pid" =~ ^[0-9]+$ && "$start_time" =~ ^[0-9]+$ && "$expires" =~ ^[0-9]+$ ]] \
        || { remove_stale_inhibit; return 1; }
    [ "$now" -lt "$expires" ] || { remove_stale_inhibit; return 1; }
    [ -r "/proc/${pid}/stat" ] || { remove_stale_inhibit; return 1; }
    current_start=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null) || {
        remove_stale_inhibit
        return 1
    }
    [ "$current_start" = "$start_time" ] || { remove_stale_inhibit; return 1; }
    return 0
}

acquire_transition_lock() {
    local __result_var="$1"
    local fd
    mkdir -p "$(dirname "$TRANSITION_LOCK")" || return 1
    exec {fd}>"$TRANSITION_LOCK" || return 1
    if ! flock -n "$fd"; then
        eval "exec ${fd}>&-"
        return 1
    fi
    printf -v "$__result_var" '%s' "$fd"
}

release_transition_lock() {
    local fd="$1"
    flock -u "$fd" 2>/dev/null || true
    eval "exec ${fd}>&-"
}

nm_associated() {
    local state
    state=$(nmcli -t -f GENERAL.STATE device show "$AP_INTERFACE" 2>/dev/null | head -1)
    [[ "$state" == *":100"* || "$state" == *"(connected)"* ]] && return 0
    iw dev "$AP_INTERFACE" link 2>/dev/null | grep -q '^Connected to '
}

has_client_address() {
    ip -o address show dev "$AP_INTERFACE" scope global 2>/dev/null \
        | grep -qE ' inet6? '
}

default_route() {
    local route gateway
    route=$(ip -4 route show default dev "$AP_INTERFACE" 2>/dev/null | head -1)
    if [ -n "$route" ]; then
        gateway=$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$route")
        [ -n "$gateway" ] && { printf '4 %s\n' "$gateway"; return 0; }
    fi
    route=$(ip -6 route show default dev "$AP_INTERFACE" 2>/dev/null | head -1)
    if [ -n "$route" ]; then
        gateway=$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$route")
        [ -n "$gateway" ] && { printf '6 %s\n' "$gateway"; return 0; }
    fi
    return 1
}

gateway_reachable() {
    local family="$1" gateway="$2"
    [ -n "$gateway" ] || return 1
    timeout "$PROBE_TIMEOUT" ping "-${family}" -c 1 -W "$PROBE_TIMEOUT" "$gateway" >/dev/null 2>&1
}

dns_resolves() {
    timeout "$PROBE_TIMEOUT" getent ahosts "$DNS_HOST_1" >/dev/null 2>&1 \
        || timeout "$PROBE_TIMEOUT" getent ahosts "$DNS_HOST_2" >/dev/null 2>&1
}

https_connectivity() {
    curl --fail --silent --show-error --output /dev/null \
        --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" \
        "$HTTPS_ENDPOINT_1" 2>/dev/null \
        || curl --fail --silent --show-error --output /dev/null \
            --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" \
            "$HTTPS_ENDPOINT_2" 2>/dev/null
}

probe_client_state() {
    local route gateway_ok=0 dns_ok=0
    PROBE_STATE="CLIENT_CONNECTING"
    PROBE_REASON="association_missing"
    PROBE_GATEWAY=""
    PROBE_FAMILY=""
    nm_associated || return 1
    PROBE_STATE="CLIENT_LINK_DEAD"
    PROBE_REASON="address_missing"
    has_client_address || return 1
    PROBE_REASON="default_route_missing"
    route=$(default_route) || return 1
    IFS=' ' read -r PROBE_FAMILY PROBE_GATEWAY <<< "$route"
    [ -n "$PROBE_FAMILY" ] && [ -n "$PROBE_GATEWAY" ] || return 1
    gateway_reachable "$PROBE_FAMILY" "$PROBE_GATEWAY" && gateway_ok=1
    dns_resolves && dns_ok=1
    if [ "$dns_ok" -eq 1 ] && https_connectivity; then
        PROBE_STATE="CLIENT_ONLINE"
        PROBE_REASON="internet_reachable"
        return 0
    fi
    if [ "$gateway_ok" -eq 1 ]; then
        PROBE_STATE="CLIENT_LOCAL_ONLY"
        PROBE_REASON="local_network_only"
        return 0
    fi
    PROBE_STATE="CLIENT_LINK_DEAD"
    PROBE_REASON="gateway_and_external_probes_failed"
    return 1
}

active_wifi_profile() {
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | awk -F: -v iface="$AP_INTERFACE" '$2 == iface {print $1; exit}'
}

saved_wifi_profile() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 == "802-11-wireless" || $2 == "wifi" || $2 == "wireless" {print $1; exit}'
}

start_ap_services() {
    [ "$DRY_RUN" -eq 0 ] || { log "DRY_RUN start AP"; return 0; }
    nmcli device disconnect "$AP_INTERFACE" >/dev/null 2>&1 || true
    nmcli device set "$AP_INTERFACE" managed no >/dev/null 2>&1 || return 1
    rfkill unblock wifi >/dev/null 2>&1 || true
    ip link set "$AP_INTERFACE" down >/dev/null 2>&1 || true
    ip addr flush dev "$AP_INTERFACE" || return 1
    ip link set "$AP_INTERFACE" up || return 1
    ip addr add "${AP_IP}/24" dev "$AP_INTERFACE" >/dev/null 2>&1 || true
    systemctl unmask hostapd >/dev/null 2>&1 || return 1
    systemctl is-active --quiet hostapd || systemctl start hostapd || return 1
    systemctl is-active --quiet dnsmasq || systemctl start dnsmasq || return 1
}

stop_ap_services() {
    [ "$DRY_RUN" -eq 0 ] || { log "DRY_RUN stop AP"; return 0; }
    if systemctl is-active --quiet hostapd; then systemctl stop hostapd || return 1; fi
    if systemctl is-active --quiet dnsmasq; then systemctl stop dnsmasq || return 1; fi
    ip addr flush dev "$AP_INTERFACE" >/dev/null 2>&1 || true
    nmcli device set "$AP_INTERFACE" managed yes >/dev/null 2>&1 || return 1
    rfkill unblock wifi >/dev/null 2>&1 || true
    wait_for_nm_ownership
}

nm_owns_interface() {
    local state
    state=$(nmcli -t -f GENERAL.STATE device show "$AP_INTERFACE" 2>/dev/null) \
        || return 1
    [[ "$state" != *unmanaged* && "$state" != *":10 "* && "$state" != "10 "* ]]
}

wait_for_nm_ownership() {
    local elapsed=0
    while (( elapsed <= CLIENT_OWNERSHIP_TIMEOUT )); do
        nm_owns_interface && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

ensure_ap_services() {
    local lock_fd rc=0
    [ "$DRY_RUN" -eq 0 ] || return 0
    if systemctl is-active --quiet hostapd \
        && systemctl is-active --quiet dnsmasq; then
        return 0
    fi
    inhibit_active && return 1
    acquire_transition_lock lock_fd || return 1
    if inhibit_active; then
        release_transition_lock "$lock_fd"
        return 1
    fi
    start_ap_services || rc=$?
    release_transition_lock "$lock_fd"
    return "$rc"
}

deactivate_dead_profile_once() {
    local profile
    profile=$(active_wifi_profile)
    [ -n "$profile" ] || return 0
    if [ "${WIFI_STATE[DEAD_PROFILE_DEACTIVATED]}" = "1" ] \
        && [ "${WIFI_STATE[DEAD_PROFILE]}" = "$profile" ]; then
        return 0
    fi
    [ "$DRY_RUN" -eq 1 ] || nmcli connection down id "$profile" >/dev/null 2>&1 || true
    WIFI_STATE[DEAD_PROFILE]="$profile"
    WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="1"
}

enter_ap() {
    local now="$1" reason="$2" lock_fd
    inhibit_active && return 1
    acquire_transition_lock lock_fd || return 1
    if inhibit_active; then
        release_transition_lock "$lock_fd"
        return 1
    fi
    if ! start_ap_services; then
        release_transition_lock "$lock_fd"
        return 1
    fi
    release_transition_lock "$lock_fd"
    WIFI_STATE[AP_ACTIVE]="1"
    WIFI_STATE[NEXT_RETRY_AT]="$((now + AP_RECOVERY_INTERVAL))"
    WIFI_STATE[RECOVERY_BACKOFF]="$AP_RECOVERY_INTERVAL"
    WIFI_STATE[FAIL_COUNT]="0"
    WIFI_STATE[SUCCESS_COUNT]="0"
    persist_state "AP_ACTIVE" "$reason" "$now"
}

restore_ap_after_failed_recovery() {
    local now="$1" reason="$2" backoff
    start_ap_services || return 1
    backoff="${WIFI_STATE[RECOVERY_BACKOFF]}"
    (( backoff < AP_RECOVERY_INTERVAL )) && backoff="$AP_RECOVERY_INTERVAL"
    backoff=$((backoff * 2))
    (( backoff > MAX_RECOVERY_BACKOFF )) && backoff="$MAX_RECOVERY_BACKOFF"
    WIFI_STATE[RECOVERY_BACKOFF]="$backoff"
    WIFI_STATE[NEXT_RETRY_AT]="$((now + backoff))"
    WIFI_STATE[AP_ACTIVE]="1"
    persist_state "AP_ACTIVE" "$reason" "$now"
}

attempt_ap_recovery() {
    local now="$1" lock_fd profile stable=0 elapsed=0
    acquire_transition_lock lock_fd || return 1
    if inhibit_active; then
        release_transition_lock "$lock_fd"
        return 1
    fi
    WIFI_STATE[STATE]="RECOVERY_PROBING"
    WIFI_STATE[CLIENT_STATE]="CLIENT_CONNECTING"
    WIFI_STATE[REASON]="known_profile_probe"
    WIFI_STATE[UPDATED_AT]="$now"
    save_state

    if ! stop_ap_services; then
        restore_ap_after_failed_recovery "$now" "recovery_stop_ap_failed"
        release_transition_lock "$lock_fd"
        return 1
    fi
    profile=$(saved_wifi_profile)
    if [ -z "$profile" ] || ! nmcli connection up id "$profile" >/dev/null 2>&1; then
        restore_ap_after_failed_recovery "$now" "recovery_profile_failed"
        release_transition_lock "$lock_fd"
        return 1
    fi

    while (( elapsed <= RECOVERY_STABILIZATION_SECONDS )); do
        probe_client_state
        case "$PROBE_STATE" in
            CLIENT_ONLINE|CLIENT_LOCAL_ONLY) stable=$((stable + 1)) ;;
            *) stable=0 ;;
        esac
        if (( stable >= SUCCESS_THRESHOLD )); then
            WIFI_STATE[AP_ACTIVE]="0"
            WIFI_STATE[FAIL_COUNT]="0"
            WIFI_STATE[SUCCESS_COUNT]="$stable"
            WIFI_STATE[FAIL_STARTED_AT]="0"
            WIFI_STATE[RECOVERY_BACKOFF]="$AP_RECOVERY_INTERVAL"
            WIFI_STATE[NEXT_RETRY_AT]="0"
            WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="0"
            WIFI_STATE[CLIENT_STATE]="$PROBE_STATE"
            persist_state "$PROBE_STATE" "$PROBE_REASON" "$(date +%s)"
            release_transition_lock "$lock_fd"
            return 0
        fi
        sleep "$RECOVERY_CHECK_INTERVAL"
        elapsed=$((elapsed + RECOVERY_CHECK_INTERVAL))
    done

    WIFI_STATE[CLIENT_STATE]="$PROBE_STATE"
    restore_ap_after_failed_recovery "$(date +%s)" "recovery_probe_failed"
    release_transition_lock "$lock_fd"
    return 1
}

handle_local_only() {
    local now="$1" backoff
    WIFI_STATE[FAIL_COUNT]="0"
    WIFI_STATE[FAIL_STARTED_AT]="0"
    WIFI_STATE[SUCCESS_COUNT]="0"
    WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="0"
    WIFI_STATE[CLIENT_STATE]="CLIENT_LOCAL_ONLY"
    backoff="${WIFI_STATE[LOCAL_PROBE_BACKOFF]}"
    (( backoff < LOCAL_PROBE_INITIAL_BACKOFF )) && backoff="$LOCAL_PROBE_INITIAL_BACKOFF"
    WIFI_STATE[NEXT_PROBE_AT]="$((now + backoff))"
    backoff=$((backoff * 2))
    (( backoff > LOCAL_PROBE_MAX_BACKOFF )) && backoff="$LOCAL_PROBE_MAX_BACKOFF"
    WIFI_STATE[LOCAL_PROBE_BACKOFF]="$backoff"
    persist_state "CLIENT_LOCAL_ONLY" "local_network_only" "$now"
}

handle_client_failure() {
    local now="$1" probe_state="$2" reason="$3" started elapsed
    WIFI_STATE[SUCCESS_COUNT]="0"
    WIFI_STATE[CLIENT_STATE]="$probe_state"
    WIFI_STATE[FAIL_COUNT]="$((WIFI_STATE[FAIL_COUNT] + 1))"
    started="${WIFI_STATE[FAIL_STARTED_AT]}"
    if [ "$started" -eq 0 ]; then
        started="$now"
        WIFI_STATE[FAIL_STARTED_AT]="$started"
    fi
    elapsed=$((now - started))
    if (( WIFI_STATE[FAIL_COUNT] < FAIL_THRESHOLD || elapsed < CONNECTION_GRACE_SECONDS )); then
        persist_state "CLIENT_CONNECTING" "$reason" "$now"
        return 0
    fi

    if [ "$probe_state" = "CLIENT_LINK_DEAD" ]; then
        deactivate_dead_profile_once
        WIFI_STATE[NEXT_RETRY_AT]="$((now + WIFI_STATE[RECOVERY_BACKOFF]))"
        WIFI_STATE[STATE]="CLIENT_LINK_DEAD"
        WIFI_STATE[REASON]="$reason"
        WIFI_STATE[UPDATED_AT]="$now"
        save_state
    fi
    enter_ap "$now" "$reason" || persist_state "CLIENT_CONNECTING" "transition_inhibited_or_busy" "$now"
}

run_cycle() {
    local now previous_state
    now=$(date +%s)
    load_state
    previous_state="${WIFI_STATE[STATE]}"

    if inhibit_active; then
        log "panel connection inhibited; transition owner retains canonical state"
        return 0
    fi

    if [ "${WIFI_STATE[AP_ACTIVE]}" = "1" ]; then
        ensure_ap_services || log "AP service reconciliation failed"
        if (( now >= WIFI_STATE[NEXT_RETRY_AT] )); then
            attempt_ap_recovery "$now" || true
        else
            persist_state "AP_ACTIVE" "recovery_cooldown" "$now"
        fi
        return 0
    fi

    if [ "${WIFI_STATE[STATE]}" = "CLIENT_LOCAL_ONLY" ] \
        && (( now < WIFI_STATE[NEXT_PROBE_AT] )); then
        persist_state "CLIENT_LOCAL_ONLY" "local_network_only_backoff" "$now"
        return 0
    fi

    probe_client_state
    case "$PROBE_STATE" in
        CLIENT_ONLINE)
            WIFI_STATE[FAIL_COUNT]="0"
            WIFI_STATE[FAIL_STARTED_AT]="0"
            WIFI_STATE[SUCCESS_COUNT]="$((WIFI_STATE[SUCCESS_COUNT] + 1))"
            WIFI_STATE[LOCAL_PROBE_BACKOFF]="$LOCAL_PROBE_INITIAL_BACKOFF"
            WIFI_STATE[NEXT_PROBE_AT]="0"
            WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="0"
            WIFI_STATE[CLIENT_STATE]="CLIENT_ONLINE"
            if [ "$previous_state" = "CLIENT_LOCAL_ONLY" ] \
                && (( WIFI_STATE[SUCCESS_COUNT] < SUCCESS_THRESHOLD )); then
                persist_state "CLIENT_LOCAL_ONLY" "internet_recovery_stabilizing" "$now"
            else
                persist_state "CLIENT_ONLINE" "$PROBE_REASON" "$now"
            fi
            ;;
        CLIENT_LOCAL_ONLY)
            handle_local_only "$now"
            ;;
        CLIENT_LINK_DEAD|CLIENT_CONNECTING)
            handle_client_failure "$now" "$PROBE_STATE" "$PROBE_REASON"
            ;;
    esac
}

usage() {
    printf 'Usage: %s [--oneshot|--dry-run|--prepare-client|--restore-ap|--external-client-handoff|--persist-client-secret PROFILE PASSWORD_FILE]\n' "$(basename "$0")"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --oneshot) ONE_SHOT=1 ;;
            --dry-run) DRY_RUN=1; ONE_SHOT=1 ;;
            --prepare-client) PREPARE_EXTERNAL_CLIENT=1 ;;
            --restore-ap) RESTORE_EXTERNAL_AP=1 ;;
            --external-client-handoff) EXTERNAL_CLIENT_HANDOFF=1 ;;
            --persist-client-secret)
                [ "$#" -ge 3 ] || { usage; return 2; }
                PERSIST_CLIENT_SECRET=1
                PERSIST_PROFILE="$2"
                PERSIST_PASSWORD_FILE="$3"
                shift 2
                ;;
            -h|--help) usage; return 1 ;;
            *) printf 'unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@" || return $?
    if [ "$PREPARE_EXTERNAL_CLIENT" -eq 1 ]; then
        prepare_external_client_ownership
        return
    fi
    if [ "$RESTORE_EXTERNAL_AP" -eq 1 ]; then
        restore_external_ap_ownership
        return
    fi
    if [ "$EXTERNAL_CLIENT_HANDOFF" -eq 1 ]; then
        record_external_client_handoff
        return
    fi
    if [ "$PERSIST_CLIENT_SECRET" -eq 1 ]; then
        persist_external_client_secret "$PERSIST_PROFILE" "$PERSIST_PASSWORD_FILE"
        return
    fi
    mkdir -p "$(dirname "$SERVICE_LOCK")" || return 1
    exec 8>"$SERVICE_LOCK" || return 1
    flock -n 8 || { log "another wifi-fallback process is active"; return 1; }
    log "version=${VERSION} interval=${CHECK_INTERVAL} fail_threshold=${FAIL_THRESHOLD} grace=${CONNECTION_GRACE_SECONDS}"
    if [ "$ONE_SHOT" -eq 1 ]; then
        run_cycle
        return
    fi
    while true; do
        run_cycle
        sleep "$CHECK_INTERVAL"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
