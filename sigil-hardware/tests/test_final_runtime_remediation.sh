#!/bin/bash
# Behavioral regression tests for firstboot runtime repair and SSH logout fetch
# serialization.  These tests source and call the production shell functions.
# Production sources are selected at runtime, their functions consume test
# globals, and cases are invoked through the run_test function registry.
# shellcheck disable=SC1091,SC2034,SC2317

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

run_test() {
    local name="$1"
    local fn="$2"
    if ( "$fn" ); then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL %s\n' "$name"
    fi
}

make_mock_stat() {
    local path="$1"
    local owner="$2"
    local group="$3"
    local mode="$4"
    cat > "$path" <<EOF
#!/bin/bash
case "\${2:-}" in
    %U) printf '%s\\n' '${owner}' ;;
    %G) printf '%s\\n' '${group}' ;;
    %a) printf '%s\\n' '${mode}' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$path"
}

make_ssh_fixture() {
    local tmp="$1"
    mkdir -p "$tmp/run" "$tmp/state" "$tmp/bin"
    chmod 0770 "$tmp/run"

    cat > "$tmp/bin/sudo" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    shift 2
fi
"$@" &
child=$!
wait "$child"
exit $?
EOF
    chmod +x "$tmp/bin/sudo"

    cat > "$tmp/bin/systemctl" <<'EOF'
#!/bin/bash
case "${1:-}" in
    show)
        printf '%s\n' 'LoadState=loaded' 'ActiveState=inactive' 'UnitFileState=disabled'
        ;;
    is-active|is-enabled|is-failed) exit 1 ;;
    stop|start|reset-failed) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$tmp/bin/systemctl"

    cat > "$tmp/bin/cache-wipe" <<'EOF'
#!/bin/bash
set -euo pipefail
[ -f "${SIGIL_RUN_DIR}/ssh-active" ]
printf 'wipe\n' >> "${TEST_EVENT_LOG}"
exit "${MOCK_WIPE_RC:-0}"
EOF
    chmod +x "$tmp/bin/cache-wipe"

    cat > "$tmp/bin/radio-fetcher" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "--validate-active" ]; then
    exit "${MOCK_VALIDATE_RC:-0}"
fi
source "${PRODUCTION_FETCHER}"
ONCE=true
LOG="${TEST_FETCHER_LOG}"
if ! cache_fetch_coordination_allowed "authorized test fetch"; then
    exit 90
fi
printf 'explicit-fetch\n' >> "${TEST_EVENT_LOG}"
: > "${TEST_FETCH_STARTED}"
sleep "${MOCK_FETCH_SLEEP:-0.4}"
exit "${MOCK_FETCH_RC:-0}"
EOF
    chmod +x "$tmp/bin/radio-fetcher"
}

load_ssh_production() {
    local tmp="$1"
    export SIGIL_STATE_DIR="$tmp/state"
    export SIGIL_RUN_DIR="$tmp/run"
    export SIGIL_CACHE_WIPE="$tmp/bin/cache-wipe"
    export SIGIL_RADIO_FETCHER="$tmp/bin/radio-fetcher"
    export SIGIL_FETCH_WRAPPER="${ROOT}/scripts/sigil-logout-fetch-operation.sh"
    export SIGIL_FETCH_OPERATION_FILE="$tmp/run/logout-fetch-operation.json"
    export SIGIL_SERVICE_SNAPSHOT_FILE="$tmp/run/ssh-service-snapshot.json"
    export SIGIL_MARKER_OWNER
    SIGIL_MARKER_OWNER=$(id -un)
    export SIGIL_MARKER_GROUP
    SIGIL_MARKER_GROUP=$(id -gn)
    export TEST_EVENT_LOG="$tmp/events.log"
    export TEST_FETCH_STARTED="$tmp/fetch.started"
    export TEST_FETCHER_LOG="$tmp/fetcher.log"
    export PRODUCTION_FETCHER="${ROOT}/scripts/radio-fetcher.sh"
    PATH="$tmp/bin:$PATH"
    export PATH
    # shellcheck source=../scripts/ssh-monitor.sh
    source "${ROOT}/scripts/ssh-monitor.sh"
    write_service_snapshot >/dev/null 2>&1
}

test_run_sigil_chown_failure_propagates() {
    local tmp rc=0
    tmp=$(mktemp -d /tmp/sigil-runtime-repair.XXXXXX)
    mkdir -p "$tmp/run" "$tmp/bin"
    make_mock_stat "$tmp/bin/stat" "wrong-owner" "sigil" "770"
    cat > "$tmp/bin/chown" <<'EOF'
#!/bin/bash
exit 42
EOF
    chmod +x "$tmp/bin/chown"

    # shellcheck source=../scripts/firstboot.sh
    source "${ROOT}/scripts/firstboot.sh"
    DRY_RUN=false
    SIGIL_RUN_DIR="$tmp/run"
    PATH="$tmp/bin:$PATH"
    export PATH
    if ensure_run_sigil; then
        rc=0
    else
        rc=$?
    fi
    rm -rf "$tmp"
    [ "$rc" -ne 0 ]
}

test_run_sigil_stat_failure_propagates() {
    local tmp rc=0
    tmp=$(mktemp -d /tmp/sigil-runtime-stat.XXXXXX)
    mkdir -p "$tmp/run" "$tmp/bin"
    cat > "$tmp/bin/stat" <<'EOF'
#!/bin/bash
exit 44
EOF
    chmod +x "$tmp/bin/stat"

    # shellcheck source=../scripts/firstboot.sh
    source "${ROOT}/scripts/firstboot.sh"
    DRY_RUN=false
    SIGIL_RUN_DIR="$tmp/run"
    PATH="$tmp/bin:$PATH"
    export PATH
    if ensure_run_sigil; then
        rc=0
    else
        rc=$?
    fi
    rm -rf "$tmp"
    [ "$rc" -ne 0 ]
}

test_run_sigil_verification_mismatch_propagates() {
    local tmp rc=0
    tmp=$(mktemp -d /tmp/sigil-runtime-verify.XXXXXX)
    mkdir -p "$tmp/run" "$tmp/bin"
    make_mock_stat "$tmp/bin/stat" "wrong-owner" "sigil" "770"
    cat > "$tmp/bin/chown" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$tmp/bin/chown"

    # shellcheck source=../scripts/firstboot.sh
    source "${ROOT}/scripts/firstboot.sh"
    DRY_RUN=false
    SIGIL_RUN_DIR="$tmp/run"
    PATH="$tmp/bin:$PATH"
    export PATH
    if ensure_run_sigil; then
        rc=0
    else
        rc=$?
    fi
    rm -rf "$tmp"
    [ "$rc" -ne 0 ]
}

test_logout_fetch_is_serialized_and_awaited() {
    local tmp transition_pid transition_rc=0 normal_rc=0 attempts fetch_exit
    tmp=$(mktemp -d /tmp/sigil-logout-serialize.XXXXXX)
    make_ssh_fixture "$tmp"
    load_ssh_production "$tmp"
    printf 'ssh-monitor:test\n' > "$SSH_ACTIVE_MARKER"
    chmod 0640 "$SSH_ACTIVE_MARKER"
    export MOCK_WIPE_RC=0 MOCK_FETCH_RC=0 MOCK_FETCH_SLEEP=0.6

    exit_maintenance 0 >"$tmp/transition.log" 2>&1 &
    transition_pid=$!
    for _ in $(seq 1 100); do
        [ -f "$TEST_FETCH_STARTED" ] && break
        sleep 0.02
    done
    [ -f "$TEST_FETCH_STARTED" ] || {
        kill "$transition_pid" 2>/dev/null || true
        wait "$transition_pid" 2>/dev/null || true
        rm -rf "$tmp"
        return 1
    }

    # Call the real production sync_cycle as a normal continuous cycle.  It
    # must return before lock/download/swap work while logout-fetch-active is
    # owned by the explicit transition.
    (
        # shellcheck source=../scripts/radio-fetcher.sh
        source "${ROOT}/scripts/radio-fetcher.sh"
        ONCE=false
        LOG="$tmp/continuous.log"
        if sync_cycle; then
            exit 99
        else
            [ "$?" -eq 2 ]
        fi
    ) || normal_rc=$?

    if wait "$transition_pid"; then
        transition_rc=0
    else
        transition_rc=$?
    fi
    attempts=$(grep -c '^explicit-fetch$' "$TEST_EVENT_LOG" 2>/dev/null || true)
    fetch_exit=$(python3 -c "import json; print(json.load(open('${SSH_STATUS_FILE}'))['last_exit']['fetch_exit_code'])")

    [ "$normal_rc" -eq 0 ]
    [ "$transition_rc" -eq 0 ]
    [ "$attempts" -eq 1 ]
    [ "$fetch_exit" -eq 0 ]
    [ ! -e "$SSH_ACTIVE_MARKER" ]
    [ -e "$LOGOUT_FETCH_MARKER" ]
    rm -rf "$tmp"
}

test_logout_persists_real_fetch_failure() {
    local tmp rc=0 attempts fetch_exit fetch_ok
    tmp=$(mktemp -d /tmp/sigil-logout-result.XXXXXX)
    make_ssh_fixture "$tmp"
    load_ssh_production "$tmp"
    printf 'ssh-monitor:test\n' > "$SSH_ACTIVE_MARKER"
    chmod 0640 "$SSH_ACTIVE_MARKER"
    export MOCK_WIPE_RC=0 MOCK_FETCH_RC=23 MOCK_FETCH_SLEEP=0

    if exit_maintenance 0 >"$tmp/transition.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    attempts=$(grep -c '^explicit-fetch$' "$TEST_EVENT_LOG" 2>/dev/null || true)
    read -r fetch_exit fetch_ok < <(python3 -c "import json; d=json.load(open('${SSH_STATUS_FILE}'))['last_exit']; print(d['fetch_exit_code'], str(d['fetch_ok']).lower())")

    [ "$rc" -eq 23 ]
    [ "$attempts" -eq 1 ]
    [ "$fetch_exit" -eq 23 ]
    [ "$fetch_ok" = "false" ]
    [ ! -e "$LOGOUT_FETCH_MARKER" ]
    rm -rf "$tmp"
}

test_logout_wipe_failure_keeps_ssh_marker() {
    local tmp rc=0 count wipe_ok
    tmp=$(mktemp -d /tmp/sigil-logout-wipe.XXXXXX)
    make_ssh_fixture "$tmp"
    load_ssh_production "$tmp"
    printf 'ssh-monitor:test\n' > "$SSH_ACTIVE_MARKER"
    chmod 0640 "$SSH_ACTIVE_MARKER"
    export MOCK_WIPE_RC=9 MOCK_FETCH_RC=0 MOCK_FETCH_SLEEP=0

    if exit_maintenance 0 >"$tmp/transition.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    read -r count wipe_ok < <(python3 -c "import json; d=json.load(open('${SSH_STATUS_FILE}')); print(d['ssh_session_count'], str(d['last_exit']['wipe_ok']).lower())")

    [ "$rc" -ne 0 ]
    [ -f "$SSH_ACTIVE_MARKER" ]
    [ ! -e "$LOGOUT_FETCH_MARKER" ]
    [ ! -e "$TEST_FETCH_STARTED" ]
    [ "$count" -eq 0 ]
    [ "$wipe_ok" = "false" ]
    rm -rf "$tmp"
}

test_stale_logout_marker_is_recovered() {
    local tmp
    tmp=$(mktemp -d /tmp/sigil-logout-stale.XXXXXX)
    make_ssh_fixture "$tmp"
    load_ssh_production "$tmp"
    printf 'ssh-monitor:99999999\n' > "$LOGOUT_FETCH_MARKER"
    chmod 0640 "$LOGOUT_FETCH_MARKER"

    recover_stale_logout_marker
    [ -e "$LOGOUT_FETCH_MARKER" ]
    [ "$(read_ssh_recovery_state)" = "fetch_failed" ]
    rm -rf "$tmp"
}

test_fetcher_cleanup_preserves_failure_status() {
    local tmp rc=0
    tmp=$(mktemp -d /tmp/sigil-fetcher-exit.XXXXXX)
    if bash -c '
        source "$1"
        LOG="$2"
        LOG_LEVEL=DEBUG
        trap cleanup EXIT
        exit 23
    ' bash "${ROOT}/scripts/radio-fetcher.sh" "$tmp/fetcher.log"; then
        rc=0
    else
        rc=$?
    fi
    rm -rf "$tmp"
    [ "$rc" -eq 23 ]
}

test_tmpfiles_precreates_shared_lock_with_group_write() {
    grep -Eq '^f[[:space:]]+/run/sigil/cache-operation\.lock[[:space:]]+0660[[:space:]]+sigil[[:space:]]+sigil([[:space:]]|$)' \
        "${ROOT}/conf/sigil-tmpfiles.conf"
}

printf '%s\n' '=== Final runtime remediation tests ==='
run_test "ensure_run_sigil propagates ownership repair failure" test_run_sigil_chown_failure_propagates
run_test "ensure_run_sigil propagates stat failure" test_run_sigil_stat_failure_propagates
run_test "ensure_run_sigil rejects ineffective metadata repair" test_run_sigil_verification_mismatch_propagates
run_test "SSH logout serializes and awaits exactly one fetch" test_logout_fetch_is_serialized_and_awaited
run_test "SSH logout persists the real fetch exit code" test_logout_persists_real_fetch_failure
run_test "SSH logout wipe failure retains ssh-active" test_logout_wipe_failure_keeps_ssh_marker
run_test "stale logout-fetch coordination is recovered" test_stale_logout_marker_is_recovered
run_test "radio-fetcher cleanup preserves failure exit status" test_fetcher_cleanup_preserves_failure_status
run_test "tmpfiles precreates the shared lock as sigil:sigil 0660" test_tmpfiles_precreates_shared_lock_with_group_write

printf '\nRuntime remediation: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' 'Failed tests:'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
