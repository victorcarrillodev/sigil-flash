#!/bin/bash
# Behavioral regression tests for the Raspberry SSH short-smoke findings.
# Production ssh-monitor functions are sourced; only external commands are mocked.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
ORIGINAL_PATH="$PATH"

# shellcheck source=scripts/ssh-monitor.sh
source "${ROOT}/scripts/ssh-monitor.sh"
set +e

PASS=0
FAIL=0
TEST_ROOT=""

cleanup_case() {
    if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
        rm -rf "$TEST_ROOT"
    fi
    TEST_ROOT=""
    PATH="$ORIGINAL_PATH"
}
trap cleanup_case EXIT

run_test() {
    local name="$1"
    local function_name="$2"
    if "$function_name"; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$name"
    fi
    cleanup_case
}

setup_case() {
    cleanup_case
    TEST_ROOT=$(mktemp -d /tmp/sigil-ssh-smoke.XXXXXX)
    mkdir -p "$TEST_ROOT/run" "$TEST_ROOT/state" "$TEST_ROOT/bin" "$TEST_ROOT/services"
    chmod 0770 "$TEST_ROOT/run"

    RUN_SIGIL_DIR="$TEST_ROOT/run"
    STATE_DIR="$TEST_ROOT/state"
    SSH_STATUS_FILE="$STATE_DIR/ssh_status.json"
    SSH_ACTIVE_MARKER="$RUN_SIGIL_DIR/ssh-active"
    LOGOUT_FETCH_MARKER="$RUN_SIGIL_DIR/logout-fetch-active"
    SERVICE_SNAPSHOT_FILE="$RUN_SIGIL_DIR/ssh-service-snapshot.json"
    FETCH_OPERATION_FILE="$RUN_SIGIL_DIR/logout-fetch-operation.json"
    CACHE_WIPE="$TEST_ROOT/bin/cache-wipe"
    RADIO_FETCHER="$TEST_ROOT/bin/radio-fetcher"
    FETCH_WRAPPER="$ROOT/scripts/sigil-logout-fetch-operation.sh"
    SS_BIN="$TEST_ROOT/bin/ss"
    PROC_ROOT="/proc"
    MARKER_OWNER=$(id -un)
    MARKER_GROUP=$(id -gn)
    LOGOUT_COORDINATION_TOKEN=""
    LOGOUT_COORDINATION_OWNED=false
    ACTIVE_FETCH_PID=""
    RESTORE_FAILED_SERVICE=""
    RECOVERED_FETCH_IN_PROGRESS=false

    export TEST_SERVICE_DIR="$TEST_ROOT/services"
    export TEST_EVENT_LOG="$TEST_ROOT/events.log"
    export TEST_SS_OUTPUT="$TEST_ROOT/ss-output"
    : > "$TEST_EVENT_LOG"
    : > "$TEST_SS_OUTPUT"

    cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/bin/bash
set -u
command="${1:-}"
service="${2:-}"
shift || true
key="${service%.service}"
case "$command" in
    show)
        [ ! -f "${TEST_SERVICE_DIR}/${key}.query-fail" ] || exit 42
        [ ! -f "${TEST_SERVICE_DIR}/${key}.missing" ] || {
            printf 'LoadState=not-found\nActiveState=inactive\nUnitFileState=\n'
            exit 0
        }
        printf 'LoadState=loaded\n'
        if [ -f "${TEST_SERVICE_DIR}/${key}.failed" ]; then
            printf 'ActiveState=failed\n'
        elif [ -f "${TEST_SERVICE_DIR}/${key}.active" ]; then
            printf 'ActiveState=active\n'
        else
            printf 'ActiveState=inactive\n'
        fi
        if [ -f "${TEST_SERVICE_DIR}/${key}.static" ]; then
            printf 'UnitFileState=static\n'
        elif [ -f "${TEST_SERVICE_DIR}/${key}.enabled" ]; then
            printf 'UnitFileState=enabled\n'
        else
            printf 'UnitFileState=disabled\n'
        fi
        ;;
    is-active)  [ -f "${TEST_SERVICE_DIR}/${key}.active" ] ;;
    is-enabled) [ -f "${TEST_SERVICE_DIR}/${key}.enabled" ] ;;
    is-failed)  [ -f "${TEST_SERVICE_DIR}/${key}.failed" ] ;;
    stop)
        printf 'stop:%s\n' "$service" >> "$TEST_EVENT_LOG"
        rm -f "${TEST_SERVICE_DIR}/${key}.active"
        rm -f "${TEST_SERVICE_DIR}/${key}.failed"
        ;;
    start)
        printf 'start:%s\n' "$service" >> "$TEST_EVENT_LOG"
        [ ! -f "${TEST_SERVICE_DIR}/${key}.fail-start" ] || exit 41
        touch "${TEST_SERVICE_DIR}/${key}.active"
        ;;
    reset-failed)
        printf 'reset-failed:%s\n' "$service" >> "$TEST_EVENT_LOG"
        rm -f "${TEST_SERVICE_DIR}/${key}.failed"
        ;;
    enable|disable)
        printf 'UNEXPECTED-ENABLEMENT-MUTATION:%s:%s\n' "$command" "$service" >> "$TEST_EVENT_LOG"
        exit 90
        ;;
    *) exit 1 ;;
esac
EOF

    cat > "$TEST_ROOT/bin/ss" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
    *"sport = :ssh"*)
        [ "${MOCK_SSH_SERVICE_FAIL:-0}" = "0" ] || exit 1
        ;;
    *"sport = :22"*) ;;
    *) exit 88 ;;
esac
cat "$TEST_SS_OUTPUT"
EOF

    cat > "$CACHE_WIPE" <<'EOF'
#!/bin/bash
set -u
[ -f "${SIGIL_RUN_DIR}/ssh-active" ] || exit 70
logout_present=false
[ ! -f "${SIGIL_RUN_DIR}/logout-fetch-active" ] || logout_present=true
printf 'wipe:ssh-present:logout-%s\n' "$logout_present" >> "$TEST_EVENT_LOG"
exit "${MOCK_WIPE_RC:-0}"
EOF

    cat > "$RADIO_FETCHER" <<'EOF'
#!/bin/bash
set -u
case "${1:-}" in
    --once)
        [ -f "${SIGIL_RUN_DIR}/logout-fetch-active" ] || exit 71
        [ ! -f "${SIGIL_RUN_DIR}/ssh-active" ] || exit 72
        printf 'explicit-fetch\n' >> "$TEST_EVENT_LOG"
        exit "${MOCK_FETCH_RC:-0}"
        ;;
    --validate-active)
        printf 'validate-active\n' >> "$TEST_EVENT_LOG"
        exit "${MOCK_VALIDATE_RC:-0}"
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$TEST_ROOT/bin/sudo" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    shift 2
fi
"$@" &
child=$!
wait "$child"
exit $?
EOF
    printf '#!/bin/bash\nexit 1\n' > "$TEST_ROOT/bin/pgrep"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_ROOT/bin/pkill"
    chmod +x "$TEST_ROOT/bin/"*

    PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
    export PATH SIGIL_RUN_DIR="$RUN_SIGIL_DIR"
    export MOCK_WIPE_RC=0 MOCK_FETCH_RC=0 MOCK_VALIDATE_RC=0 MOCK_SSH_SERVICE_FAIL=0
}

set_service_state() {
    local service="$1" active="$2" enabled="$3"
    local key="${service%.service}"
    rm -f "$TEST_SERVICE_DIR/${key}.active" "$TEST_SERVICE_DIR/${key}.enabled" \
        "$TEST_SERVICE_DIR/${key}.failed" "$TEST_SERVICE_DIR/${key}.fail-start"
    [ "$active" = "active" ] && touch "$TEST_SERVICE_DIR/${key}.active"
    [ "$enabled" = "enabled" ] && touch "$TEST_SERVICE_DIR/${key}.enabled"
    return 0
}

assert_count() {
    local expected="$1" actual
    actual=$(get_ssh_count) || return 1
    [ "$actual" = "$expected" ]
}

test_inbound_local_port_22_counted() {
    setup_case
    printf 'tcp ESTAB 0 0 10.0.0.2:22 10.0.0.3:50000\n' > "$TEST_SS_OUTPUT"
    assert_count 1
}

test_outbound_remote_port_22_not_counted() {
    setup_case
    # The mocked ss filter returns no rows for sport=22. A dport-based caller is
    # rejected by the mock rather than accidentally passing this test.
    : > "$TEST_SS_OUTPUT"
    assert_count 0
}

test_ipv4_inbound_counted() {
    setup_case
    printf 'tcp ESTAB 0 0 192.168.1.20:22 192.168.1.30:41000\n' > "$TEST_SS_OUTPUT"
    assert_count 1
}

test_ipv6_inbound_counted() {
    setup_case
    printf 'tcp ESTAB 0 0 [fd00::20]:22 [fd00::30]:41000\n' > "$TEST_SS_OUTPUT"
    assert_count 1
}

test_two_inbound_sessions_counted() {
    setup_case
    printf '%s\n' \
        'tcp ESTAB 0 0 10.0.0.2:22 10.0.0.3:50000' \
        'tcp ESTAB 0 0 [fd00::2]:22 [fd00::3]:50001' > "$TEST_SS_OUTPUT"
    assert_count 2
}

test_zero_inbound_sessions() {
    setup_case
    : > "$TEST_SS_OUTPUT"
    assert_count 0
}

test_numeric_port_fallback() {
    setup_case
    export MOCK_SSH_SERVICE_FAIL=1
    printf 'tcp ESTAB 0 0 10.0.0.2:22 10.0.0.3:50000\n' > "$TEST_SS_OUTPUT"
    assert_count 1
}

prepare_mixed_service_state() {
    set_service_state radio-fetcher.service active enabled
    set_service_state audio-manager.service active enabled
    set_service_state audio-player.service active disabled
    set_service_state radio-stream.service inactive disabled
}

test_successful_cycle_restores_exact_state() {
    setup_case
    prepare_mixed_service_state

    enter_maintenance >/dev/null 2>&1 || return 1
    [ -f "$SERVICE_SNAPSHOT_FILE" ] || return 1
    [ "$(stat -c '%a' "$SERVICE_SNAPSHOT_FILE")" = "640" ] || return 1
    python3 - "$SERVICE_SNAPSHOT_FILE" <<'PYEOF' || return 1
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {
    "radio-fetcher.service": {"load": "loaded", "active": "active", "enabled": "enabled"},
    "audio-manager.service": {"load": "loaded", "active": "active", "enabled": "enabled"},
    "audio-player.service": {"load": "loaded", "active": "active", "enabled": "disabled"},
    "radio-stream.service": {"load": "loaded", "active": "inactive", "enabled": "disabled"},
}
raise SystemExit(0 if document.get("services") == expected else 1)
PYEOF
    [ -f "$SSH_ACTIVE_MARKER" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/radio-fetcher.active" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/audio-manager.active" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/audio-player.active" ] || return 1
    [ -f "$TEST_SERVICE_DIR/audio-player.enabled" ] && return 1
    [ -f "$TEST_SERVICE_DIR/audio-player.failed" ] || touch "$TEST_SERVICE_DIR/audio-player.failed"

    exit_maintenance 0 >/dev/null 2>&1 || return 1
    [ -f "$TEST_SERVICE_DIR/radio-fetcher.active" ] || return 1
    [ -f "$TEST_SERVICE_DIR/audio-manager.active" ] || return 1
    [ -f "$TEST_SERVICE_DIR/audio-player.active" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/radio-stream.active" ] || return 1
    [ -f "$TEST_SERVICE_DIR/radio-fetcher.enabled" ] || return 1
    [ -f "$TEST_SERVICE_DIR/audio-manager.enabled" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/audio-player.enabled" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/radio-stream.enabled" ] || return 1
    [ "$(grep -c '^explicit-fetch$' "$TEST_EVENT_LOG")" -eq 1 ] || return 1
    [ "$(grep -c '^validate-active$' "$TEST_EVENT_LOG")" -eq 1 ] || return 1
    grep -q '^reset-failed:audio-player.service$' "$TEST_EVENT_LOG" || return 1
    grep -q '^wipe:ssh-present:logout-true$' "$TEST_EVENT_LOG" || return 1
    ! grep -q '^UNEXPECTED-ENABLEMENT-MUTATION:' "$TEST_EVENT_LOG" || return 1
    [ ! -e "$SERVICE_SNAPSHOT_FILE" ] || return 1
    [ ! -e "$SSH_ACTIVE_MARKER" ] || return 1
    [ ! -e "$LOGOUT_FETCH_MARKER" ]
}

test_logout_wipe_failure_fails_closed() {
    setup_case
    prepare_mixed_service_state
    enter_maintenance >/dev/null 2>&1 || return 1
    export MOCK_WIPE_RC=9
    ! exit_maintenance 0 >/dev/null 2>&1 || return 1
    [ -f "$SSH_ACTIVE_MARKER" ] || return 1
    [ -f "$SERVICE_SNAPSHOT_FILE" ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/audio-player.active" ] || return 1
    ! grep -q '^explicit-fetch$' "$TEST_EVENT_LOG" || return 1
    python3 - "$SSH_STATUS_FILE" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))["last_exit"]
ok = state["wipe_ok"] is False and state["recovery_pending"] is True
raise SystemExit(0 if ok else 1)
PYEOF
}

test_login_wipe_failure_status_survives_count_update() {
    setup_case
    prepare_mixed_service_state
    export MOCK_WIPE_RC=9
    ! enter_maintenance >/dev/null 2>&1 || return 1
    write_ssh_status 1 || return 1
    python3 - "$SSH_STATUS_FILE" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))["last_exit"]
ok = state["wipe_ok"] is False and state["recovery_pending"] is True
raise SystemExit(0 if ok else 1)
PYEOF
}

test_fetch_failure_does_not_restore_player() {
    setup_case
    prepare_mixed_service_state
    enter_maintenance >/dev/null 2>&1 || return 1
    export MOCK_FETCH_RC=23
    exit_maintenance 0 >/dev/null 2>&1
    [ "$?" -eq 23 ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/audio-player.active" ] || return 1
    [ -f "$SERVICE_SNAPSHOT_FILE" ] || return 1
    python3 - "$SSH_STATUS_FILE" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))["last_exit"]
raise SystemExit(0 if state["fetch_exit_code"] == 23 and state["recovery_pending"] and state["recovery_state"] == "fetch_failed" else 1)
PYEOF
}

test_invalid_cache_does_not_restore_player() {
    setup_case
    prepare_mixed_service_state
    enter_maintenance >/dev/null 2>&1 || return 1
    export MOCK_VALIDATE_RC=65
    exit_maintenance 0 >/dev/null 2>&1
    [ "$?" -eq 65 ] || return 1
    [ ! -f "$TEST_SERVICE_DIR/audio-player.active" ] || return 1
    [ -f "$SERVICE_SNAPSHOT_FILE" ] || return 1
    python3 - "$SSH_STATUS_FILE" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))["last_exit"]
raise SystemExit(0 if state["fetch_exit_code"] == 0 and state["cache_valid"] is False else 1)
PYEOF
}

test_service_restart_failure_preserves_diagnostics() {
    setup_case
    prepare_mixed_service_state
    enter_maintenance >/dev/null 2>&1 || return 1
    touch "$TEST_SERVICE_DIR/audio-player.fail-start"
    ! exit_maintenance 0 >/dev/null 2>&1 || return 1
    [ -f "$SERVICE_SNAPSHOT_FILE" ] || return 1
    python3 - "$SSH_STATUS_FILE" <<'PYEOF'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))["last_exit"]
ok = state["failed_service"] == "audio-player.service" and state["restore_ok"] is False
raise SystemExit(0 if ok else 1)
PYEOF
}

write_synthetic_stat() {
    local path="$1" pid="$2" name="$3" start="$4"
    {
        printf '%s (%s) S' "$pid" "$name"
        local _
        for _ in $(seq 4 21); do printf ' 0'; done
        printf ' %s\n' "$start"
    } > "$path"
}

test_reused_unrelated_pid_not_trusted() {
    setup_case
    PROC_ROOT="$TEST_ROOT/proc"
    mkdir -p "$PROC_ROOT/4242"
    write_synthetic_stat "$PROC_ROOT/4242/stat" 4242 sleep 777
    printf '/usr/bin/sleep\000999\000' > "$PROC_ROOT/4242/cmdline"
    printf 'ssh-monitor:4242:777\n' > "$LOGOUT_FETCH_MARKER"
    recover_stale_logout_marker >/dev/null 2>&1 || return 1
    [ ! -e "$LOGOUT_FETCH_MARKER" ]
}

test_live_orphaned_fetch_preserves_coordination() {
    setup_case
    PROC_ROOT="$TEST_ROOT/proc"
    mkdir -p "$PROC_ROOT/5151"
    write_synthetic_stat "$PROC_ROOT/5151/stat" 5151 bash 888
    printf '/bin/bash\000%s\000--once\000' "$(readlink -f "$RADIO_FETCHER")" > "$PROC_ROOT/5151/cmdline"
    printf 'SIGIL_LOGOUT_OPERATION_ID=orphan-test\000' > "$PROC_ROOT/5151/environ"
    write_fetch_operation orphan-test running "$RUN_SIGIL_DIR/logout-fetch-result-orphan-test.json" \
        "" "" "" 5151 888 "" || return 1
    printf 'ssh-monitor:4141:777\n' > "$LOGOUT_FETCH_MARKER"

    recover_stale_logout_marker >/dev/null 2>&1 || return 1
    $RECOVERED_FETCH_IN_PROGRESS || return 1
    [ -e "$LOGOUT_FETCH_MARKER" ]
}

prepare_failed_logout_transition() {
    prepare_mixed_service_state
    enter_maintenance >/dev/null 2>&1 || return 1
    write_ssh_status 1 || return 1
    export MOCK_WIPE_RC=9
    ! process_ssh_transition 0 1 >/dev/null 2>&1 || return 1
}

test_logout_wipe_failure_occurs_once() {
    setup_case
    prepare_failed_logout_transition || return 1
    [ "$(grep -c '^wipe:ssh-present:logout-true$' "$TEST_EVENT_LOG")" -eq 1 ] || return 1
    [ "$(read_ssh_status)" -eq 0 ] || return 1
    [ "$(read_ssh_recovery_state)" = "wipe_failed" ]
}

test_failed_logout_not_retried_by_later_cycles() {
    setup_case
    prepare_failed_logout_transition || return 1
    local before previous
    before=$(grep -c '^wipe:ssh-present:logout-true$' "$TEST_EVENT_LOG")
    previous=$(read_ssh_status)
    process_ssh_transition 0 "$previous" >/dev/null 2>&1 || return 1
    previous=$(read_ssh_status)
    process_ssh_transition 0 "$previous" >/dev/null 2>&1 || return 1
    [ "$(grep -c '^wipe:ssh-present:logout-true$' "$TEST_EVENT_LOG")" -eq "$before" ]
}

test_new_ssh_cycle_retries_recovery_once() {
    setup_case
    prepare_failed_logout_transition || return 1
    export MOCK_WIPE_RC=0
    process_ssh_transition 1 0 >/dev/null 2>&1 || return 1
    process_ssh_transition 0 1 >/dev/null 2>&1 || return 1
    [ "$(grep -c '^explicit-fetch$' "$TEST_EVENT_LOG")" -eq 1 ] || return 1
    [ "$(read_ssh_recovery_state)" = "complete" ] || return 1
    [ ! -e "$SSH_ACTIVE_MARKER" ] && [ ! -e "$SERVICE_SNAPSHOT_FILE" ]
}

test_snapshot_active_service_state() {
    setup_case
    set_service_state radio-fetcher.service active enabled
    [ "$(query_service_state radio-fetcher.service)" = $'loaded\tactive\tenabled' ]
}

test_snapshot_inactive_service_state() {
    setup_case
    set_service_state radio-fetcher.service inactive enabled
    [ "$(query_service_state radio-fetcher.service)" = $'loaded\tinactive\tenabled' ]
}

test_snapshot_failed_service_state() {
    setup_case
    set_service_state radio-fetcher.service inactive enabled
    touch "$TEST_SERVICE_DIR/radio-fetcher.failed"
    [ "$(query_service_state radio-fetcher.service)" = $'loaded\tfailed\tenabled' ]
}

test_snapshot_disabled_service_state() {
    setup_case
    set_service_state radio-fetcher.service active disabled
    [ "$(query_service_state radio-fetcher.service)" = $'loaded\tactive\tdisabled' ]
}

test_snapshot_static_service_state() {
    setup_case
    set_service_state radio-fetcher.service inactive disabled
    touch "$TEST_SERVICE_DIR/radio-fetcher.static"
    [ "$(query_service_state radio-fetcher.service)" = $'loaded\tinactive\tstatic' ]
}

test_snapshot_dbus_failure_aborts() {
    setup_case
    prepare_mixed_service_state
    touch "$TEST_SERVICE_DIR/audio-manager.query-fail"
    ! write_service_snapshot >/dev/null 2>&1 || return 1
    [ "$SNAPSHOT_FAILED_SERVICE" = "audio-manager.service" ] || return 1
    [ "$SNAPSHOT_FAILED_QUERY" = "systemctl-show:42" ] || return 1
    [ ! -e "$SERVICE_SNAPSHOT_FILE" ]
}

test_snapshot_missing_unit_aborts() {
    setup_case
    prepare_mixed_service_state
    touch "$TEST_SERVICE_DIR/audio-player.missing"
    ! write_service_snapshot >/dev/null 2>&1 || return 1
    [ "$SNAPSHOT_FAILED_SERVICE" = "audio-player.service" ] || return 1
    [ "$SNAPSHOT_FAILED_QUERY" = "load-state:not-found" ] || return 1
    [ ! -e "$SERVICE_SNAPSHOT_FILE" ]
}

test_partial_snapshot_failure_stops_no_service() {
    setup_case
    prepare_mixed_service_state
    touch "$TEST_SERVICE_DIR/audio-player.query-fail"
    ! enter_maintenance >/dev/null 2>&1 || return 1
    ! grep -q '^stop:' "$TEST_EVENT_LOG" || return 1
    [ -f "$TEST_SERVICE_DIR/radio-fetcher.active" ] || return 1
    [ -f "$TEST_SERVICE_DIR/audio-manager.active" ] || return 1
    [ -f "$TEST_SERVICE_DIR/audio-player.active" ]
}

printf '%s\n' '=== SSH hardware-smoke remediation tests ==='
run_test "inbound local port 22 is counted" test_inbound_local_port_22_counted
run_test "outbound remote port 22 is not counted" test_outbound_remote_port_22_not_counted
run_test "IPv4 inbound session is counted" test_ipv4_inbound_counted
run_test "IPv6 inbound session is counted" test_ipv6_inbound_counted
run_test "two inbound sessions are counted" test_two_inbound_sessions_counted
run_test "zero inbound sessions returns zero" test_zero_inbound_sessions
run_test "numeric port 22 fallback works" test_numeric_port_fallback
run_test "successful cycle restores exact service state" test_successful_cycle_restores_exact_state
run_test "logout wipe failure fails closed" test_logout_wipe_failure_fails_closed
run_test "login wipe failure remains persisted across count updates" test_login_wipe_failure_status_survives_count_update
run_test "fetch failure does not restore audio-player" test_fetch_failure_does_not_restore_player
run_test "invalid cache does not restore audio-player" test_invalid_cache_does_not_restore_player
run_test "service restart failure preserves diagnostics" test_service_restart_failure_preserves_diagnostics
run_test "reused unrelated PID is not trusted" test_reused_unrelated_pid_not_trusted
run_test "live orphaned fetch preserves logout coordination" test_live_orphaned_fetch_preserves_coordination
run_test "logout wipe failure is attempted once" test_logout_wipe_failure_occurs_once
run_test "later monitor cycles do not retry failed wipe" test_failed_logout_not_retried_by_later_cycles
run_test "new SSH cycle can retry pending recovery" test_new_ssh_cycle_retries_recovery_once
run_test "active service snapshot query is exact" test_snapshot_active_service_state
run_test "inactive service snapshot query is exact" test_snapshot_inactive_service_state
run_test "failed service snapshot query is exact" test_snapshot_failed_service_state
run_test "disabled service snapshot query is exact" test_snapshot_disabled_service_state
run_test "static service snapshot query is accepted" test_snapshot_static_service_state
run_test "systemctl D-Bus/query failure aborts snapshot" test_snapshot_dbus_failure_aborts
run_test "missing unit aborts snapshot" test_snapshot_missing_unit_aborts
run_test "partial snapshot failure stops no service" test_partial_snapshot_failure_stops_no_service

printf '\nSSH smoke remediation: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
