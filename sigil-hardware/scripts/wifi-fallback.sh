#!/bin/bash
# SIGIL single-radio WiFi fallback state machine.
set -uo pipefail
IFS=$'\n\t'

VERSION="3.3.0"
LOG_TAG="[wifi-fallback]"
WIFI_DEFAULTS_FILE="${SIGIL_WIFI_DEFAULTS_FILE:-/etc/sigil/wifi-fallback.conf}"
if [ -r "$WIFI_DEFAULTS_FILE" ]; then
    # Root-owned manufacturing defaults; contains no credentials.
    # shellcheck source=conf/wifi-fallback.conf
    source "$WIFI_DEFAULTS_FILE"
fi
AP_INTERFACE="${SIGIL_WIFI_INTERFACE:-wlan0}"
AP_IP="${SIGIL_WIFI_AP_IP:-192.168.4.1}"
STATE_FILE="${SIGIL_WIFI_STATE_FILE:-/var/lib/sigil/wifi-fallback-state}"
WIFI_CONTROL_SOCKET="${SIGIL_WIFI_CONTROL_SOCKET:-/run/sigil/wifi-control.sock}"
WIFI_CONTROL_STATE="${SIGIL_WIFI_CONTROL_STATE:-/run/sigil/wifi-control-state.json}"
INHIBIT_FILE="${SIGIL_WIFI_INHIBIT_FILE:-/run/sigil/wifi-fallback-inhibit.json}"
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
PROBE_STATE="CLIENT_CONNECTING"
PROBE_REASON="not_checked"
PROBE_GATEWAY=""
PROBE_FAMILY=""

declare -A WIFI_STATE=()

interface_available() {
    [ -d "${SIGIL_WIFI_SYS_CLASS_NET:-/sys/class/net}/${AP_INTERFACE}" ]
}

# panel_scan and disable_power_save moved to sigil-wifi-control.py
# (the single-owner daemon).  No panel path invokes these directly.

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
    WIFI_STATE[LAST_SUCCESSFUL_PROFILE]=""
    WIFI_STATE[UPDATED_AT]="0"
}

load_state() {
    state_defaults
    [ -f "$STATE_FILE" ] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            STATE|CLIENT_STATE|REASON|FAIL_COUNT|SUCCESS_COUNT|FAIL_STARTED_AT|AP_ACTIVE|NEXT_RETRY_AT|RECOVERY_BACKOFF|LOCAL_PROBE_BACKOFF|NEXT_PROBE_AT|DEAD_PROFILE|DEAD_PROFILE_DEACTIVATED|LAST_SUCCESSFUL_PROFILE|UPDATED_AT)
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
        printf 'LAST_SUCCESSFUL_PROFILE=%s\n' "${WIFI_STATE[LAST_SUCCESSFUL_PROFILE]//$'\n'/ }"
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

# panel_transition_context_active, record_external_client_handoff,
# persist_external_client_secret — all deleted in favour of the
# single-owner daemon (sigil-wifi-control).  The panel communicates
# exclusively via Unix socket; secret persistence uses O_NOFOLLOW-safe
# descriptor paths within the daemon.

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

# start_ap_services, stop_ap_services, nm_owns_interface, wait_for_nm_ownership,
# ensure_ap_services, deactivate_dead_profile_once, enter_ap,
# restore_ap_after_failed_recovery, attempt_ap_recovery
# — all deleted.  All wlan0 and NM mutations are now exclusive to
# sigil-wifi-control.service (single-owner daemon).
# wifi-fallback sends socket commands to request transitions.

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

# ---------------------------------------------------------------------------
# Socket helpers — communicate with sigil-wifi-control (single-owner daemon)
# ---------------------------------------------------------------------------

_send_socket_command() {
    local cmd_json="$1"
    local socket_path="${WIFI_CONTROL_SOCKET:-/run/sigil/wifi-control.sock}"
    python3 - "$socket_path" "$cmd_json" <<'PYEOF' 2>/dev/null \
        || echo '{"error":"socket_failure","accepted":false}'
import json, socket, sys
sock = sys.argv[1]
cmd = sys.argv[2]
try:
    cmd_obj = json.loads(cmd)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(sock)
    s.sendall(json.dumps(cmd_obj).encode() + b'\n')
    data = s.recv(65536)
    s.close()
    print(data.decode())
except Exception as e:
    print(json.dumps({'error': 'socket_error: ' + str(e), 'accepted': False}))
PYEOF
}

_read_daemon_state() {
    # Populates DAEMON_STATE bash associative array from the daemon state file.
    # Caller must declare -A DAEMON_STATE before calling.
    DAEMON_STATE=()
    [ -f "$WIFI_CONTROL_STATE" ] || return 1
    local phase success message
    phase=$(python3 - "$WIFI_CONTROL_STATE" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
for k in ('phase', 'success', 'message'):
    print(k, '=', d.get(k, ''))
PYEOF
    ) || return 1
    while IFS='= ' read -r key value; do
        [ -n "$key" ] && DAEMON_STATE["$key"]="$value"
    done <<< "$phase"
    [ -n "${DAEMON_STATE[phase]:-}" ]
}


# ---------------------------------------------------------------------------
# Policy/watchdog cycle — socket-only mutation requests
# ---------------------------------------------------------------------------

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

    # Threshold exceeded — request AP restore from daemon
    local resp
    resp=$(_send_socket_command '{"command":"restore_ap"}')
    local accepted state_val
    accepted=$(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('accepted') else 'false')" 2>/dev/null)
    state_val=$(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null)

    if [ "$accepted" = "true" ] && [ "$state_val" = "ap_active" ]; then
        log "socket restore_ap accepted; entering AP mode"
        WIFI_STATE[AP_ACTIVE]="1"
        WIFI_STATE[NEXT_RETRY_AT]="$((now + WIFI_STATE[RECOVERY_BACKOFF]))"
        WIFI_STATE[FAIL_COUNT]="0"
        WIFI_STATE[SUCCESS_COUNT]="0"
        persist_state "AP_ACTIVE" "restore_ap_via_socket" "$now"
    else
        log "FAIL restore_ap rejected or unavailable: $(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)"
        persist_state "CLIENT_CONNECTING" "transition_inhibited_or_busy" "$now"
    fi
}

run_cycle() {
    local now previous_state active_profile
    now=$(date +%s)
    load_state

    # Synchronise with daemon state — detect panel-initiated handoffs
    declare -A DAEMON_STATE=()
    _read_daemon_state || true

    if [ "${DAEMON_STATE[phase]:-}" = "connected" ] && [ "${WIFI_STATE[AP_ACTIVE]}" = "1" ]; then
        log "daemon reports connected; resetting fallback state (panel handoff)"
        WIFI_STATE[STATE]="CLIENT_CONNECTING"
        WIFI_STATE[CLIENT_STATE]="CLIENT_CONNECTING"
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
        active_profile=$(active_wifi_profile)
        [ -z "$active_profile" ] || WIFI_STATE[LAST_SUCCESSFUL_PROFILE]="$active_profile"
        persist_state "CLIENT_CONNECTING" "panel_client_handoff" "$now"
        return 0
    fi

    if [ "${DAEMON_STATE[phase]:-}" = "ap_active" ] && [ "${WIFI_STATE[AP_ACTIVE]}" = "0" ]; then
        log "daemon restored AP; synchronising fallback state"
        WIFI_STATE[AP_ACTIVE]="1"
        persist_state "AP_ACTIVE" "daemon_restored_ap" "$now"
        return 0
    fi

    previous_state="${WIFI_STATE[STATE]}"

    if inhibit_active; then
        log "panel connection inhibited; transition owner retains canonical state"
        return 0
    fi

    if [ "${WIFI_STATE[AP_ACTIVE]}" = "1" ]; then
        # Send ensure_ap (idempotent) — daemon verifies services
        local ensure_resp
        ensure_resp=$(_send_socket_command '{"command":"ensure_ap"}')
        local ensure_ok
        ensure_ok=$(printf '%s' "$ensure_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('accepted') else 'false')" 2>/dev/null)
        if [ "$ensure_ok" != "true" ]; then
            log "ensure_ap socket command failed: $(printf '%s' "$ensure_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)"
        fi

        if (( now >= WIFI_STATE[NEXT_RETRY_AT] )); then
            log "AP active and retry time reached; requesting recover_client"
            local recover_resp state_val
            recover_resp=$(_send_socket_command '{"command":"recover_client"}')
            state_val=$(printf '%s' "$recover_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null)
            local accepted_val
            accepted_val=$(printf '%s' "$recover_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('accepted') else 'false')" 2>/dev/null)

            if [ "$state_val" = "connected" ]; then
                active_profile=$(active_wifi_profile)
                WIFI_STATE[AP_ACTIVE]="0"
                WIFI_STATE[FAIL_COUNT]="0"
                WIFI_STATE[SUCCESS_COUNT]="0"
                WIFI_STATE[FAIL_STARTED_AT]="0"
                WIFI_STATE[RECOVERY_BACKOFF]="$AP_RECOVERY_INTERVAL"
                WIFI_STATE[NEXT_RETRY_AT]="0"
                WIFI_STATE[DEAD_PROFILE_DEACTIVATED]="0"
                [ -z "$active_profile" ] || WIFI_STATE[LAST_SUCCESSFUL_PROFILE]="$active_profile"
                persist_state "CLIENT_ONLINE" "recovery_success_via_socket" "$now"
            elif [ "$state_val" = "ap_active" ]; then
                # Recovery failed, daemon restored AP
                WIFI_STATE[AP_ACTIVE]="1"
                local backoff="${WIFI_STATE[RECOVERY_BACKOFF]}"
                (( backoff < AP_RECOVERY_INTERVAL )) && backoff="$AP_RECOVERY_INTERVAL"
                backoff=$((backoff * 2))
                (( backoff > MAX_RECOVERY_BACKOFF )) && backoff="$MAX_RECOVERY_BACKOFF"
                WIFI_STATE[RECOVERY_BACKOFF]="$backoff"
                WIFI_STATE[NEXT_RETRY_AT]="$((now + backoff))"
                persist_state "AP_ACTIVE" "recovery_failed_daemon_restored" "$now"
            else
                log "recover_client response unexpected state=$state_val accepted=$accepted_val"
                persist_state "AP_ACTIVE" "recovery_cooldown" "$now"
            fi
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
            active_profile=$(active_wifi_profile)
            [ -z "$active_profile" ] || WIFI_STATE[LAST_SUCCESSFUL_PROFILE]="$active_profile"
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
    printf 'Usage: %s [--oneshot|--dry-run]\n' "$(basename "$0")"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --oneshot) ONE_SHOT=1 ;;
            --dry-run) DRY_RUN=1; ONE_SHOT=1 ;;
            -h|--help) usage; return 1 ;;
            *) printf 'unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@" || return $?
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
