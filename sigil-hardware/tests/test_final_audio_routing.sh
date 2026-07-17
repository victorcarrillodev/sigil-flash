#!/bin/bash
# Behavioral tests for canonical production audio-route detection.
# Runtime-computed source paths and globals consumed by sourced production
# functions are intentional in this behavioral harness.
# shellcheck disable=SC1091,SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TEST_ROOT=$(mktemp -d /tmp/sigil-audio-routing.XXXXXX)
MOCK_BIN="${TEST_ROOT}/bin"
MOCK_STATE="${TEST_ROOT}/state"
PASS=0
FAIL=0
FAKE_MAC="AA:BB:CC:DD:EE:01"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$MOCK_BIN" "$MOCK_STATE"

cat > "${MOCK_BIN}/pactl" <<'EOF'
#!/bin/bash
printf '%s|user=%s|xdg=%s|server=%s|runtime=%s|home=%s\n' \
    "$*" "${MOCK_EFFECTIVE_USER:-caller}" "${XDG_RUNTIME_DIR:-}" \
    "${PULSE_SERVER:-}" "${PULSE_RUNTIME_PATH:-}" "${HOME:-}" \
    >> "$MOCK_STATE/pactl_invocations"
case "${1:-} ${2:-} ${3:-}" in
    "list cards "*) cat "$MOCK_STATE/cards" ;;
    "list sinks short") cat "$MOCK_STATE/sinks_short" ;;
    "list sinks "*) cat "$MOCK_STATE/sinks" ;;
    "set-card-profile "*|"set-default-sink "*)
        printf '%s\n' "$*" >> "$MOCK_STATE/pactl_calls"
        exit "${PACTL_SET_RC:-0}"
        ;;
    *) exit 1 ;;
esac
EOF
cat > "${MOCK_BIN}/bluetoothctl" <<'EOF'
#!/bin/bash
case "${1:-}" in
    info) cat "$MOCK_STATE/bt_info" ;;
    devices) cat "$MOCK_STATE/bt_devices" ;;
    *) exit 1 ;;
esac
EOF
cat > "${MOCK_BIN}/aplay" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] || exit 1
cat "$MOCK_STATE/aplay"
EOF
cat > "${MOCK_BIN}/paplay" <<'EOF'
#!/bin/bash
cat >/dev/null
printf '%s\n' "$*" >> "$MOCK_STATE/paplay_calls"
printf '%s|user=%s|xdg=%s|server=%s|runtime=%s|home=%s\n' \
    "$*" "${MOCK_EFFECTIVE_USER:-caller}" "${XDG_RUNTIME_DIR:-}" \
    "${PULSE_SERVER:-}" "${PULSE_RUNTIME_PATH:-}" "${HOME:-}" \
    >> "$MOCK_STATE/paplay_invocations"
exit "${PAPLAY_RC:-0}"
EOF
cat > "${MOCK_BIN}/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "sigil" ]; then
    printf '%s\n' "${MOCK_SIGIL_UID:-1234}"
elif [ "${1:-}" = "-u" ] && [ "$#" -eq 1 ]; then
    printf '%s\n' "${MOCK_CALLER_UID:-1000}"
else
    /usr/bin/id "$@"
fi
EOF
cat > "${MOCK_BIN}/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/sudo_calls"
target_user=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -H) shift ;;
        -u)
            target_user="${2:-}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *) break ;;
    esac
done
[ "$target_user" = "sigil" ] || exit 97
env MOCK_EFFECTIVE_USER=sigil "$@"
EOF
cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/timeout_calls"
[ "${1:-}" = "3" ] || exit 96
shift
"$@"
EOF
cat > "${MOCK_BIN}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "$MOCK_STATE/sleep_calls"
EOF
cat > "${MOCK_BIN}/mpg123" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/mpg123_calls"
EOF
cat > "${MOCK_BIN}/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_STATE/curl_calls"
exit "${CURL_RC:-0}"
EOF
chmod +x "${MOCK_BIN}"/*

export MOCK_STATE PATH="${MOCK_BIN}:${PATH}"
export MOCK_CALLER_UID=1000 MOCK_SIGIL_UID=1234
export SIGIL_AUDIO_PREFERRED_FILE="${MOCK_STATE}/preferred"
export SIGIL_ASOUND_CARDS_FILE="${MOCK_STATE}/asound_cards"
export SIGIL_AUDIO_ROUTE_HELPER="${ROOT}/scripts/sigil-audio-route.sh"
export SIGIL_PLAYBACK_STATE_FILE="${MOCK_STATE}/playback_state.json"

# shellcheck source=../scripts/sigil-audio-route.sh
source "${ROOT}/scripts/sigil-audio-route.sh"
# shellcheck source=../scripts/sigil-audio-capability.sh
source "${ROOT}/scripts/sigil-audio-capability.sh"

reset_fixture() {
    : > "${MOCK_STATE}/cards"
    : > "${MOCK_STATE}/sinks_short"
    : > "${MOCK_STATE}/sinks"
    : > "${MOCK_STATE}/bt_info"
    : > "${MOCK_STATE}/bt_devices"
    : > "${MOCK_STATE}/aplay"
    : > "${MOCK_STATE}/asound_cards"
    : > "${MOCK_STATE}/preferred"
    : > "${MOCK_STATE}/pactl_calls"
    : > "${MOCK_STATE}/pactl_invocations"
    : > "${MOCK_STATE}/paplay_calls"
    : > "${MOCK_STATE}/paplay_invocations"
    : > "${MOCK_STATE}/sudo_calls"
    : > "${MOCK_STATE}/timeout_calls"
    : > "${MOCK_STATE}/sleep_calls"
    : > "${MOCK_STATE}/curl_calls"
    rm -f "${MOCK_STATE}/mpg123_calls"
    printf '%s\n' '{}' > "$SIGIL_PLAYBACK_STATE_FILE"
    PAPLAY_RC=0
    export PAPLAY_RC
    MOCK_CALLER_UID=1000
    MOCK_SIGIL_UID=1234
    export MOCK_CALLER_UID MOCK_SIGIL_UID
    unset SIGIL_I2S_DAC_PRESENT
    CURL_RC=0
    export CURL_RC
}

set_bluetooth_fixture() {
    local state="${1:-IDLE}"
    local connected="${2:-yes}"
    printf '%s\n' "$FAKE_MAC" > "${MOCK_STATE}/preferred"
    cat > "${MOCK_STATE}/bt_info" <<EOF
Device ${FAKE_MAC}
    Connected: ${connected}
    Trusted: yes
EOF
    if [ "$connected" = "yes" ]; then
        printf 'Device %s Test Speaker\n' "$FAKE_MAC" > "${MOCK_STATE}/bt_devices"
    fi
    cat > "${MOCK_STATE}/cards" <<EOF
Card #1
    Name: bluez_card.AA_BB_CC_DD_EE_01
    Profiles:
        a2dp_sink: High Fidelity Playback (available: yes)
    Active Profile: a2dp_sink
EOF
    cat > "${MOCK_STATE}/sinks_short" <<EOF
1 bluez_sink.AA_BB_CC_DD_EE_01.a2dp_sink module-bluez5-device.c s16le 2ch 48000Hz ${state}
EOF
    cat > "${MOCK_STATE}/sinks" <<EOF
Sink #1
    State: ${state}
    Name: bluez_sink.AA_BB_CC_DD_EE_01.a2dp_sink
    Ports:
        headset-output: Bluetooth Output (available: yes)
    Active Port: headset-output
EOF
}

set_i2s_fixture() {
    cat > "${MOCK_STATE}/aplay" <<'EOF'
card 0: sndrpihifiberry [snd_rpi_hifiberry_dac], device 0: HifiBerry DAC HiFi pcm5102a-hifi-0
EOF
    cp "${MOCK_STATE}/aplay" "${MOCK_STATE}/asound_cards"
    cat > "${MOCK_STATE}/sinks_short" <<'EOF'
0 alsa_output.platform-soc_sound.stereo-fallback module-alsa-card.c s16le 2ch 48000Hz SUSPENDED
EOF
    cat > "${MOCK_STATE}/sinks" <<'EOF'
Sink #0
    State: SUSPENDED
    Name: alsa_output.platform-soc_sound.stereo-fallback
    Ports:
        analog-output: PCM5102A Output (available: yes)
    Active Port: analog-output
EOF
}

run_test() {
    local name="$1" fn="$2"
    if ( reset_fixture; "$fn" ); then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$name"
    fi
}

test_bluetooth_connected() {
    set_i2s_fixture
    SIGIL_I2S_DAC_PRESENT=1
    set_bluetooth_fixture IDLE yes
    select_audio_route
    [ "$AUDIO_ROUTE_TYPE" = bluetooth ] \
        && [ "$AUDIO_ROUTE_SINK" = bluez_sink.AA_BB_CC_DD_EE_01.a2dp_sink ]
}

test_bluetooth_suspended() {
    set_bluetooth_fixture SUSPENDED yes
    select_audio_route
    [ "$AUDIO_ROUTE_TYPE" = bluetooth ] && [ "$AUDIO_ROUTE_SINK" = bluez_sink.AA_BB_CC_DD_EE_01.a2dp_sink ]
}

test_stale_bluetooth_rejected() {
    set_bluetooth_fixture SUSPENDED no
    ! select_audio_route && [ -z "$AUDIO_ROUTE_SINK" ]
}

test_i2s_selected() {
    set_i2s_fixture
    SIGIL_I2S_DAC_PRESENT=1
    select_audio_route
    [ "$AUDIO_ROUTE_TYPE" = i2s ] \
        && [ "$AUDIO_ROUTE_SINK" = alsa_output.platform-soc_sound.stereo-fallback ]
}

test_i2s_open_failure() {
    set_i2s_fixture
    SIGIL_I2S_DAC_PRESENT=1
    PAPLAY_RC=1
    export PAPLAY_RC
    ! select_audio_route
}

test_i2s_explicitly_absent() {
    set_i2s_fixture
    SIGIL_I2S_DAC_PRESENT=0
    ! select_audio_route \
        && [ -z "$AUDIO_ROUTE_SINK" ] \
        && [ ! -s "${MOCK_STATE}/paplay_calls" ]
}

test_i2s_setting_absent() {
    set_i2s_fixture
    unset SIGIL_I2S_DAC_PRESENT
    ! select_audio_route && [ ! -s "${MOCK_STATE}/paplay_calls" ]
}

test_i2s_setting_invalid() {
    set_i2s_fixture
    SIGIL_I2S_DAC_PRESENT=auto
    ! select_audio_route && [ ! -s "${MOCK_STATE}/paplay_calls" ]
}

test_silent_probe_never_declares_hardware() {
    set_i2s_fixture
    PAPLAY_RC=0
    unset SIGIL_I2S_DAC_PRESENT
    ! select_audio_route && [ ! -s "${MOCK_STATE}/paplay_calls" ]
}

test_no_output_player_stops_cleanly() {
    # shellcheck source=../scripts/audio-player.sh
    source "${ROOT}/scripts/audio-player.sh"
    LOG="${MOCK_STATE}/player.log"
    MPG123_PID=""
    ! audio_output_gate
    ! audio_output_gate
    [ "$NO_AUDIO_OUTPUT_ACTIVE" = true ] \
        && [ ! -e "${MOCK_STATE}/mpg123_calls" ] \
        && [ "$(grep -c 'no_audio_output — Bluetooth' "$LOG")" -eq 1 ]
}

test_output_appears_and_player_resumes() {
    # shellcheck source=../scripts/audio-player.sh
    source "${ROOT}/scripts/audio-player.sh"
    LOG="${MOCK_STATE}/player.log"
    ! audio_output_gate
    set_bluetooth_fixture IDLE yes
    audio_output_gate
    [ "$NO_AUDIO_OUTPUT_ACTIVE" = false ] \
        && [ "$SINK" = bluez_sink.AA_BB_CC_DD_EE_01.a2dp_sink ]
}

test_route_probe_does_not_duplicate_player() {
    # shellcheck source=../scripts/audio-player.sh
    source "${ROOT}/scripts/audio-player.sh"
    LOG="${MOCK_STATE}/player.log"
    set_i2s_fixture
    SIGIL_I2S_DAC_PRESENT=1
    MPG123_PID=424242
    audio_output_gate
    [ "$MPG123_PID" = 424242 ] && [ ! -e "${MOCK_STATE}/mpg123_calls" ]
}

test_installer_enables_declared_i2s() {
    local provision="${MOCK_STATE}/provision-true.json"
    local boot_config="${MOCK_STATE}/config-true.txt"
    local audio_config="${MOCK_STATE}/audio-true.conf"
    cat > "$provision" <<'EOF'
{"_schema_version":"1.0","serial_number":"S1","model":"Custom","batch":"B","capabilities":{"i2s_dac":true}}
EOF
    printf '%s\n' 'dtparam=audio=on' > "$boot_config"
    printf '%s\n' 'SIGIL_I2S_DAC_PRESENT=0' > "$audio_config"
    local capability
    capability=$(sigil_resolve_i2s_capability "$provision" "$audio_config")
    sigil_configure_i2s_overlay "$boot_config" "$capability"
    sigil_write_i2s_capability "$audio_config" "$capability"
    [ "$capability" = 1 ] \
        && grep -qxF 'dtoverlay=hifiberry-dac' "$boot_config" \
        && grep -qxF 'dtparam=audio=off' "$boot_config" \
        && grep -qxF 'SIGIL_I2S_DAC_PRESENT=1' "$audio_config"
}

test_installer_disables_undeclared_i2s() {
    local provision="${MOCK_STATE}/provision-false.json"
    local boot_config="${MOCK_STATE}/config-false.txt"
    local audio_config="${MOCK_STATE}/audio-false.conf"
    cat > "$provision" <<'EOF'
{"_schema_version":"1.0","serial_number":"S2","model":"Custom","batch":"B","capabilities":{"i2s_dac":false}}
EOF
    printf '%s\n' 'dtoverlay=hifiberry-dac' > "$boot_config"
    printf '%s\n' 'SIGIL_I2S_DAC_PRESENT=1' > "$audio_config"
    local capability
    capability=$(sigil_resolve_i2s_capability "$provision" "$audio_config")
    sigil_configure_i2s_overlay "$boot_config" "$capability"
    sigil_write_i2s_capability "$audio_config" "$capability"
    [ "$capability" = 0 ] \
        && ! grep -q '^dtoverlay=hifiberry-dac$' "$boot_config" \
        && grep -qxF 'SIGIL_I2S_DAC_PRESENT=0' "$audio_config"
}

test_installer_legacy_model_mapping() {
    local provision="${MOCK_STATE}/provision-legacy.json"
    cat > "$provision" <<'EOF'
{"_schema_version":"1.0","serial_number":"S3","model":"Sigil-Streamer-v1","batch":"B"}
EOF
    [ "$(sigil_resolve_i2s_capability "$provision" /nonexistent)" = 1 ]
}

test_installer_preserves_explicit_existing_capability() {
    local audio_config="${MOCK_STATE}/audio-existing.conf"
    printf '%s\n' 'SIGIL_I2S_DAC_PRESENT=1' > "$audio_config"
    [ "$(sigil_resolve_i2s_capability "" "$audio_config")" = 1 ]
}

test_installer_rejects_invalid_capability() {
    local provision="${MOCK_STATE}/provision-invalid.json"
    cat > "$provision" <<'EOF'
{"_schema_version":"1.0","serial_number":"S4","model":"Custom","batch":"B","capabilities":{"i2s_dac":"auto"}}
EOF
    ! sigil_resolve_i2s_capability "$provision" /nonexistent >/dev/null 2>&1
}

test_manager_persists_no_output_reason() {
    # shellcheck source=../scripts/audio-manager.sh
    source "${ROOT}/scripts/audio-manager.sh"
    LOG="${MOCK_STATE}/manager.log"
    DRY_RUN=true
    LEGACY_ACTIVE=false
    SINK_AVAILABLE=false
    PLAYBACK_MODE=radio-first
    CURRENT_MODE=BLOCKED_NO_SINK
    CURRENT_DESIRED=RADIO
    CURRENT_REASON=no_sink
    evaluate_state
    [ "$CURRENT_MODE" = BLOCKED_NO_SINK ] \
        && [ "$CURRENT_REASON" = no_audio_output ] \
        && [[ "$LAST_ERROR" == no_audio_output:* ]]
}

test_manager_consumes_player_output_without_routing() {
    # shellcheck source=../scripts/audio-manager.sh
    source "${ROOT}/scripts/audio-manager.sh"
    LOG="${MOCK_STATE}/manager.log"
    cat > "$PLAYBACK_STATE_FILE" <<'EOF'
{"output":{"available":true,"type":"i2s","sink":"test_i2s_sink","reason":"i2s_selected"}}
EOF
    check_sink
    [ "$SINK_AVAILABLE" = true ] \
        && [ "$AUDIO_OUTPUT_TYPE" = i2s ] \
        && [ "$AUDIO_OUTPUT_SINK" = test_i2s_sink ] \
        && [ ! -s "${MOCK_STATE}/pactl_calls" ] \
        && [ ! -s "${MOCK_STATE}/paplay_calls" ]
}

test_manager_tolerates_unreachable_server() {
    # shellcheck source=../scripts/audio-manager.sh
    source "${ROOT}/scripts/audio-manager.sh"
    LOG="${MOCK_STATE}/manager.log"
    SERVER_URL="https://offline.invalid"
    CURL_CONFIG=""
    LAST_INTERNET_CHECK_EPOCH=0
    INTERNET_AVAILABLE=true
    CURL_RC=7
    export CURL_RC

    check_internet

    [ "$INTERNET_AVAILABLE" = false ] \
        && [ "$(wc -l < "${MOCK_STATE}/curl_calls")" -eq 1 ] \
        && grep -q 'Internet lost' "$LOG"
}

test_root_uses_sigil_pulse_session() {
    MOCK_CALLER_UID=0
    export MOCK_CALLER_UID
    HOME=/root
    XDG_RUNTIME_DIR=/run/user/0
    PULSE_SERVER=unix:/run/user/0/pulse/native
    PULSE_RUNTIME_PATH=/run/user/0/pulse
    export HOME XDG_RUNTIME_DIR PULSE_SERVER PULSE_RUNTIME_PATH
    set_bluetooth_fixture IDLE yes

    select_audio_route || return 1
    [ "$AUDIO_ROUTE_TYPE" = bluetooth ] || return 1
    [ -s "${MOCK_STATE}/sudo_calls" ] || return 1
    [ -s "${MOCK_STATE}/pactl_invocations" ] || return 1
    [ -s "${MOCK_STATE}/paplay_invocations" ] || return 1
    grep -q -- '-u sigil .*env .*HOME=/home/sigil .*XDG_RUNTIME_DIR=/run/user/1234' \
        "${MOCK_STATE}/sudo_calls" || return 1

    awk -F'|' '
        $2 != "user=sigil" ||
        $3 != "xdg=/run/user/1234" ||
        $4 != "server=unix:/run/user/1234/pulse/native" ||
        $5 != "runtime=/run/user/1234/pulse" ||
        $6 != "home=/home/sigil" { bad=1 }
        END { exit NR == 0 || bad }
    ' "${MOCK_STATE}/pactl_invocations" || return 1
    awk -F'|' '
        $2 != "user=sigil" ||
        $3 != "xdg=/run/user/1234" ||
        $4 != "server=unix:/run/user/1234/pulse/native" ||
        $5 != "runtime=/run/user/1234/pulse" ||
        $6 != "home=/home/sigil" { bad=1 }
        END { exit NR == 0 || bad }
    ' "${MOCK_STATE}/paplay_invocations"
}

test_root_silent_probe_keeps_timeout() {
    MOCK_CALLER_UID=0
    export MOCK_CALLER_UID
    HOME=/root
    XDG_RUNTIME_DIR=/run/user/0
    PULSE_SERVER=unix:/run/user/0/pulse/native
    PULSE_RUNTIME_PATH=/run/user/0/pulse
    export HOME XDG_RUNTIME_DIR PULSE_SERVER PULSE_RUNTIME_PATH
    set_bluetooth_fixture SUSPENDED yes

    select_audio_route || return 1
    [ "$(wc -l < "${MOCK_STATE}/timeout_calls")" -eq 1 ] || return 1
    grep -q '^3 .*paplay .*--raw .*--device=bluez_sink\.AA_BB_CC_DD_EE_01\.a2dp_sink' \
        "${MOCK_STATE}/timeout_calls" || return 1
    [ "$(wc -l < "${MOCK_STATE}/paplay_invocations")" -eq 1 ]
}

test_non_root_does_not_use_sudo() {
    MOCK_CALLER_UID=1000
    export MOCK_CALLER_UID
    HOME=/home/sigil
    XDG_RUNTIME_DIR=/run/user/1234
    PULSE_SERVER=unix:/run/user/1234/pulse/native
    PULSE_RUNTIME_PATH=/run/user/1234/pulse
    export HOME XDG_RUNTIME_DIR PULSE_SERVER PULSE_RUNTIME_PATH
    set_bluetooth_fixture IDLE yes

    select_audio_route || return 1
    [ "$AUDIO_ROUTE_TYPE" = bluetooth ] \
        && [ ! -s "${MOCK_STATE}/sudo_calls" ] \
        && grep -q '|user=caller|' "${MOCK_STATE}/pactl_invocations" \
        && grep -q '|user=caller|' "${MOCK_STATE}/paplay_invocations"
}

test_audio_manager_unit_runs_as_sigil() {
    grep -qxF 'User=sigil' "${ROOT}/services/audio-manager.service" \
        && grep -qxF 'Group=sigil' "${ROOT}/services/audio-manager.service"
}

run_test "Bluetooth connected with A2DP is selected" test_bluetooth_connected
run_test "Bluetooth SUSPENDED sink remains eligible" test_bluetooth_suspended
run_test "stale Bluetooth sink with Connected=no is rejected" test_stale_bluetooth_rejected
run_test "usable PCM5102A I2S output is selected" test_i2s_selected
run_test "I2S sink that rejects silent write is rejected" test_i2s_open_failure
run_test "I2S sink is rejected when capability is 0" test_i2s_explicitly_absent
run_test "I2S sink is rejected when capability is absent" test_i2s_setting_absent
run_test "I2S sink is rejected when capability is invalid" test_i2s_setting_invalid
run_test "silent probe success never declares I2S hardware" test_silent_probe_never_declares_hardware
run_test "no output keeps player stopped with bounded diagnostic" test_no_output_player_stops_cleanly
run_test "player recovers when Bluetooth later connects" test_output_appears_and_player_resumes
run_test "route changes do not duplicate an existing player" test_route_probe_does_not_duplicate_player
run_test "manager persists no_audio_output runtime reason" test_manager_persists_no_output_reason
run_test "manager consumes player output without activating a route" test_manager_consumes_player_output_without_routing
run_test "audio-manager remains alive when the server is unreachable" test_manager_tolerates_unreachable_server
run_test "root routes pactl and paplay through the sigil PulseAudio session" test_root_uses_sigil_pulse_session
run_test "root silent probe retains the three-second timeout" test_root_silent_probe_keeps_timeout
run_test "non-root audio routing never invokes sudo" test_non_root_does_not_use_sudo
run_test "audio-manager systemd unit runs as sigil" test_audio_manager_unit_runs_as_sigil
run_test "installer enables overlay only for declared I2S" test_installer_enables_declared_i2s
run_test "installer removes overlay for explicitly absent I2S" test_installer_disables_undeclared_i2s
run_test "installer preserves confirmed legacy DAC model mapping" test_installer_legacy_model_mapping
run_test "installer preserves explicit capability on confirmed deployed DAC" test_installer_preserves_explicit_existing_capability
run_test "installer rejects invalid I2S capability" test_installer_rejects_invalid_capability

printf '\nAudio routing: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
