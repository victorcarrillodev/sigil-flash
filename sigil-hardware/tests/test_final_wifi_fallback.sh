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
[ -f "$MOCK_STATE/associated" ] && echo 'Connected to 00:11:22:33:44:55'
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

reset_case() {
    rm -f "${MOCK_STATE}"/* "$STATE_FILE" "$INHIBIT_FILE"
    : > "${MOCK_STATE}/nmcli_calls"
    : > "${MOCK_STATE}/systemctl_calls"
    : > "${MOCK_STATE}/ip_calls"
    : > "${MOCK_STATE}/ping_calls"
    : > "${MOCK_STATE}/curl_calls"
    : > "${MOCK_STATE}/sudo_calls"
    : > "${MOCK_STATE}/panel_output"
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
    state_is CLIENT_ONLINE && ! grep -q 'start hostapd' "${MOCK_STATE}/systemctl_calls"
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
        && ! grep -q 'start hostapd' "${MOCK_STATE}/systemctl_calls"
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
    state_is CLIENT_CONNECTING && ! grep -q 'start hostapd' "${MOCK_STATE}/systemctl_calls"
}

test_threshold_starts_ap() {
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && [ "$(grep -c '^start hostapd$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] \
        && [ "$(grep -c '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ]
}

test_fresh_boot_without_profile_starts_ap() {
    touch "${MOCK_STATE}/no_saved_profiles"
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && [ -f "${MOCK_STATE}/service_hostapd" ] \
        && [ -f "${MOCK_STATE}/service_dnsmasq" ]
}

test_connected_dead_gateway_is_link_dead_transition() {
    set_dead_gateway
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && grep -q '^REASON=gateway_and_external_probes_failed' "$STATE_FILE" \
        && grep -q '^CLIENT_STATE=CLIENT_LINK_DEAD' "$STATE_FILE" \
        && grep -q '^DEAD_PROFILE_DEACTIVATED=1' "$STATE_FILE"
}

test_dead_profile_deactivated_once() {
    set_dead_gateway
    run_cycle; run_cycle; run_cycle; run_cycle
    [ "$(grep -c '^connection down id KnownNet$' "${MOCK_STATE}/nmcli_calls")" -eq 1 ]
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
    ! grep -q '^device connect wlan0$' "${MOCK_STATE}/nmcli_calls"
}

test_successful_ap_recovery() {
    write_ap_state 0
    touch "${MOCK_STATE}/recovery_success"
    run_cycle
    state_is CLIENT_ONLINE \
        && [ "$(grep -c '^stop hostapd$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] \
        && ! grep -q '^start hostapd$' "${MOCK_STATE}/systemctl_calls" \
        && grep -q '^LAST_SUCCESSFUL_PROFILE=KnownNet$' "$STATE_FILE"
}

test_failed_recovery_restores_ap_once() {
    write_ap_state 0
    run_cycle
    state_is AP_ACTIVE \
        && [ "$(grep -c '^start hostapd$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] \
        && [ "$(grep -c '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] \
        && grep -q '^RECOVERY_BACKOFF=240' "$STATE_FILE"
}

test_active_ap_has_no_duplicate_services() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    run_cycle
    ! grep -q '^start hostapd$' "${MOCK_STATE}/systemctl_calls" \
        && ! grep -q '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls"
}

test_ap_ownership_is_exclusive() {
    run_cycle; run_cycle; run_cycle
    state_is AP_ACTIVE \
        && grep -q '^device set wlan0 managed no$' "${MOCK_STATE}/nmcli_calls" \
        && grep -q '^addr add 192.168.4.1/24 dev wlan0$' "${MOCK_STATE}/ip_calls" \
        && [ -f "${MOCK_STATE}/service_hostapd" ] \
        && [ -f "${MOCK_STATE}/service_dnsmasq" ] \
        && ! grep -q '^device set wlan0 managed yes$' "${MOCK_STATE}/nmcli_calls"
}

test_repeated_ap_reconciliation_is_idempotent() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    run_cycle
    run_cycle
    ! grep -q '^start hostapd$' "${MOCK_STATE}/systemctl_calls" \
        && ! grep -q '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls"
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

with patch.object(wifi.time, 'sleep', return_value=None):
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
    state_is CLIENT_CONNECTING && ! grep -q '^start hostapd$' "${MOCK_STATE}/systemctl_calls"
}

test_expired_inhibit_removed() {
    write_inhibit "$(( $(date +%s) - 1 ))"
    run_cycle
    [ ! -e "$INHIBIT_FILE" ] && state_is CLIENT_CONNECTING
}

test_panel_success_handoff_prevents_stale_ap_restart() {
    local starts_before
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    run_panel_connect 1 || return 1
    [ ! -e "$INHIBIT_FILE" ] || return 1
    state_is CLIENT_CONNECTING || return 1
    [ "${WIFI_STATE[AP_ACTIVE]}" = 0 ] || return 1
    [ "${WIFI_STATE[CLIENT_STATE]}" = CLIENT_CONNECTING ] || return 1
    grep -q '^REASON=panel_client_handoff$' "$STATE_FILE" || return 1
    grep -q '^FAIL_COUNT=0$' "$STATE_FILE" || return 1
    grep -q '^SUCCESS_COUNT=0$' "$STATE_FILE" || return 1
    grep -q '^FAIL_STARTED_AT=0$' "$STATE_FILE" || return 1
    grep -q '^NEXT_RETRY_AT=0$' "$STATE_FILE" || return 1
    grep -q '^RECOVERY_BACKOFF=120$' "$STATE_FILE" || return 1
    grep -q '^LOCAL_PROBE_BACKOFF=30$' "$STATE_FILE" || return 1
    grep -q '^NEXT_PROBE_AT=0$' "$STATE_FILE" || return 1
    grep -q '^DEAD_PROFILE=$' "$STATE_FILE" || return 1
    grep -q '^DEAD_PROFILE_DEACTIVATED=0$' "$STATE_FILE" || return 1
    [ -z "$(find "${TEST_ROOT}/var" -name '.wifi-fallback-state.*' -print -quit)" ] || return 1
    starts_before=$(grep -c '^start hostapd$' "${MOCK_STATE}/systemctl_calls" || true)
    [ "$starts_before" -eq 0 ] || return 1
    [ "$(grep -c '^stop hostapd$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] || return 1
    [ "$(grep -c '^stop dnsmasq$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] || return 1
    run_cycle
    state_is CLIENT_ONLINE \
        && [ "${WIFI_STATE[AP_ACTIVE]}" = 0 ] \
        && ! grep -q '^start hostapd$' "${MOCK_STATE}/systemctl_calls" \
        && ! grep -q '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls"
}

test_panel_local_only_handoff_does_not_restore_ap() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_local_only
    run_panel_connect 1 || return 1
    [ ! -e "$INHIBIT_FILE" ] || return 1
    run_cycle
    state_is CLIENT_LOCAL_ONLY \
        && [ "${WIFI_STATE[AP_ACTIVE]}" = 0 ] \
        && ! grep -q '^start hostapd$' "${MOCK_STATE}/systemctl_calls" \
        && ! grep -q '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls"
}

test_panel_uses_canonical_ownership_helper() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    run_panel_connect 1 || return 1
    grep -qxF "${SIGIL_WIFI_FALLBACK_HELPER} --prepare-client" \
        "${MOCK_STATE}/sudo_calls" || return 1
    grep -qxF "${SIGIL_WIFI_FALLBACK_HELPER} --external-client-handoff" \
        "${MOCK_STATE}/sudo_calls" || return 1
    ! grep -q '^systemctl stop \|^ip addr flush \|^nmcli device set wlan0 managed' \
        "${MOCK_STATE}/sudo_calls"
}

test_client_ownership_is_exclusive() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    run_panel_connect 1 || return 1
    [ ! -f "${MOCK_STATE}/service_hostapd" ] \
        && [ ! -f "${MOCK_STATE}/service_dnsmasq" ] \
        && grep -q '^device set wlan0 managed yes$' "${MOCK_STATE}/nmcli_calls" \
        && ! grep -q '^device set wlan0 managed no$' "${MOCK_STATE}/nmcli_calls"
}

test_static_mac_policy_never_blocks_client_ownership() {
    local policy="${ROOT}/conf/99-sigil-mac-fixed.conf"
    grep -qx 'wifi.scan-rand-mac-address=no' "$policy" \
        && grep -qx 'wifi.cloned-mac-address=permanent' "$policy" \
        && ! grep -Eq 'unmanaged-devices|managed[[:space:]]*=[[:space:]]*false' "$policy" \
        && grep -q 'unmanaged-devices.*wlan0' "${ROOT}/install.sh"
}

test_failed_panel_transition_restores_ap_once() {
    local original_retry="$(( $(date +%s) + 1000 ))"
    write_ap_state "$original_retry"
    load_state
    WIFI_STATE[REASON]="preexisting_ap_failure"
    save_state
    touch "${MOCK_STATE}/panel_up_fail"
    run_panel_connect 0 || return 1
    [ ! -e "$INHIBIT_FILE" ] || return 1
    [ "$(grep -c -- '--restore-ap$' "${MOCK_STATE}/sudo_calls")" -eq 1 ] || return 1
    state_is AP_ACTIVE || return 1
    [ "${WIFI_STATE[REASON]}" = preexisting_ap_failure ] || return 1
    [ "${WIFI_STATE[RECOVERY_BACKOFF]}" = 120 ] || return 1
    [ "${WIFI_STATE[NEXT_RETRY_AT]}" = "$original_retry" ] || return 1
    run_cycle
    state_is AP_ACTIVE || return 1
    [ "$(grep -c '^start hostapd$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] || return 1
    [ "$(grep -c '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] || return 1
    grep -q '^device set wlan0 managed no$' "${MOCK_STATE}/nmcli_calls" || return 1
    run_cycle
    [ "$(grep -c '^start hostapd$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ] \
        && [ "$(grep -c '^start dnsmasq$' "${MOCK_STATE}/systemctl_calls")" -eq 1 ]
}

test_unmanaged_client_preparation_fails_closed_to_ap() {
    write_ap_state "$(( $(date +%s) + 1000 ))"
    touch "${MOCK_STATE}/nm_unmanaged"
    run_panel_connect 0 || return 1
    state_is AP_ACTIVE \
        && [ -f "${MOCK_STATE}/service_hostapd" ] \
        && [ -f "${MOCK_STATE}/service_dnsmasq" ] \
        && [ "$(grep -c -- '--restore-ap$' "${MOCK_STATE}/sudo_calls")" -eq 1 ]
}

test_panel_transitions_share_one_lock() {
    ROOT="$ROOT" python3 - <<'PYEOF'
import fcntl
import importlib.util
import os
from unittest.mock import patch

root = os.environ['ROOT']
spec = importlib.util.spec_from_file_location(
    'sigil_wifi_lock_test', os.path.join(root, 'panel', 'wifi.py')
)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

os.makedirs(os.path.dirname(wifi.WIFI_TRANSITION_LOCK), exist_ok=True)
with open(wifi.WIFI_TRANSITION_LOCK, 'a+', encoding='utf-8') as holder:
    fcntl.flock(holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    with patch.object(wifi.time, 'sleep', return_value=None):
        success, message = wifi.connect_wifi('KnownNet', 'never-used-secret')
    assert not success
    assert message == 'Otra transición WiFi está en progreso'
assert not os.path.exists(wifi.WIFI_INHIBIT_FILE)
PYEOF
}

test_panel_credentials_never_reach_logs_or_argv() {
    local secret="handoff-password-not-for-logs"
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    run_panel_connect 1 || return 1
    ! grep -R -F "$secret" \
        "${MOCK_STATE}/sudo_calls" \
        "${MOCK_STATE}/nmcli_calls" \
        "${MOCK_STATE}/systemctl_calls" \
        "${MOCK_STATE}/panel_output"
}

test_panel_secret_is_persisted_only_in_root_profile() {
    local profile="${SIGIL_NM_CONNECTION_DIR}/KnownNet.nmconnection"
    write_ap_state "$(( $(date +%s) + 1000 ))"
    set_online
    run_panel_connect 1 || return 1
    [ "$(stat -c %a "$profile")" = 600 ] \
        && grep -qx 'psk=handoff-password-not-for-logs' "$profile" \
        && grep -qx 'psk-flags=0' "$profile" \
        && ! grep -R -F 'handoff-password-not-for-logs' \
            "${MOCK_STATE}/sudo_calls" "${MOCK_STATE}/nmcli_calls" \
            "${MOCK_STATE}/panel_output"
}

test_panel_transition_contract() {
    SIGIL_TEST_ROOT="$TEST_ROOT" ROOT="$ROOT" python3 - <<'PYEOF'
import glob
import importlib.util
import logging
import os
import subprocess
import sys
from unittest.mock import patch

root = os.environ['ROOT']
test_root = os.environ['SIGIL_TEST_ROOT']
os.environ['SIGIL_WIFI_INHIBIT_FILE'] = os.path.join(test_root, 'panel-inhibit.json')
os.environ['SIGIL_WIFI_TRANSITION_LOCK'] = os.path.join(test_root, 'panel-transition.lock')
os.environ['SIGIL_WIFI_CONNECT_INHIBIT_SECONDS'] = '30'
os.environ['SIGIL_WIFI_CONNECT_STABILIZATION_SECONDS'] = '2'
os.environ['SIGIL_WIFI_CONNECT_STABLE_CHECKS'] = '2'
os.environ['SIGIL_WIFI_CONNECT_CHECK_INTERVAL'] = '0'
spec = importlib.util.spec_from_file_location('sigil_wifi_test', os.path.join(root, 'panel', 'wifi.py'))
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)

class Result:
    def __init__(self, rc=0, stdout='', stderr=''):
        self.returncode = rc
        self.stdout = stdout
        self.stderr = stderr

commands = []
inhibit_seen = False
fail_up = False

def fake_run(args, **_kwargs):
    global inhibit_seen
    commands.append(list(args))
    joined = ' '.join(args)
    if 'connection show' in joined:
        return Result(stdout='KnownNet:802-11-wireless\n')
    if '--persist-client-secret' in args:
        inhibit_seen = inhibit_seen or os.path.exists(wifi.WIFI_INHIBIT_FILE)
        password_file = args[-1]
        assert oct(os.stat(password_file).st_mode & 0o777) == '0o600'
        with open(password_file, encoding='utf-8') as handle:
            assert handle.read() == f'802-11-wireless-security.psk:{secret}\n'
        return Result()
    if args[:5] == ['sudo', 'nmcli', 'con', 'up', 'KnownNet']:
        return Result(1 if fail_up else 0)
    if 'GENERAL.STATE' in args:
        return Result(stdout='GENERAL.STATE:100 (connected)\n')
    if args and args[0] == 'ip':
        return Result(stdout='3: wlan0 inet 192.0.2.2/24 scope global\n')
    return Result()

messages = []
class Capture(logging.Handler):
    def emit(self, record):
        messages.append(record.getMessage())
wifi.logger.addHandler(Capture())

secret = 'test-password-not-for-logs'
with patch.object(subprocess, 'run', side_effect=fake_run), patch.object(wifi.time, 'sleep', return_value=None):
    success, _message = wifi.connect_wifi('KnownNet', secret)
assert success and inhibit_seen
persist = next(command for command in commands if '--persist-client-secret' in command)
activation = next(
    command for command in commands
    if command[:4] == ['sudo', 'nmcli', 'con', 'up']
)
assert persist[:4] == ['sudo', wifi.WIFI_FALLBACK_HELPER, '--persist-client-secret', 'KnownNet']
assert activation == ['sudo', 'nmcli', 'con', 'up', 'KnownNet']
assert 'passwd-file' not in activation
assert not os.path.exists(wifi.WIFI_INHIBIT_FILE)
assert not any(
    'systemctl' in command and 'wifi-fallback' in command
    for command in commands
)
assert not any(secret in ' '.join(command) for command in commands)
assert not any(secret in message for message in messages)
assert not glob.glob(os.path.join(test_root, '.nmcli-password.*'))

commands.clear()
fail_up = True
with patch.object(subprocess, 'run', side_effect=fake_run), patch.object(wifi.time, 'sleep', return_value=None):
    success, _message = wifi.connect_wifi('KnownNet', secret)
assert not success
assert not os.path.exists(wifi.WIFI_INHIBIT_FILE)
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
run_test "dead profile is deactivated at most once per transition" test_dead_profile_deactivated_once
run_test "AP recovery respects persisted retry cooldown" test_recovery_cooldown_respected
run_test "known-profile recovery leaves AP and enters client mode" test_successful_ap_recovery
run_test "failed recovery restores AP exactly once with backoff" test_failed_recovery_restores_ap_once
run_test "active AP services are not duplicated" test_active_ap_has_no_duplicate_services
run_test "AP mode owns wlan0 exclusively" test_ap_ownership_is_exclusive
run_test "repeated AP reconciliation is idempotent" test_repeated_ap_reconciliation_is_idempotent
run_test "a second wifi-fallback process is refused by the canonical lock" test_duplicate_fallback_process_refused
run_test "panel inhibit prevents fallback AP activation" test_inhibit_blocks_ap
run_test "expired inhibit is removed and monitoring resumes" test_expired_inhibit_removed
run_test "panel handoff clears stale AP before the next online cycle" test_panel_success_handoff_prevents_stale_ap_restart
run_test "panel local-only handoff does not reactivate AP" test_panel_local_only_handoff_does_not_restore_ap
run_test "panel delegates ownership only to wifi-fallback" test_panel_uses_canonical_ownership_helper
run_test "client mode gives NetworkManager exclusive wlan0 ownership" test_client_ownership_is_exclusive
run_test "stable MAC policy contains no permanent unmanaged rule" test_static_mac_policy_never_blocks_client_ownership
run_test "failed panel transition restores AP exactly once" test_failed_panel_transition_restores_ap_once
run_test "permanently unmanaged client preparation fails closed to AP" test_unmanaged_client_preparation_fails_closed_to_ap
run_test "two panel transitions serialize on the canonical lock" test_panel_transitions_share_one_lock
run_test "panel credentials never enter logs or argv" test_panel_credentials_never_reach_logs_or_argv
run_test "panel PSK persists only in the root-owned NetworkManager profile" test_panel_secret_is_persisted_only_in_root_profile
run_test "panel transition uses bounded inhibit and hides password" test_panel_transition_contract

printf '\nWiFi fallback: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
