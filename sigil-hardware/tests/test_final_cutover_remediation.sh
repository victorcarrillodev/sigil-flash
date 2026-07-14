#!/bin/bash
# Behavioral tests for the production cutover/rollback restoration and
# canonical audio-player identity functions.
# The source path is computed at runtime and test globals are consumed by the
# sourced production functions.
# shellcheck disable=SC1091,SC2034

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK="${HERE}/../scripts/sigil-phase2-rollback.sh"

# Sourcing rollback also sources cutover. Both scripts guard main(), so these
# are the exact production functions used during deployment.
# shellcheck source=../scripts/sigil-phase2-rollback.sh
source "$ROLLBACK"
set +e

PASS=0
FAIL=0
TEST_ROOT=""
MOCK_SERVICE_DIR=""

cleanup_case() {
    if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
        rm -rf "$TEST_ROOT"
    fi
    TEST_ROOT=""
}
trap cleanup_case EXIT

systemctl() {
    local command="${1:-}"
    shift || true
    local service="${1:-}"
    local key="${service%.service}"
    case "$command" in
        is-active)
            if [ -f "${MOCK_SERVICE_DIR}/${key}.active" ]; then
                echo active
                return 0
            fi
            echo inactive
            return 3
            ;;
        is-enabled)
            if [ -f "${MOCK_SERVICE_DIR}/${key}.enabled" ]; then
                echo enabled
                return 0
            fi
            echo disabled
            return 1
            ;;
        start)
            touch "${MOCK_SERVICE_DIR}/${key}.active"
            ;;
        stop|kill)
            rm -f "${MOCK_SERVICE_DIR}/${key}.active"
            ;;
        enable)
            touch "${MOCK_SERVICE_DIR}/${key}.enabled"
            ;;
        disable)
            rm -f "${MOCK_SERVICE_DIR}/${key}.enabled"
            ;;
        show)
            if [ -f "${MOCK_SERVICE_DIR}/${key}.mainpid" ]; then
                cat "${MOCK_SERVICE_DIR}/${key}.mainpid"
            else
                echo 0
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

sleep() { :; }
journalctl() { :; }

setup_case() {
    cleanup_case
    TEST_ROOT=$(mktemp -d /tmp/sigil-final-cutover-test.XXXXXX)
    MOCK_SERVICE_DIR="${TEST_ROOT}/services"
    SIGIL_ETC="${TEST_ROOT}/etc"
    SIGIL_STATE="${TEST_ROOT}/state"
    BACKUP_DIR="${SIGIL_STATE}/backups"
    SIGIL_BIN="${TEST_ROOT}/bin"
    PROC_ROOT="${TEST_ROOT}/proc"
    PLAYER_LOCK_FILE="${TEST_ROOT}/sigil-audio-player.lock"
    mkdir -p "$MOCK_SERVICE_DIR" "$SIGIL_ETC" "$BACKUP_DIR" "$SIGIL_BIN" "$PROC_ROOT"
    printf '#!/bin/bash\nexit 0\n' > "${SIGIL_BIN}/audio-player.sh"
    chmod 755 "${SIGIL_BIN}/audio-player.sh"
    printf 'flock-state-not-json\n' > "$PLAYER_LOCK_FILE"
    MODE="apply"
}

set_service_state() {
    local service="$1"
    local active="$2"
    local enabled="$3"
    local key="${service%.service}"
    rm -f "${MOCK_SERVICE_DIR}/${key}.active" "${MOCK_SERVICE_DIR}/${key}.enabled"
    [ "$active" = "active" ] && touch "${MOCK_SERVICE_DIR}/${key}.active"
    [ "$enabled" = "enabled" ] && touch "${MOCK_SERVICE_DIR}/${key}.enabled"
    return 0
}

expect_service_state() {
    local service="$1"
    local expected_active="$2"
    local expected_enabled="$3"
    local actual_active="inactive"
    local actual_enabled="disabled"
    systemctl is-active "$service" >/dev/null 2>&1 && actual_active="active"
    systemctl is-enabled "$service" >/dev/null 2>&1 && actual_enabled="enabled"
    [ "$actual_active" = "$expected_active" ] && [ "$actual_enabled" = "$expected_enabled" ]
}

write_snapshot() {
    local dir="$1"
    local json="$2"
    mkdir -p "$dir"
    printf '%s\n' "$json" > "${dir}/service-snapshot.json"
}

create_mock_process() {
    local pid="$1"
    local kind="$2"
    local holds_lock="${3:-false}"
    local canonical
    canonical=$(readlink -f "${SIGIL_BIN}/audio-player.sh")
    mkdir -p "${PROC_ROOT}/${pid}/fd"
    case "$kind" in
        genuine)
            printf '/bin/bash\0%s\0' "$canonical" > "${PROC_ROOT}/${pid}/cmdline"
            ;;
        unrelated)
            printf '/bin/bash\0-c\0echo inspecting %s\0' "$canonical" > "${PROC_ROOT}/${pid}/cmdline"
            ;;
        *) return 1 ;;
    esac
    if [ "$holds_lock" = "true" ]; then
        ln -s "$PLAYER_LOCK_FILE" "${PROC_ROOT}/${pid}/fd/200"
    fi
}

test_backup_records_all_managed_services_exactly() {
    setup_case
    set_service_state radio-stream.service active disabled
    set_service_state radio-fetcher.service inactive enabled
    set_service_state audio-manager.service active enabled
    set_service_state audio-player.service inactive disabled
    set_service_state ssh-monitor.service active enabled

    create_backup >/dev/null 2>&1 || return 1
    [ -n "$CREATED_BACKUP_DIR" ] && [ -d "$CREATED_BACKUP_DIR" ] || return 1
    python3 - "${CREATED_BACKUP_DIR}/service-snapshot.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
expected = {
    "radio-stream.service": {"active": "active", "enabled": "disabled"},
    "radio-fetcher.service": {"active": "inactive", "enabled": "enabled"},
    "audio-manager.service": {"active": "active", "enabled": "enabled"},
    "audio-player.service": {"active": "inactive", "enabled": "disabled"},
    "ssh-monitor.service": {"active": "active", "enabled": "enabled"},
}
raise SystemExit(0 if snapshot == expected else 1)
PY
}

test_partial_rollback_restores_every_snapshot_service() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-partial"
    write_snapshot "$snapshot" '{
      "radio-stream.service": {"active":"active", "enabled":"enabled"},
      "radio-fetcher.service": {"active":"inactive", "enabled":"enabled"},
      "audio-manager.service": {"active":"active", "enabled":"disabled"},
      "audio-player.service": {"active":"inactive", "enabled":"disabled"},
      "ssh-monitor.service": {"active":"active", "enabled":"enabled"},
      "future-snapshot.service": {"active":"inactive", "enabled":"enabled"}
    }'

    set_service_state radio-stream.service inactive disabled
    set_service_state radio-fetcher.service active disabled
    set_service_state audio-manager.service inactive enabled
    set_service_state audio-player.service active enabled
    set_service_state ssh-monitor.service inactive disabled
    set_service_state future-snapshot.service active disabled

    do_rollback_after_failure "$snapshot" >/dev/null 2>&1
    local rc=$?
    [ "$rc" -eq 1 ] || return 1
    expect_service_state radio-stream.service active enabled || return 1
    expect_service_state radio-fetcher.service inactive enabled || return 1
    expect_service_state audio-manager.service active disabled || return 1
    expect_service_state audio-player.service inactive disabled || return 1
    expect_service_state ssh-monitor.service active enabled || return 1
    expect_service_state future-snapshot.service inactive enabled
}

test_explicit_rollback_accepts_inactive_disabled_legacy() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-explicit"
    write_snapshot "$snapshot" '{
      "radio-stream.service": {"active":"inactive", "enabled":"disabled"},
      "radio-fetcher.service": {"active":"inactive", "enabled":"enabled"},
      "audio-manager.service": {"active":"active", "enabled":"disabled"},
      "audio-player.service": {"active":"inactive", "enabled":"disabled"},
      "ssh-monitor.service": {"active":"active", "enabled":"enabled"}
    }'
    set_service_state radio-stream.service active enabled
    set_service_state radio-fetcher.service active disabled
    set_service_state audio-manager.service inactive enabled
    set_service_state audio-player.service active enabled
    set_service_state ssh-monitor.service inactive disabled

    do_apply >/dev/null 2>&1 || return 1
    expect_service_state radio-stream.service inactive disabled || return 1
    expect_service_state radio-fetcher.service inactive enabled || return 1
    expect_service_state audio-manager.service active disabled || return 1
    expect_service_state audio-player.service inactive disabled || return 1
    expect_service_state ssh-monitor.service active enabled
}

test_legacy_inactive_enabled_remains_inactive() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-legacy-inactive"
    write_snapshot "$snapshot" '{"radio-stream.service":{"active":"inactive","enabled":"enabled"}}'
    set_service_state radio-stream.service active disabled

    do_apply >/dev/null 2>&1 || return 1
    expect_service_state radio-stream.service inactive enabled
}

test_legacy_active_disabled_remains_disabled() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-legacy-disabled"
    write_snapshot "$snapshot" '{"radio-stream.service":{"active":"active","enabled":"disabled"}}'
    set_service_state radio-stream.service inactive enabled

    do_apply >/dev/null 2>&1 || return 1
    expect_service_state radio-stream.service active disabled
}

test_enabled_inactive_restored_exactly() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-enabled-inactive"
    write_snapshot "$snapshot" '{"audio-manager.service":{"active":"inactive","enabled":"enabled"}}'
    set_service_state audio-manager.service active disabled
    restore_service_from_snapshot audio-manager.service "$snapshot" >/dev/null 2>&1 || return 1
    expect_service_state audio-manager.service inactive enabled
}

test_disabled_active_restored_exactly() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-disabled-active"
    write_snapshot "$snapshot" '{"audio-manager.service":{"active":"active","enabled":"disabled"}}'
    set_service_state audio-manager.service inactive enabled
    restore_service_from_snapshot audio-manager.service "$snapshot" >/dev/null 2>&1 || return 1
    expect_service_state audio-manager.service active disabled
}

test_backup_file_content_and_metadata_restored() {
    setup_case
    local snapshot="${BACKUP_DIR}/phase2-cutover-files"
    mkdir -p "$snapshot"
    printf 'original\n' > "${snapshot}/audio.conf"
    chmod 640 "${snapshot}/audio.conf"
    printf 'mutated\n' > "${SIGIL_ETC}/audio.conf"
    chmod 600 "${SIGIL_ETC}/audio.conf"

    restore_files_from_snapshot "$snapshot" audio.conf >/dev/null 2>&1 || return 1
    cmp -s "${snapshot}/audio.conf" "${SIGIL_ETC}/audio.conf" || return 1
    [ "$(stat -c '%u:%g:%a' "${snapshot}/audio.conf")" = "$(stat -c '%u:%g:%a' "${SIGIL_ETC}/audio.conf")" ]
}

test_one_genuine_player_passes() {
    setup_case
    set_service_state audio-player.service active disabled
    printf '101\n' > "${MOCK_SERVICE_DIR}/audio-player.mainpid"
    create_mock_process 101 genuine true
    confirm_no_duplicate_player >/dev/null 2>&1
}

test_two_genuine_players_fail() {
    setup_case
    set_service_state audio-player.service active disabled
    printf '101\n' > "${MOCK_SERVICE_DIR}/audio-player.mainpid"
    create_mock_process 101 genuine true
    create_mock_process 202 genuine false
    ! confirm_no_duplicate_player >/dev/null 2>&1
}

test_unrelated_mention_is_ignored() {
    setup_case
    set_service_state audio-player.service active disabled
    printf '101\n' > "${MOCK_SERVICE_DIR}/audio-player.mainpid"
    create_mock_process 101 genuine true
    create_mock_process 303 unrelated false
    confirm_no_duplicate_player >/dev/null 2>&1
}

test_zero_player_valid_when_service_inactive() {
    setup_case
    set_service_state audio-player.service inactive disabled
    printf '0\n' > "${MOCK_SERVICE_DIR}/audio-player.mainpid"
    confirm_no_duplicate_player >/dev/null 2>&1
}

run_test() {
    local function_name="$1"
    local label="$2"
    local log_file
    log_file=$(mktemp /tmp/sigil-final-cutover-log.XXXXXX)
    if "$function_name" >"$log_file" 2>&1; then
        PASS=$((PASS + 1))
        printf '  ok  %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$label"
        sed 's/^/       /' "$log_file"
    fi
    rm -f "$log_file"
    cleanup_case
}

echo "SIGIL final cutover remediation tests"
echo "======================================"
run_test test_backup_records_all_managed_services_exactly "backup records all managed service states exactly"
run_test test_partial_rollback_restores_every_snapshot_service "partial rollback restores every service in snapshot"
run_test test_explicit_rollback_accepts_inactive_disabled_legacy "explicit rollback accepts legacy inactive and disabled"
run_test test_legacy_inactive_enabled_remains_inactive "legacy initially inactive remains inactive"
run_test test_legacy_active_disabled_remains_disabled "legacy initially disabled remains disabled"
run_test test_enabled_inactive_restored_exactly "enabled/inactive state restored exactly"
run_test test_disabled_active_restored_exactly "disabled/active state restored exactly"
run_test test_backup_file_content_and_metadata_restored "backup content, owner, group, and mode restored"
run_test test_one_genuine_player_passes "one genuine canonical player passes"
run_test test_two_genuine_players_fail "two genuine canonical players fail"
run_test test_unrelated_mention_is_ignored "unrelated command mentioning audio-player.sh ignored"
run_test test_zero_player_valid_when_service_inactive "zero players valid for inactive service"

echo "======================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
