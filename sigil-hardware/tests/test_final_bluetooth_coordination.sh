#!/bin/bash
# Production-behavior tests for canonical Bluetooth ownership and flock.
# shellcheck disable=SC2317
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
OWNER="${ROOT}/scripts/bt-connect.sh"
PASS=0
FAIL=0
FAILED=()
TEST_DIR=""

OLD_MAC="02:00:00:00:00:01"
NEW_MAC="02:00:00:00:00:02"
THIRD_MAC="02:00:00:00:00:03"
NON_AUDIO_MAC="02:00:00:00:00:04"

ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  FAIL %s\n' "$1"; }
assert_true() { if "$@"; then return 0; else return 1; fi; }
has_pattern() {
    local pattern="$1"; shift
    if command -v rg >/dev/null 2>&1; then rg -q -- "$pattern" "$@"; else grep -Eq -- "$pattern" "$@"; fi
}

run_test() {
    local label="$1" function="$2"
    printf '=== %s ===\n' "$label"
    if "$function"; then ok "$label"; else not_ok "$label"; fi
    teardown
}

teardown() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
}
trap teardown EXIT

setup() {
    teardown
    TEST_DIR=$(mktemp -d /tmp/sigil-bt-test.XXXXXX)
    mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/state"
    : > "${TEST_DIR}/events"
    : > "${TEST_DIR}/state/paired"
    : > "${TEST_DIR}/state/trusted"
    : > "${TEST_DIR}/state/connected"
    printf '0\n' > "${TEST_DIR}/state/active"

    cat > "${TEST_DIR}/bin/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK

    cat > "${TEST_DIR}/bin/sudo" <<'MOCK'
#!/bin/bash
exit 0
MOCK

    cat > "${TEST_DIR}/bin/hciconfig" <<'MOCK'
#!/bin/bash
printf 'hci0: UP RUNNING\n'
MOCK

    cat > "${TEST_DIR}/bin/pactl" <<'MOCK'
#!/bin/bash
printf '1 module-bluetooth-discover\n'
MOCK

    cat > "${TEST_DIR}/audio-route.sh" <<'MOCK'
#!/bin/bash
audio_route_activate_bluetooth() {
    printf '%s\n' "$1" >> "${MOCK_AUDIO_LOG}"
    [ "${MOCK_FAIL_A2DP_MAC:-}" != "$1" ]
}
MOCK

    cat > "${TEST_DIR}/bin/bluetoothctl" <<'MOCK'
#!/bin/bash
set -u
state=${MOCK_BT_STATE:?}
events=${MOCK_BT_EVENTS:?}
command=${1:-}
argument=${2:-}

contains() { grep -qxF "$2" "$1" 2>/dev/null; }
add_value() {
    contains "$1" "$2" || printf '%s\n' "$2" >> "$1"
}
remove_value() {
    local temporary
    temporary=$(mktemp "${state}/list.XXXXXX")
    grep -vxF "$2" "$1" > "$temporary" || true
    mv -f "$temporary" "$1"
}
mutation_begin() {
    local active
    exec 8> "${state}/counter.lock"
    flock 8
    active=$(cat "${state}/active")
    if [ "$active" -gt 0 ]; then touch "${state}/overlap"; fi
    printf '%s\n' "$((active + 1))" > "${state}/active"
    flock -u 8
    printf 'BEGIN %s %s\n' "$command" "$argument" >> "$events"
    /bin/sleep "${MOCK_MUTATION_DELAY:-0.04}"
}
mutation_end() {
    local active
    exec 8> "${state}/counter.lock"
    flock 8
    active=$(cat "${state}/active")
    printf '%s\n' "$((active - 1))" > "${state}/active"
    flock -u 8
    printf 'END %s %s\n' "$command" "$argument" >> "$events"
}

case "$command" in
    show)
        printf 'UUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)\n'
        ;;
    devices)
        if [ "$argument" = Connected ]; then
            while IFS= read -r mac; do
                [ -n "$mac" ] && printf 'Device %s Test speaker\n' "$mac"
            done < "${state}/connected"
        fi
        ;;
    info)
        mac=$argument
        if ! contains "${state}/paired" "$mac" \
            && ! contains "${state}/connected" "$mac"; then
            exit 1
        fi
        printf 'Device %s\n' "$mac"
        if contains "${state}/paired" "$mac"; then printf '    Paired: yes\n'; else printf '    Paired: no\n'; fi
        if contains "${state}/trusted" "$mac"; then printf '    Trusted: yes\n'; else printf '    Trusted: no\n'; fi
        if contains "${state}/connected" "$mac"; then printf '    Connected: yes\n'; else printf '    Connected: no\n'; fi
        if [ "$mac" = "${MOCK_NON_AUDIO_MAC:-none}" ]; then
            printf '    UUID: Human Interface Device (00001124-0000-1000-8000-00805f9b34fb)\n'
            printf '    Class: 0x00000540\n'
        else
            printf '    UUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)\n'
            printf '    Class: 0x00200414\n'
        fi
        ;;
    scan|power|unblock|block|trust|untrust|pair|connect|disconnect|remove)
        mutation_begin
        mac=$argument
        case "$command" in
            trust) add_value "${state}/trusted" "$mac" ;;
            untrust) remove_value "${state}/trusted" "$mac" ;;
            pair)
                /bin/sleep "${MOCK_PAIR_DELAY:-0}"
                if [ "${MOCK_FAIL_PAIR_MAC:-}" = "$mac" ]; then
                    mutation_end
                    printf 'Failed to pair\n' >&2
                    exit 1
                fi
                add_value "${state}/paired" "$mac"
                ;;
            connect)
                /bin/sleep "${MOCK_CONNECT_DELAY:-0}"
                if [ "${MOCK_FAIL_CONNECT_MAC:-}" = "$mac" ]; then
                    mutation_end
                    printf 'Failed to connect\n' >&2
                    exit 1
                fi
                add_value "${state}/connected" "$mac"
                ;;
            disconnect) remove_value "${state}/connected" "$mac" ;;
            remove)
                if [ "${MOCK_FAIL_REMOVE_MAC:-}" = "$mac" ]; then
                    mutation_end
                    printf 'Failed to remove\n' >&2
                    exit 1
                fi
                remove_value "${state}/connected" "$mac"
                remove_value "${state}/trusted" "$mac"
                remove_value "${state}/paired" "$mac"
                ;;
        esac
        mutation_end
        ;;
    *) exit 1 ;;
esac
MOCK

    chmod +x "${TEST_DIR}/bin/"* "${TEST_DIR}/audio-route.sh"
    export PATH="${TEST_DIR}/bin:/usr/bin:/bin"
    export SIGIL_BT_PREFERRED_FILE="${TEST_DIR}/preferred_bt.txt"
    export SIGIL_BT_LOCK_FILE="${TEST_DIR}/bluetooth-transition.lock"
    export SIGIL_BT_LOG_FILE="${TEST_DIR}/bt.log"
    export SIGIL_AUDIO_ROUTE_HELPER="${TEST_DIR}/audio-route.sh"
    export MOCK_BT_STATE="${TEST_DIR}/state"
    export MOCK_BT_EVENTS="${TEST_DIR}/events"
    export MOCK_AUDIO_LOG="${TEST_DIR}/audio.log"
    export MOCK_NON_AUDIO_MAC="$NON_AUDIO_MAC"
    export MOCK_MUTATION_DELAY=0.04
    unset MOCK_FAIL_PAIR_MAC MOCK_FAIL_CONNECT_MAC MOCK_FAIL_REMOVE_MAC
    unset MOCK_FAIL_A2DP_MAC MOCK_PAIR_DELAY MOCK_CONNECT_DELAY
}

add_paired() { printf '%s\n' "$1" >> "${TEST_DIR}/state/paired"; }
add_trusted() { printf '%s\n' "$1" >> "${TEST_DIR}/state/trusted"; }
add_connected() { printf '%s\n' "$1" >> "${TEST_DIR}/state/connected"; }
set_preferred() { printf '%s\n' "$1" > "$SIGIL_BT_PREFERRED_FILE"; chmod 0600 "$SIGIL_BT_PREFERRED_FILE"; }

owner_request() {
    local rc=0
    OWNER_OUTPUT=$("$OWNER" request "$@") || rc=$?
    OWNER_RC=$rc
}

json_field() {
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

test_pair_and_auto_reconnect_serialized() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"; add_trusted "$OLD_MAC"
    export MOCK_PAIR_DELAY=0.25
    "$OWNER" request pair "$NEW_MAC" > "${TEST_DIR}/pair.json" 2>/dev/null &
    local pair_pid=$!
    /bin/sleep 0.03
    SIGIL_BT_RUN_ONCE=1 "$OWNER" > "${TEST_DIR}/auto.out" 2>/dev/null &
    local auto_pid=$!
    wait "$pair_pid" && wait "$auto_pid"
    [ ! -e "${TEST_DIR}/state/overlap" ]
}

test_connect_and_remove_serialized() {
    setup
    add_paired "$NEW_MAC"; add_paired "$THIRD_MAC"
    export MOCK_CONNECT_DELAY=0.25
    "$OWNER" request connect "$NEW_MAC" > "${TEST_DIR}/connect.json" 2>/dev/null &
    local connect_pid=$!
    /bin/sleep 0.03
    "$OWNER" request remove "$THIRD_MAC" > "${TEST_DIR}/remove.json" 2>/dev/null &
    local remove_pid=$!
    wait "$connect_pid" && wait "$remove_pid"
    [ ! -e "${TEST_DIR}/state/overlap" ]
}

test_preferred_normalized_atomic_private() {
    setup
    add_paired "$NEW_MAC"
    set_preferred "$OLD_MAC"
    local old_inode new_inode
    old_inode=$(stat -c %i "$SIGIL_BT_PREFERRED_FILE")
    owner_request connect "${NEW_MAC,,}"
    new_inode=$(stat -c %i "$SIGIL_BT_PREFERRED_FILE")
    [ "$OWNER_RC" -eq 0 ] \
        && [ "$(cat "$SIGIL_BT_PREFERRED_FILE")" = "$NEW_MAC" ] \
        && [ "$old_inode" != "$new_inode" ] \
        && [ "$(stat -c %a "$SIGIL_BT_PREFERRED_FILE")" = 600 ] \
        && ! find "$TEST_DIR" -name '.preferred_bt.*' | grep -q .
}

test_preferred_symlink_never_followed() {
    setup
    local target="${TEST_DIR}/outside-state"
    printf '%s\n' "$OLD_MAC" > "$target"
    ln -s "$target" "$SIGIL_BT_PREFERRED_FILE"
    owner_request disconnect
    [ "$OWNER_RC" -ne 0 ] \
        && [ "$(json_field "$OWNER_OUTPUT" code)" = state_write_failed ] \
        && [ -L "$SIGIL_BT_PREFERRED_FILE" ] \
        && [ "$(cat "$target")" = "$OLD_MAC" ]
}

test_failed_target_preserves_old_preferred() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"; add_paired "$NEW_MAC"
    export MOCK_FAIL_CONNECT_MAC="$NEW_MAC"
    owner_request connect "$NEW_MAC"
    [ "$OWNER_RC" -ne 0 ] \
        && [ "$(json_field "$OWNER_OUTPUT" success)" = False ] \
        && [ "$(cat "$SIGIL_BT_PREFERRED_FILE")" = "$OLD_MAC" ]
}

test_success_updates_only_after_completion() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$NEW_MAC"
    export MOCK_CONNECT_DELAY=0.35
    "$OWNER" request connect "$NEW_MAC" > "${TEST_DIR}/result.json" 2>/dev/null &
    local owner_pid=$!
    /bin/sleep 0.12
    local during
    during=$(cat "$SIGIL_BT_PREFERRED_FILE")
    wait "$owner_pid"
    [ "$during" = "$OLD_MAC" ] && [ "$(cat "$SIGIL_BT_PREFERRED_FILE")" = "$NEW_MAC" ]
}

test_stale_marker_eliminated_by_flock() {
    setup
    add_paired "$NEW_MAC"
    : > /tmp/bt-switching.lock
    owner_request connect "$NEW_MAC"
    local rc=$OWNER_RC
    rm -f /tmp/bt-switching.lock
    [ "$rc" -eq 0 ] \
        && ! has_pattern '/tmp/bt-switching.lock|BT_SWITCH_LOCK' "$OWNER" "${ROOT}/panel"
}

test_auto_reconnect_uses_same_lock() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"; add_trusted "$OLD_MAC"
    exec 9> "$SIGIL_BT_LOCK_FILE"
    flock 9
    SIGIL_BT_RUN_ONCE=1 "$OWNER" > "${TEST_DIR}/auto.out" 2>/dev/null &
    local auto_pid=$!
    /bin/sleep 0.15
    if grep -q '^BEGIN connect' "$MOCK_BT_EVENTS"; then
        flock -u 9; wait "$auto_pid"; return 1
    fi
    flock -u 9
    wait "$auto_pid"
    grep -q "BEGIN connect $OLD_MAC" "$MOCK_BT_EVENTS"
}

test_bluez_remove_failure_reported() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"
    export MOCK_FAIL_REMOVE_MAC="$OLD_MAC"
    owner_request remove "$OLD_MAC"
    [ "$OWNER_RC" -ne 0 ] \
        && [ "$(json_field "$OWNER_OUTPUT" code)" = remove_failed ] \
        && [ "$(cat "$SIGIL_BT_PREFERRED_FILE")" = "$OLD_MAC" ]
}

test_prestart_delay_not_panel_failure() {
    setup
    grep -q '^ExecStartPre=/bin/sleep 12$' "${ROOT}/services/bt-connect.service" \
        && ! has_pattern 'systemctl.*(start|stop|restart).*bt-connect' \
            "${ROOT}/panel/app.py" "${ROOT}/panel/bluetooth.py" \
        && grep -q '^BT_OWNER_TIMEOUT_SECONDS = 100$' "${ROOT}/panel/bluetooth.py"
}

test_no_duplicate_systemctl_jobs() {
    setup
    ! has_pattern 'systemctl.*bt-connect|bt-connect.*systemctl' \
        "${ROOT}/panel/app.py" "${ROOT}/panel/bluetooth.py" \
        && ! has_pattern 'systemctl' "$OWNER"
}

test_a2dp_routes_selected_target() {
    setup
    add_paired "$NEW_MAC"
    owner_request connect "$NEW_MAC"
    # shellcheck disable=SC2016
    [ "$OWNER_RC" -eq 0 ] \
        && [ "$(tail -n 1 "$MOCK_AUDIO_LOG")" = "$NEW_MAC" ] \
        && has_pattern 'audio_route_activate_bluetooth "\$mac"' "$OWNER"
}

test_non_audio_device_rejected_before_trust() {
    setup
    add_paired "$NON_AUDIO_MAC"
    owner_request connect "$NON_AUDIO_MAC"
    [ "$OWNER_RC" -ne 0 ] \
        && [ "$(json_field "$OWNER_OUTPUT" code)" = not_audio ] \
        && ! grep -qxF "$NON_AUDIO_MAC" "${TEST_DIR}/state/trusted" \
        && ! grep -q "BEGIN connect $NON_AUDIO_MAC" "$MOCK_BT_EVENTS"
}

test_auto_recovery_leaves_unrelated_devices_unchanged() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"; add_trusted "$OLD_MAC"; add_connected "$OLD_MAC"
    add_paired "$THIRD_MAC"; add_trusted "$THIRD_MAC"; add_connected "$THIRD_MAC"
    SIGIL_BT_RUN_ONCE=1 "$OWNER" >/dev/null 2>&1
    grep -qxF "$OLD_MAC" "${TEST_DIR}/state/connected" \
        && grep -qxF "$THIRD_MAC" "${TEST_DIR}/state/connected" \
        && grep -qxF "$THIRD_MAC" "${TEST_DIR}/state/trusted" \
        && ! grep -qE "BEGIN (block|untrust|remove|disconnect) $THIRD_MAC" "$MOCK_BT_EVENTS"
}

test_explicit_switch_only_disconnects_previous_preferred() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"; add_trusted "$OLD_MAC"; add_connected "$OLD_MAC"
    add_paired "$NEW_MAC"; add_trusted "$NEW_MAC"
    owner_request connect "$NEW_MAC"
    [ "$OWNER_RC" -eq 0 ] \
        && ! grep -qxF "$OLD_MAC" "${TEST_DIR}/state/connected" \
        && grep -qxF "$OLD_MAC" "${TEST_DIR}/state/trusted" \
        && ! grep -qE "BEGIN (block|untrust|remove) $OLD_MAC" "$MOCK_BT_EVENTS" \
        && [ "$(cat "$SIGIL_BT_PREFERRED_FILE")" = "$NEW_MAC" ]
}

test_destructive_cleanup_is_explicit_remove_only() {
    setup
    set_preferred "$OLD_MAC"
    add_paired "$OLD_MAC"; add_trusted "$OLD_MAC"; add_connected "$OLD_MAC"
    owner_request remove "$OLD_MAC"
    [ "$OWNER_RC" -eq 0 ] \
        && grep -q "BEGIN untrust $OLD_MAC" "$MOCK_BT_EVENTS" \
        && grep -q "BEGIN remove $OLD_MAC" "$MOCK_BT_EVENTS" \
        && [ -z "$(cat "$SIGIL_BT_PREFERRED_FILE")" ]
}

test_no_real_macs_or_panel_policy() {
    setup
    ! grep -Eo '([0-9A-F]{2}:){5}[0-9A-F]{2}' "$0" \
        | grep -qv '^02:00:00:00:00:0[1-4]$' \
        && ! has_pattern '_disconnect_all_except|set_a2dp_profile|save_preferred_device' \
            "${ROOT}/panel/bluetooth.py"
}

run_test "pair and automatic reconnect cannot overlap" test_pair_and_auto_reconnect_serialized
run_test "connect and remove cannot overlap" test_connect_and_remove_serialized
run_test "preferred MAC is normalized and atomically written" test_preferred_normalized_atomic_private
run_test "preferred state never follows symlinks" test_preferred_symlink_never_followed
run_test "failed connection preserves old preferred" test_failed_target_preserves_old_preferred
run_test "successful connection persists only after completion" test_success_updates_only_after_completion
run_test "stale marker is eliminated in favor of flock" test_stale_marker_eliminated_by_flock
run_test "automatic reconnect respects canonical flock" test_auto_reconnect_uses_same_lock
run_test "BlueZ removal failure is reported" test_bluez_remove_failure_reported
run_test "12-second pre-start cannot create panel failure" test_prestart_delay_not_panel_failure
run_test "no duplicate systemctl jobs occur" test_no_duplicate_systemctl_jobs
run_test "A2DP routing receives selected target" test_a2dp_routes_selected_target
run_test "non-audio metadata is rejected before trust" test_non_audio_device_rejected_before_trust
run_test "automatic recovery leaves unrelated devices unchanged" test_auto_recovery_leaves_unrelated_devices_unchanged
run_test "explicit switch disconnects but preserves previous trust" test_explicit_switch_only_disconnects_previous_preferred
run_test "destructive cleanup occurs only for explicit remove" test_destructive_cleanup_is_explicit_remove_only
run_test "fixtures use only synthetic MACs and panel has no policy" test_no_real_macs_or_panel_policy

printf '\nBluetooth coordination: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf 'Failed tests:\n'
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
