#!/bin/bash
# Behavioral tests for the production single-radio WiFi state machine and panel transition.
set -uo pipefail
# Production functions are sourced and invoked dynamically by this harness.
# shellcheck disable=SC1091,SC2034,SC2317

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TEST_ROOT=$(mktemp -d /tmp/sigil-wifi-fallback.XXXXXX)
MOCK_BIN="${TEST_ROOT}/bin"
MOCK_STATE="${TEST_ROOT}/mock"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$TEST_ROOT/run" "$TEST_ROOT/var"

cat > "${MOCK_BIN}/nmcli" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/nmcli_calls"
case "$*" in
    "-t -f GENERAL.STATE device show wlan0")
        if [ -f "$MOCK_STATE/nm_unmanaged" ]; then
            echo 'GENERAL.STATE:10 (unmanaged)'
        elif [ -f "$MOCK_STATE/associated" ]; then
            echo 'GENERAL.STATE:100 (connected)'
        else
            echo 'GENERAL.STATE:30 (disconnected)'
        fi
        ;;
    "-t -f NAME,DEVICE connection show --active")
        [ -f "$MOCK_STATE/active_profile" ] && echo 'KnownNet:wlan0'
        ;;
    "-t -f NAME,TYPE connection show")
        [ -f "$MOCK_STATE/no_saved_profiles" ] || echo 'KnownNet:802-11-wireless'
        ;;
    "-g connection.uuid connection show KnownNet")
        echo '00000000-0000-4000-8000-000000000001'
        ;;
    connection\ load\ *) exit 0 ;;
    "connection down id KnownNet") exit 0 ;;
    "device connect wlan0")
        if [ -f "$MOCK_STATE/recovery_success" ]; then
            touch "$MOCK_STATE/active_profile"
            touch "$MOCK_STATE/associated" "$MOCK_STATE/address" "$MOCK_STATE/route" \
                "$MOCK_STATE/gateway_ok" "$MOCK_STATE/dns_ok" "$MOCK_STATE/https_ok"
            exit 0
        fi
        exit 1
        ;;
    con\ up\ KnownNet\ passwd-file\ *|"con up KnownNet")
        [ ! -f "$MOCK_STATE/panel_up_fail" ]
        ;;
    *) exit 0 ;;
esac
EOF
cat > "${MOCK_BIN}/ip" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/ip_calls"
case "$*" in
    "-o address show dev wlan0 scope global")
        if [ -f "$MOCK_STATE/ipv6" ]; then
            echo '3: wlan0 inet6 2001:db8::2/64 scope global'
        elif [ -f "$MOCK_STATE/address" ]; then
            echo '3: wlan0 inet 192.0.2.2/24 scope global'
        fi
        ;;
    "-4 route show default dev wlan0")
        [ -f "$MOCK_STATE/route" ] && [ ! -f "$MOCK_STATE/ipv6" ] \
            && echo 'default via 192.0.2.1 dev wlan0'
        ;;
    "-6 route show default dev wlan0")
        [ -f "$MOCK_STATE/route" ] && [ -f "$MOCK_STATE/ipv6" ] \
            && echo 'default via fe80::1 dev wlan0'
        ;;
    *) exit 0 ;;
esac
EOF
cat > "${MOCK_BIN}/iw" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/iw_calls"
case "$*" in
    dev\ wlan0\ link)
        [ -f "$MOCK_STATE/associated" ] && echo 'Connected to 00:11:22:33:44:55'
        ;;
    dev\ wlan0\ set\ power_save\ off|dev\ wlan0\ set\ power_save\ on|dev\ wlan0\ set\ type\ *)
        # Mutation detected — signal the test
        printf 'iw mutation: %s\n' "$*" >&2
        touch "$MOCK_STATE/iw_mutation_detected"
        ;;
    dev\ wlan0\ scan|dev\ wlan0\ scan\ *)
        # Scan is read-only; pass through
        echo 'BSS 00:11:22:33:44:55'
        ;;
    *)
        # Read-only or unknown — no mutation
        ;;
esac
EOF
cat > "${MOCK_BIN}/modprobe" <<'EOF'
#!/bin/bash
# modprobe is always a mutation (kernel module load)
printf 'modprobe mutation: %s\n' "$*" >&2
touch "$MOCK_STATE/modprobe_mutation_detected"
exit 0
EOF
cat > "${MOCK_BIN}/ping" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/ping_calls"
[ -f "$MOCK_STATE/gateway_ok" ]
EOF
cat > "${MOCK_BIN}/getent" <<'EOF'
#!/bin/bash
[ "${1:-}" = ahosts ] && [ -f "$MOCK_STATE/dns_ok" ]
EOF
cat > "${MOCK_BIN}/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/curl_calls"
[ -f "$MOCK_STATE/https_ok" ]
EOF
cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "${MOCK_BIN}/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/systemctl_calls"
case "${1:-}" in
    is-active) [ -f "$MOCK_STATE/service_${3:-}" ] ;;
    start) touch "$MOCK_STATE/service_${2:-}" ;;
    stop) rm -f "$MOCK_STATE/service_${2:-}" ;;
    unmask) exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "${MOCK_BIN}/rfkill" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${MOCK_BIN}/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${MOCK_BIN}/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/sudo_calls"
exec "$@"
EOF
cat > "${MOCK_BIN}/wifi-fallback-helper" <<'EOF'
#!/bin/bash
exec bash "$SIGIL_TEST_WIFI_FALLBACK_SCRIPT" "$@"
EOF
# Daemon state file mock — tests can write phase to control handoff detection
DAEMON_STATE_FILE="${TEST_ROOT}/run/wifi-control-state.json"
export SIGIL_WIFI_CONTROL_STATE="$DAEMON_STATE_FILE"
cat > "$DAEMON_STATE_FILE" <<'EOF'
{"phase":"idle","success":null,"message":"mock daemon"}
EOF
chmod +x "${MOCK_BIN}"/*

export MOCK_STATE PATH="${MOCK_BIN}:${PATH}"
export SIGIL_TEST_WIFI_FALLBACK_SCRIPT="${ROOT}/scripts/wifi-fallback.sh"
export SIGIL_WIFI_STATE_FILE="${TEST_ROOT}/var/state"
export SIGIL_WIFI_INHIBIT_FILE="${TEST_ROOT}/run/inhibit.json"
export SIGIL_WIFI_TRANSITION_LOCK="${TEST_ROOT}/run/transition.lock"
export SIGIL_WIFI_SERVICE_LOCK="${TEST_ROOT}/run/service.lock"
export SIGIL_NM_CONNECTION_DIR="${TEST_ROOT}/nm-connections"
export SIGIL_WIFI_FALLBACK_HELPER="${MOCK_BIN}/wifi-fallback-helper"
export SIGIL_WIFI_CONNECT_INHIBIT_SECONDS=30
export SIGIL_WIFI_CONNECT_STABILIZATION_SECONDS=2
export SIGIL_WIFI_CONNECT_STABLE_CHECKS=2
export SIGIL_WIFI_CONNECT_CHECK_INTERVAL=0
export SIGIL_WIFI_FAIL_THRESHOLD=3
export SIGIL_WIFI_SUCCESS_THRESHOLD=2
export SIGIL_WIFI_CONNECTION_GRACE_SECONDS=0
export SIGIL_WIFI_AP_RECOVERY_INTERVAL=120
export SIGIL_WIFI_MAX_RECOVERY_BACKOFF=480
export SIGIL_WIFI_LOCAL_PROBE_INITIAL_BACKOFF=30
export SIGIL_WIFI_LOCAL_PROBE_MAX_BACKOFF=120
export SIGIL_WIFI_PROBE_TIMEOUT=1
export SIGIL_WIFI_RECOVERY_STABILIZATION_SECONDS=2
export SIGIL_WIFI_RECOVERY_CHECK_INTERVAL=1
mkdir -p "$SIGIL_NM_CONNECTION_DIR"
cat > "${SIGIL_NM_CONNECTION_DIR}/KnownNet.nmconnection" <<'EOF'
[connection]
id=KnownNet
uuid=00000000-0000-4000-8000-000000000001
type=wifi

[wifi]
ssid=KnownNet

[wifi-security]
key-mgmt=wpa-psk

[ipv4]
method=auto
EOF
chmod 600 "${SIGIL_NM_CONNECTION_DIR}/KnownNet.nmconnection"

source "${ROOT}/scripts/wifi-fallback.sh"

# Override _send_socket_command with a mock that records and returns
# controlled responses.  Tests call set_socket_response() to configure.
SOCKET_RESPONSE='{"accepted":true,"state":"ap_active"}'
SOCKET_RESPONSE_FILE="${TEST_ROOT}/run/socket_response.json"
set_socket_response() {
    printf '%s' "$1" > "$SOCKET_RESPONSE_FILE"
}
set_socket_response '{"accepted":true,"state":"ap_active"}'

_send_socket_command() {
    local cmd_json="$1"
    # Record the command
    printf '%s\n' "$cmd_json" >> "${MOCK_STATE}/socket_commands"
    # Return the configured response
    if [ -f "$SOCKET_RESPONSE_FILE" ]; then
        cat "$SOCKET_RESPONSE_FILE"
    else
        echo '{"accepted":true,"state":"ap_active"}'
    fi
}

reset_case() {
    rm -f "${MOCK_STATE}"/* "$STATE_FILE" "$INHIBIT_FILE"
    : > "${MOCK_STATE}/nmcli_calls"
    : > "${MOCK_STATE}/systemctl_calls"
    : > "${MOCK_STATE}/ip_calls"
    : > "${MOCK_STATE}/iw_calls"
    : > "${MOCK_STATE}/ping_calls"
    : > "${MOCK_STATE}/curl_calls"
    : > "${MOCK_STATE}/sudo_calls"
    : > "${MOCK_STATE}/panel_output"
    : > "${MOCK_STATE}/socket_commands"
    rm -f "${MOCK_STATE}/iw_mutation_detected" "${MOCK_STATE}/modprobe_mutation_detected"
    set_socket_response '{"accepted":true,"state":"ap_active"}'
    # Reset daemon state to idle for handoff tests
    printf '{"phase":"idle","success":null,"message":"mock daemon"}' > "$DAEMON_STATE_FILE"
}

set_online() {
    touch "${MOCK_STATE}/associated" "${MOCK_STATE}/address" "${MOCK_STATE}/route" \
        "${MOCK_STATE}/gateway_ok" "${MOCK_STATE}/dns_ok" "${MOCK_STATE}/https_ok"
}

set_local_only() {
    touch "${MOCK_STATE}/associated" "${MOCK_STATE}/address" "${MOCK_STATE}/route" \
        "${MOCK_STATE}/gateway_ok"
}

set_dead_gateway() {
    touch "${MOCK_STATE}/associated" "${MOCK_STATE}/address" "${MOCK_STATE}/route" \
        "${MOCK_STATE}/active_profile"
}

state_is() {
    load_state
    [ "${WIFI_STATE[STATE]}" = "$1" ]
}

run_test() {
    local name="$1" fn="$2"
    if ( reset_case; "$fn" ); then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$name"
    fi
}

test_online() {
    set_online
    run_cycle
    state_is CLIENT_ONLINE && [ ! -s "${MOCK_STATE}/socket_commands" ]
}

test_zero_traffic_healthy() {
    set_online
    run_cycle
    state_is CLIENT_ONLINE && ! rg -q 'RX|TX|byte' "$STATE_FILE"
}

test_ipv6_online() {
    set_online
    touch "${MOCK_STATE}/ipv6"
    run_cycle
    state_is CLIENT_ONLINE \
        && grep -q -- '-6 -c 1' "${MOCK_STATE}/ping_calls"
}

test_blocked_gateway_icmp_with_https_is_online() {
    set_online
    rm -f "${MOCK_STATE}/gateway_ok"
    run_cycle
    state_is CLIENT_ONLINE
}

test_local_only_no_ap() {
    set_local_only
    run_cycle
    run_cycle
    state_is CLIENT_LOCAL_ONLY \
        && grep -q '^REASON=local_network_only' "$STATE_FILE" \
        && [ ! -s "${MOCK_STATE}/socket_commands" ]
}

test_local_only_requires_stable_recovery() {
    set_local_only
    run_cycle
    set_online
    load_state
    WIFI_STATE[NEXT_PROBE_AT]=0
    save_state
    run_cycle
    state_is CLIENT_LOCAL_ONLY || return 1
    grep -q '^REASON=internet_recovery_stabilizing' "$STATE_FILE" || return 1
    run_cycle
    state_is CLIENT_ONLINE
}

test_temporary_failures_do_not_start_ap() {
    run_cycle
    run_cycle
    state_is CLIENT_CONNECTING && [ ! -s "${MOCK_STATE}/socket_commands" ]
}

test_threshold_starts_ap() {
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && grep -q 'restore_ap' "${MOCK_STATE}/socket_commands"
}

test_fresh_boot_without_profile_starts_ap() {
    touch "${MOCK_STATE}/no_saved_profiles"
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && grep -q 'restore_ap' "${MOCK_STATE}/socket_commands"
}

test_connected_dead_gateway_is_link_dead_transition() {
    set_dead_gateway
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && grep -q '^CLIENT_STATE=CLIENT_LINK_DEAD' "$STATE_FILE" \
        && grep -q 'restore_ap' "${MOCK_STATE}/socket_commands"
}

test_no_profile_deactivation_by_fallback() {
    set_dead_gateway
    run_cycle; run_cycle; run_cycle; run_cycle
    # DEAD_PROFILE_DEACTIVATED was removed — profile deactivation
    # is now exclusive to sigil-wifi-control (deactivate_profile socket command)
    [ ! -f "${MOCK_STATE}/socket_commands" ] \
        || ! grep -q 'deactivate_profile' "${MOCK_STATE}/socket_commands"
}

write_ap_state() {
    load_state
    WIFI_STATE[STATE]="AP_ACTIVE"
    WIFI_STATE[AP_ACTIVE]="1"
    WIFI_STATE[NEXT_RETRY_AT]="$1"
    WIFI_STATE[RECOVERY_BACKOFF]="120"
    save_state
    touch "${MOCK_STATE}/service_hostapd" "${MOCK_STATE}/service_dnsmasq"
}

test_recovery_cooldown_respected() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    run_cycle
    # ensure_ap sent but not recover_client (cooldown not reached)
    grep -q 'ensure_ap' "${MOCK_STATE}/socket_commands" \
        && ! grep -q 'recover_client' "${MOCK_STATE}/socket_commands"
}

test_successful_ap_recovery() {
    write_ap_state 0
    touch "${MOCK_STATE}/active_profile"
    # Configure socket to return connected for recover_client
    set_socket_response '{"accepted":true,"state":"connected","message":"Recovery connected"}'
    run_cycle
    state_is CLIENT_ONLINE \
        && grep -q 'recover_client' "${MOCK_STATE}/socket_commands" \
        && grep -q '^LAST_SUCCESSFUL_PROFILE=KnownNet$' "$STATE_FILE"
}

test_failed_recovery_restores_ap_once() {
    write_ap_state 0
    # Configure socket to return ap_active for recover_client (recovery failed)
    set_socket_response '{"accepted":false,"state":"ap_active","message":"Recovery failed"}'
    run_cycle
    state_is AP_ACTIVE \
        && grep -q 'recover_client' "${MOCK_STATE}/socket_commands" \
        && grep -q '^RECOVERY_BACKOFF=240' "$STATE_FILE"
}

test_active_ap_ensure_is_idempotent() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    run_cycle
    local ensure_count1
    ensure_count1=$(grep -c 'ensure_ap' "${MOCK_STATE}/socket_commands" || true)
    run_cycle
    local ensure_count2
    ensure_count2=$(grep -c 'ensure_ap' "${MOCK_STATE}/socket_commands" || true)
    # Two AP cycles → two ensure_ap commands (daemon handles idempotency)
    [ "$ensure_count2" -eq $((ensure_count1 + 1)) ]
}

test_restore_ap_sent_on_threshold() {
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && grep -q 'restore_ap' "${MOCK_STATE}/socket_commands"
}

test_no_mutations_from_fallback() {
    run_cycle; run_cycle; run_cycle
    # Zero direct mutation commands from wifi-fallback to systemctl/ip/nmcli/iw/modprobe
    ! grep -q 'systemctl start\|systemctl stop\|ip link\|ip addr\|nmcli device\|nmcli connection\|modprobe' \
        "${MOCK_STATE}/systemctl_calls" "${MOCK_STATE}/ip_calls" "${MOCK_STATE}/nmcli_calls" \
        "${MOCK_STATE}/iw_calls" 2>/dev/null
    # Also check mutation markers
    [ ! -f "${MOCK_STATE}/iw_mutation_detected" ] || return 1
    [ ! -f "${MOCK_STATE}/modprobe_mutation_detected" ] || return 1
}

test_duplicate_fallback_process_refused() {
    local lock_fd
    exec {lock_fd}>"$SERVICE_LOCK"
    flock -n "$lock_fd"
    if main --oneshot; then
        flock -u "$lock_fd"
        eval "exec ${lock_fd}>&-"
        return 1
    fi
    flock -u "$lock_fd"
    eval "exec ${lock_fd}>&-"
}

write_inhibit() {
    local expires="$1" start pid="$BASHPID"
    start=$(awk '{print $22}' "/proc/${pid}/stat")
    printf '{"pid":%d,"process_start_time":%s,"expires_at":%s}\n' \
        "$pid" "$start" "$expires" > "$INHIBIT_FILE"
}

run_panel_connect() {
    local expected_success="$1" secret="handoff-password-not-for-logs"
    if ! PANEL_EXPECT_SUCCESS="$expected_success" PANEL_SECRET="$secret" ROOT="$ROOT" \
        python3 - <<'PYEOF' >"${MOCK_STATE}/panel_output" 2>&1
import importlib.util
import os
from unittest.mock import patch

root = os.environ['ROOT']
spec = importlib.util.spec_from_file_location(
    'sigil_wifi_handoff_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

OP_ID = 'test-handoff-op-id'

# Mock the socket call to simulate sigil-wifi-control accepting the request
def mock_send_command(cmd, **kwargs):
    if cmd == 'connect':
        return {'accepted': True, 'operation_id': OP_ID}
    return {'error': 'unknown command'}

# Mock state reading to simulate completion (sigil-wifi-control wrote this)
mock_state = {
    'operation_id': OP_ID,
    'phase': 'connected',
    'success': True,
    'message': 'Conectado',
}

with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
     patch.object(wifi, '_read_control_state', return_value=mock_state), \
     patch.object(wifi.time, 'sleep', return_value=None):
    success, _message = wifi.connect_wifi('KnownNet', os.environ['PANEL_SECRET'])

expected = os.environ['PANEL_EXPECT_SUCCESS'] == '1'
assert success is expected, (success, _message)
PYEOF
    then
        cat "${MOCK_STATE}/panel_output" >&2
        return 1
    fi
}

test_inhibit_blocks_ap() {
    write_inhibit "$(( $(date +%s) + 120 ))"
    run_cycle; run_cycle; run_cycle
    # When inhibit is active, cycle returns early without sending socket commands
    state_is CLIENT_CONNECTING && [ ! -s "${MOCK_STATE}/socket_commands" ]
}

test_expired_inhibit_removed() {
    write_inhibit "$(( $(date +%s) - 1 ))"
    run_cycle
    [ ! -e "$INHIBIT_FILE" ] && state_is CLIENT_CONNECTING
}

test_daemon_handoff_detected() {
    # Simulate daemon completing a panel-initiated connection by
    # writing the daemon state file and running a fallback cycle
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    # Daemon state shows connected → handoff
    printf '{"phase":"connected","success":true,"message":"Conectado","connectivity":{"associated":true}}' \
        > "$DAEMON_STATE_FILE"
    run_cycle
    state_is CLIENT_CONNECTING || return 1
    [ "${WIFI_STATE[AP_ACTIVE]}" = 0 ] || return 1
    [ "${WIFI_STATE[CLIENT_STATE]}" = CLIENT_CONNECTING ] || return 1
    grep -q '^REASON=panel_client_handoff$' "$STATE_FILE" || return 1
    grep -q '^FAIL_COUNT=0$' "$STATE_FILE" || return 1
    grep -q '^NEXT_RETRY_AT=0$' "$STATE_FILE" || return 1
    grep -q '^RECOVERY_BACKOFF=120$' "$STATE_FILE" || return 1
    # No socket commands sent (handoff detected before inhibit check)
    [ ! -s "${MOCK_STATE}/socket_commands" ] || return 1
    run_cycle
    # After handoff, probe finds client online
    state_is CLIENT_ONLINE \
        && [ "${WIFI_STATE[AP_ACTIVE]}" = 0 ]
}

test_daemon_ap_restore_synced() {
    # Simulate daemon restoring AP (e.g. after failed recovery from another component)
    load_state
    WIFI_STATE[AP_ACTIVE]="0"
    WIFI_STATE[STATE]="CLIENT_CONNECTING"
    save_state
    # Daemon state shows ap_active
    printf '{"phase":"ap_active","success":true,"message":"AP restored"}' \
        > "$DAEMON_STATE_FILE"
    run_cycle
    state_is AP_ACTIVE && [ "${WIFI_STATE[AP_ACTIVE]}" = 1 ]
}

test_static_no_forbidden_mutations() {
    local script="${ROOT}/scripts/wifi-fallback.sh"
    local errors=0
    # Static invariant: wifi-fallback must never execute wlan0/NM mutations
    for pattern in \
        'ip link set' \
        'ip addr add' \
        'ip addr flush' \
        'nmcli device connect' \
        'nmcli device disconnect' \
        'nmcli device set' \
        'nmcli connection up' \
        'nmcli connection down' \
        'nmcli connection load' \
        'systemctl start hostapd' \
        'systemctl stop hostapd' \
        'systemctl start dnsmasq' \
        'systemctl stop dnsmasq' \
        'modprobe'
    do
        # Forbid pattern on non-comment lines
        if grep -n "$pattern" "$script" 2>/dev/null \
            | grep -qvE '^[0-9]+:[[:space:]]*#'; then
            printf '  FAIL: forbidden pattern found: %s\n' "$pattern" >&2
            errors=$((errors + 1))
        fi
    done
    [ "$errors" -eq 0 ]
}

test_panel_uses_exclusive_socket_path() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    run_panel_connect 1 || return 1
    # No sudo calls for wifi operations — panel uses socket exclusively
    ! grep -q 'wifi-fallback.sh' "${MOCK_STATE}/sudo_calls" || return 1
    ! grep -q 'nmcli' "${MOCK_STATE}/sudo_calls" || return 1
    ! grep -q '^systemctl\|^ip \|^iw ' "${MOCK_STATE}/sudo_calls" || return 1
}

test_client_ownership_is_exclusive() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    # Simulate daemon completing a connection (handoff)
    printf '{"phase":"connected","success":true,"message":"Conectado","connectivity":{"associated":true}}' \
        > "$DAEMON_STATE_FILE"
    run_cycle
    # wifi-fallback detects daemon handoff, resets to CLIENT_CONNECTING
    state_is CLIENT_CONNECTING \
        && [ "${WIFI_STATE[AP_ACTIVE]}" = 0 ] \
        && [ ! -s "${MOCK_STATE}/socket_commands" ]
}

test_static_mac_policy_never_blocks_client_ownership() {
    local policy="${ROOT}/conf/99-sigil-mac-fixed.conf"
    grep -qx 'wifi.scan-rand-mac-address=no' "$policy" \
        && grep -qx 'wifi.cloned-mac-address=permanent' "$policy" \
        && ! grep -Eq 'unmanaged-devices|managed[[:space:]]*=[[:space:]]*false' "$policy" \
        && grep -q 'unmanaged-devices.*wlan0' "${ROOT}/install.sh"
}

test_panel_connect_failure_reports_error() {
    # Panel reports the error returned by sigil-wifi-control via socket
    ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.util
import os
from unittest.mock import patch

root = os.environ['ROOT']
spec = importlib.util.spec_from_file_location(
    'sigil_wifi_fail_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

# Mock socket to return error
def mock_send_command(cmd, **kwargs):
    if cmd == 'connect':
        return {'error': 'busy', 'accepted': False,
                'message': 'Otra transición WiFi está en progreso'}
    return {'error': 'unknown command'}

with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
     patch.object(wifi.time, 'sleep', return_value=None):
    success, message = wifi.connect_wifi('KnownNet', 'dummy-secret')

assert not success, 'expected failure'
assert message == 'Otra transición WiFi está en progreso', message
PYEOF
}

test_panel_no_sudo_paths_exist() {
    # Verify the panel has no sudo-based fallback for any wifi operation
    ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.util
import os
import re

root = os.environ['ROOT']
spec = importlib.util.spec_from_file_location(
    'sigil_wifi_sudo_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

source = (root + '/panel/wifi.py')
with open(source, encoding='utf-8') as f:
    text = f.read()

# Remove docstrings (both """ and ''') so they don't trigger false positives
text_no_docs = re.sub(
    r'""".*?"""|\'\'\'.*?\'\'\'',
    '',
    text,
    flags=re.DOTALL,
)

# No executable sudo calls for any wifi operation
exec_lines = [l for l in text_no_docs.splitlines()
              if l.strip() and not l.strip().startswith('#')]
exec_text = '\n'.join(exec_lines)
assert 'sudo' not in exec_text, 'panel wifi.py must not contain executable sudo calls'
assert 'WIFI_FALLBACK_HELPER' not in text, (
    'panel wifi.py must not reference WIFI_FALLBACK_HELPER'
)
PYEOF
}

test_panel_socket_busy_returns_busy_message() {
    # When sigil-wifi-control returns busy, the panel propagates the message.
    ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.util
import os
from unittest.mock import patch

root = os.environ['ROOT']
spec = importlib.util.spec_from_file_location(
    'sigil_wifi_busy_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

def mock_send_command(cmd, **kwargs):
    if cmd == 'connect':
        return {'error': 'busy', 'accepted': False,
                'message': 'Otra transición WiFi está en progreso'}
    return {'error': 'unknown command'}

with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
     patch.object(wifi.time, 'sleep', return_value=None):
    success, message = wifi.connect_wifi('KnownNet', 'never-used-secret')
assert not success
assert message == 'Otra transición WiFi está en progreso', message
PYEOF
}

test_panel_credentials_never_reach_logs_or_argv() {
    local secret="handoff-password-not-for-logs"
    ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.util
import logging
import os
from unittest.mock import patch

root = os.environ['ROOT']
secret = 'handoff-password-not-for-logs'

spec = importlib.util.spec_from_file_location(
    'sigil_wifi_credential_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

OP_ID = 'cred-test-op-id'

def mock_send_command(cmd, **kwargs):
    if cmd == 'connect':
        # Verify password is passed to the socket (required for connect)
        assert 'password' in kwargs
        return {'accepted': True, 'operation_id': OP_ID}
    return {'error': 'unknown command'}

mock_state = {
    'operation_id': OP_ID,
    'phase': 'connected',
    'success': True,
    'message': 'Conectado',
}

log_entries = []
class Capture(logging.Handler):
    def emit(self, record):
        log_entries.append(record.getMessage())
wifi.logger.addHandler(Capture())

try:
    with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
         patch.object(wifi, '_read_control_state', return_value=mock_state), \
         patch.object(wifi.time, 'sleep', return_value=None):
        success, message = wifi.connect_wifi('KnownNet', secret)
    assert success, message
    # Verify secret does not appear in any log
    for entry in log_entries:
        assert secret not in entry, f'Secret leaked to log: {entry}'
    # Verify secret does not appear in the return message
    assert secret not in message, f'Secret leaked to message: {message}'
finally:
    wifi.logger.removeHandler(Capture())
PYEOF
}

test_panel_secret_is_not_exposed_via_socket() {
    # The panel sends credentials via the Unix socket (not argv).
    # Verify the socket payload does not leak the secret in logs or metadata.
    ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.util
import json
import logging
import os
from unittest.mock import patch

root = os.environ['ROOT']
secret = 'socket-secret-not-for-logs'

spec = importlib.util.spec_from_file_location(
    'sigil_wifi_secret_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

OP_ID = 'secret-test-op-id'

def mock_send_command(cmd, **kwargs):
    if cmd == 'connect':
        # Verify password is in kwargs (passed to socket)
        assert 'password' in kwargs
        assert kwargs['password'] == secret
        return {'accepted': True, 'operation_id': OP_ID}
    return {'error': 'unknown command'}

mock_state = {
    'operation_id': OP_ID,
    'phase': 'connected',
    'success': True,
    'message': 'Conectado',
}

log_entries = []
class Capture(logging.Handler):
    def emit(self, record):
        log_entries.append(record.getMessage())
wifi.logger.addHandler(Capture())

try:
    with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
         patch.object(wifi, '_read_control_state', return_value=mock_state), \
         patch.object(wifi.time, 'sleep', return_value=None):
        success, message = wifi.connect_wifi('KnownNet', secret)
    assert success, message
    for entry in log_entries:
        assert secret not in entry, f'Secret leaked to log: {entry}'
    assert secret not in message, f'Secret leaked to message: {message}'
finally:
    wifi.logger.removeHandler(Capture())
PYEOF
}

test_panel_socket_transition_contract() {
    ROI="$ROOT" ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.util
import logging
import os
from unittest.mock import patch

root = os.environ['ROOT']

spec = importlib.util.spec_from_file_location(
    'sigil_wifi_contract_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

OP_ID = 'contract-test-op-id'

def mock_send_command(cmd, **kwargs):
    assert 'password' in kwargs or cmd != 'connect', \
        'connect must include password'
    if cmd == 'connect':
        return {'accepted': True, 'operation_id': OP_ID}
    return {'error': 'unknown command'}

# Test 1: Successful transition
def mock_state_success():
    return {
        'operation_id': OP_ID,
        'phase': 'connected',
        'success': True,
        'message': 'Conectado',
        'connectivity': {
            'associated': True,
            'ip_acquired': True,
            'gateway_reachable': True,
            'dns_available': True,
            'local_only': False,
            'internet_online': True,
        },
    }

log_entries = []
class Capture(logging.Handler):
    def emit(self, record):
        log_entries.append(record.getMessage())
wifi.logger.addHandler(Capture())

try:
    secret = 'test-password-not-for-logs'
    with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
         patch.object(wifi, '_read_control_state', side_effect=mock_state_success), \
         patch.object(wifi.time, 'sleep', return_value=None):
        success, message = wifi.connect_wifi('KnownNet', secret)
    assert success, f'should succeed: {message}'
    assert secret not in message, f'secret leaked to message: {message}'
    for entry in log_entries:
        assert secret not in entry, f'secret leaked to log: {entry}'

    # Test 2: Failed transition
    def mock_state_fail():
        return {
            'operation_id': OP_ID,
            'phase': 'failed',
            'success': False,
            'message': 'Error de conexión',
        }

    with patch.object(wifi, '_send_wifi_command', side_effect=mock_send_command), \
         patch.object(wifi, '_read_control_state', side_effect=mock_state_fail), \
         patch.object(wifi.time, 'sleep', return_value=None):
        success, message = wifi.connect_wifi('KnownNet', secret)
    assert not success, 'should fail'
    assert secret not in message, f'secret leaked: {message}'
finally:
    wifi.logger.removeHandler(Capture())
PYEOF
}

run_test "healthy probes remain CLIENT_ONLINE" test_online
run_test "zero passive traffic does not mark a probed link dead" test_zero_traffic_healthy
run_test "IPv6 client route and gateway are actively probed" test_ipv6_online
run_test "working HTTPS overrides an ICMP-blocking gateway" test_blocked_gateway_icmp_with_https_is_online
run_test "Internet-only outage remains CLIENT_LOCAL_ONLY without AP flapping" test_local_only_no_ap
run_test "CLIENT_LOCAL_ONLY requires consecutive Internet recovery probes" test_local_only_requires_stable_recovery
run_test "one or two temporary failures do not start AP" test_temporary_failures_do_not_start_ap
run_test "no client link after threshold enters AP_ACTIVE once" test_threshold_starts_ap
run_test "fresh boot without a client profile starts the provisioning AP" test_fresh_boot_without_profile_starts_ap
run_test "connected NM state with dead gateway confirms link-dead transition" test_connected_dead_gateway_is_link_dead_transition
run_test "no profile deactivation by fallback (daemon-only)" test_no_profile_deactivation_by_fallback
run_test "AP recovery respects persisted retry cooldown" test_recovery_cooldown_respected
run_test "known-profile recovery leaves AP and enters client mode" test_successful_ap_recovery
run_test "failed recovery restores AP exactly once with backoff" test_failed_recovery_restores_ap_once
run_test "active AP ensure_ap is idempotent at call site" test_active_ap_ensure_is_idempotent
run_test "restore_ap socket command sent on threshold" test_restore_ap_sent_on_threshold
run_test "static invariant: no forbidden mutation patterns" test_static_no_forbidden_mutations
run_test "fallback performs zero direct mutations" test_no_mutations_from_fallback
run_test "a second wifi-fallback process is refused by the canonical lock" test_duplicate_fallback_process_refused
run_test "panel inhibit prevents fallback AP activation" test_inhibit_blocks_ap
run_test "expired inhibit is removed and monitoring resumes" test_expired_inhibit_removed
run_test "daemon handoff clears stale AP before next online cycle" test_daemon_handoff_detected
run_test "daemon AP restore is synchronised to fallback state" test_daemon_ap_restore_synced
run_test "panel uses exclusive socket path (no sudo)" test_panel_uses_exclusive_socket_path
run_test "client mode handoff detected via daemon state" test_client_ownership_is_exclusive
run_test "stable MAC policy contains no permanent unmanaged rule" test_static_mac_policy_never_blocks_client_ownership
run_test "panel connect failure reports error without sudo fallback" test_panel_connect_failure_reports_error
run_test "panel has no sudo wifi fallback paths" test_panel_no_sudo_paths_exist
run_test "panel socket busy returns busy message" test_panel_socket_busy_returns_busy_message
run_test "panel credentials never enter logs or argv" test_panel_credentials_never_reach_logs_or_argv
run_test "panel socket does not expose secret" test_panel_secret_is_not_exposed_via_socket
run_test "panel socket transition contract (success + failure + no leak)" test_panel_socket_transition_contract

printf '\nWiFi fallback: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
