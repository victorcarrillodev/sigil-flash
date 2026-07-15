#!/bin/bash
# Realistic process-control tests for the SSH logout fetch operation.
# The source path is computed at runtime and test globals are consumed by the
# sourced production functions.
# shellcheck disable=SC1091,SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=../scripts/ssh-monitor.sh
source "${ROOT}/scripts/ssh-monitor.sh"
set +e

PASS=0
FAIL=0
CASE_DIR=""
ORIGINAL_PATH="$PATH"

cleanup_case() {
    if [ -f "${FETCH_OPERATION_FILE:-}" ] && fetch_operation_is_live 2>/dev/null; then
        kill_fetch_operation
    fi
    [ -z "$CASE_DIR" ] || rm -rf "$CASE_DIR"
    CASE_DIR=""
    PATH="$ORIGINAL_PATH"
}
trap cleanup_case EXIT

run_test() {
    local name="$1" fn="$2"
    if "$fn"; then
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
    CASE_DIR=$(mktemp -d /tmp/sigil-fetch-topology.XXXXXX)
    mkdir -p "$CASE_DIR/run" "$CASE_DIR/bin" "$CASE_DIR/state"
    chmod 0770 "$CASE_DIR/run"
    RUN_SIGIL_DIR="$CASE_DIR/run"
    STATE_DIR="$CASE_DIR/state"
    SSH_STATUS_FILE="$STATE_DIR/ssh_status.json"
    SSH_ACTIVE_MARKER="$RUN_SIGIL_DIR/ssh-active"
    LOGOUT_FETCH_MARKER="$RUN_SIGIL_DIR/logout-fetch-active"
    SERVICE_SNAPSHOT_FILE="$RUN_SIGIL_DIR/ssh-service-snapshot.json"
    FETCH_OPERATION_FILE="$RUN_SIGIL_DIR/logout-fetch-operation.json"
    FETCH_WRAPPER="$ROOT/scripts/sigil-logout-fetch-operation.sh"
    RADIO_FETCHER="$CASE_DIR/bin/radio-fetcher"
    PROC_ROOT=/proc
    MARKER_OWNER=$(id -un)
    MARKER_GROUP=$(id -gn)
    LAST_FETCH_EXIT=""
    LAST_FETCH_LAUNCH_PID=""
    ACTIVE_FETCH_PID=""
    export TEST_TOPOLOGY_LOG="$CASE_DIR/topology.log"
    export MOCK_FETCH_SLEEP=0.15 MOCK_FETCH_RC=0
    : > "$TEST_TOPOLOGY_LOG"

    cat > "$CASE_DIR/bin/sudo" <<'EOF'
#!/bin/bash
set -u
if [ "${1:-}" = "-u" ]; then shift 2; fi
printf 'sudo-parent:%s:%s\n' "$$" "$PPID" >> "$TEST_TOPOLOGY_LOG"
"$@" &
child=$!
printf 'sudo-child:%s\n' "$child" >> "$TEST_TOPOLOGY_LOG"
wait "$child"
exit $?
EOF
    cat > "$RADIO_FETCHER" <<'EOF'
#!/bin/bash
set -u
printf 'worker-start:%s:%s\n' "$$" "$PPID" >> "$TEST_TOPOLOGY_LOG"
trap 'printf "worker-term:%s\n" "$$" >> "$TEST_TOPOLOGY_LOG"; exit 143' TERM INT HUP
sleep "${MOCK_FETCH_SLEEP:-0.15}"
printf 'worker-exit:%s:%s\n' "$$" "${MOCK_FETCH_RC:-0}" >> "$TEST_TOPOLOGY_LOG"
exit "${MOCK_FETCH_RC:-0}"
EOF
    chmod +x "$CASE_DIR/bin/sudo" "$RADIO_FETCHER"
    PATH="$CASE_DIR/bin:$ORIGINAL_PATH"
    export PATH
}

operation_child_fields() {
    python3 - "$FETCH_OPERATION_FILE" <<'PYEOF'
import json
import sys
operation = json.load(open(sys.argv[1], encoding="utf-8"))
print(operation.get("worker_pid"), operation.get("worker_start_time_ticks"), operation.get("exit_code"))
PYEOF
}

test_real_sudo_parent_and_child_success() {
    setup_case
    launch_explicit_fetch || return 1
    [ "$LAST_FETCH_EXIT" -eq 0 ] || return 1
    local sudo_child worker_parent child_pid child_start recorded_exit
    sudo_child=$(awk -F: '/^sudo-child:/ {print $2}' "$TEST_TOPOLOGY_LOG")
    worker_parent=$(awk -F: '/^worker-start:/ {print $3}' "$TEST_TOPOLOGY_LOG")
    [ -n "$sudo_child" ] && [ "$sudo_child" = "$worker_parent" ] || return 1
    read -r child_pid child_start recorded_exit < <(operation_child_fields)
    [[ "$child_pid" =~ ^[0-9]+$ ]] && [[ "$child_start" =~ ^[0-9]+$ ]] || return 1
    [ "$recorded_exit" = "0" ] || return 1
    grep -q '^worker-exit:.*:0$' "$TEST_TOPOLOGY_LOG" || return 1
    ! grep -q '^worker-term:' "$TEST_TOPOLOGY_LOG"
}

test_wrapper_exits_before_child_discovery() {
    setup_case
    FETCH_WRAPPER="$CASE_DIR/bin/early-wrapper"
    cat > "$FETCH_WRAPPER" <<'EOF'
#!/bin/bash
radio_fetcher="$3"
SIGIL_LOGOUT_OPERATION_ID="$1" bash "$radio_fetcher" --once &
exit 0
EOF
    chmod +x "$FETCH_WRAPPER"
    export MOCK_FETCH_SLEEP=4
    local rc=0 worker_pid
    launch_explicit_fetch || rc=$?
    [ "$rc" -eq 125 ] || return 1
    # The wrapper is intentionally allowed to exit before its child emits its
    # discovery marker; poll briefly instead of making that scheduling window
    # a false production failure.
    worker_pid=""
    for _ in $(seq 1 100); do
        worker_pid=$(awk -F: '/^worker-start:/ {print $2}' "$TEST_TOPOLOGY_LOG" | tail -1)
        [ -n "$worker_pid" ] && break
        sleep 0.05
    done
    [ -n "$worker_pid" ] || return 1
    for _ in $(seq 1 30); do
        kill -0 "$worker_pid" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

test_child_exits_before_proc_capture() {
    setup_case
    export MOCK_FETCH_SLEEP=0 MOCK_FETCH_RC=7
    local rc=0
    launch_explicit_fetch || rc=$?
    [ "$rc" -eq 7 ] && [ "$LAST_FETCH_EXIT" -eq 7 ]
}

write_synthetic_process() {
    local root="$1" pid="$2" start="$3" pgrp="$4" script="$5" operation_id="$6"
    mkdir -p "$root/$pid"
    python3 - "$root/$pid/stat" "$pid" "$start" "$pgrp" <<'PYEOF'
import sys
path, pid, start, pgrp = sys.argv[1:]
fields = ["S", "1", pgrp] + ["0"] * 16 + [start]
open(path, "w", encoding="utf-8").write("{} (bash) {}\n".format(pid, " ".join(fields)))
PYEOF
    printf '/bin/bash\000%s\000--once\000' "$script" > "$root/$pid/cmdline"
    printf 'SIGIL_LOGOUT_OPERATION_ID=%s\000' "$operation_id" > "$root/$pid/environ"
}

test_wrapper_pid_reuse_rejected() {
    setup_case
    PROC_ROOT="$CASE_DIR/proc"
    write_synthetic_process "$PROC_ROOT" 4101 222 700 "$FETCH_WRAPPER" reuse-wrapper
    write_fetch_operation reuse-wrapper running "$RUN_SIGIL_DIR/result.json" 4101 111 700 || return 1
    ! fetch_operation_is_live
}

test_child_pid_reuse_rejected() {
    setup_case
    PROC_ROOT="$CASE_DIR/proc"
    write_synthetic_process "$PROC_ROOT" 4102 333 701 "$RADIO_FETCHER" reuse-child
    write_fetch_operation reuse-child running "$RUN_SIGIL_DIR/result.json" "" "" 701 4102 222 || return 1
    ! fetch_operation_is_live
}

wait_for_live_operation() {
    for _ in $(seq 1 100); do
        [ -f "$FETCH_OPERATION_FILE" ] && fetch_operation_is_live && return 0
        sleep 0.02
    done
    return 1
}

test_monitor_restart_recovers_live_operation() {
    setup_case
    export MOCK_FETCH_SLEEP=0.8
    launch_explicit_fetch >/dev/null 2>&1 &
    local launcher=$!
    wait_for_live_operation || return 1
    printf 'ssh-monitor:999999:123\n' > "$LOGOUT_FETCH_MARKER"
    write_ssh_status 0 true "" "" "" false false "" true "" fetch_in_progress || return 1
    RECOVERED_FETCH_IN_PROGRESS=false
    recover_stale_logout_marker >/dev/null 2>&1 || return 1
    $RECOVERED_FETCH_IN_PROGRESS || return 1
    wait "$launcher" || return 1
    [ "$(get_recorded_fetch_exit)" -eq 0 ]
}

test_duplicate_explicit_fetch_refused() {
    setup_case
    export MOCK_FETCH_SLEEP=0.8
    launch_explicit_fetch >/dev/null 2>&1 &
    local launcher=$! rc=0
    wait_for_live_operation || return 1
    launch_explicit_fetch >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 75 ] || return 1
    wait "$launcher" || return 1
    [ "$(grep -c '^worker-start:' "$TEST_TOPOLOGY_LOG")" -eq 1 ]
}

test_failure_exit_persisted_in_operation() {
    setup_case
    export MOCK_FETCH_SLEEP=0 MOCK_FETCH_RC=23
    local rc=0
    launch_explicit_fetch || rc=$?
    [ "$rc" -eq 23 ] || return 1
    [ "$LAST_FETCH_EXIT" -eq 23 ] || return 1
    [ "$(get_recorded_fetch_exit)" -eq 23 ] || return 1
    [ "$(operation_child_fields | awk '{print $3}')" = "23" ]
}

test_no_wrapper_or_child_orphan() {
    setup_case
    export MOCK_FETCH_SLEEP=0.05
    launch_explicit_fetch || return 1
    local pid
    while IFS=: read -r kind pid _; do
        case "$kind" in sudo-parent|sudo-child|worker-start)
            kill -0 "$pid" 2>/dev/null && return 1
            ;;
        esac
    done < "$TEST_TOPOLOGY_LOG"
    return 0
}

printf '%s\n' '=== SSH logout process-topology tests ==='
run_test 'real sudo parent/child topology succeeds without killing fetch' test_real_sudo_parent_and_child_success
run_test 'wrapper exit before child discovery is contained' test_wrapper_exits_before_child_discovery
run_test 'child exit before proc capture preserves real status' test_child_exits_before_proc_capture
run_test 'wrapper PID reuse is rejected' test_wrapper_pid_reuse_rejected
run_test 'child PID reuse is rejected' test_child_pid_reuse_rejected
run_test 'monitor restart recognizes live operation' test_monitor_restart_recovers_live_operation
run_test 'duplicate explicit fetch is refused' test_duplicate_explicit_fetch_refused
run_test 'fetch failure exit is persisted' test_failure_exit_persisted_in_operation
run_test 'no wrapper or child remains orphaned' test_no_wrapper_or_child_orphan

printf '\nProcess topology: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
