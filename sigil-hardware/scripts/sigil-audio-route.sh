#!/bin/bash
# Canonical SIGIL audio-output discovery and readiness checks.
# Source this file and call select_audio_route. It sets:
#   AUDIO_ROUTE_TYPE, AUDIO_ROUTE_SINK, AUDIO_ROUTE_DEVICE, AUDIO_ROUTE_REASON
# When executed directly, `select` prints those fields separated by tabs.

AUDIO_ROUTE_PREFERRED_FILE="${SIGIL_AUDIO_PREFERRED_FILE:-/home/sigil/preferred_bt.txt}"
AUDIO_ROUTE_ASOUND_CARDS="${SIGIL_ASOUND_CARDS_FILE:-/proc/asound/cards}"
AUDIO_ROUTE_TYPE=""
AUDIO_ROUTE_SINK=""
AUDIO_ROUTE_DEVICE=""
AUDIO_ROUTE_REASON="no_audio_output"

_audio_route_run_as_sigil() {
    local executable="$1"
    shift

    if [ "$(id -u)" -eq 0 ]; then
        local sigil_uid
        sigil_uid=$(id -u sigil 2>/dev/null) || return 1
        sudo -H -u sigil -- env \
            HOME=/home/sigil \
            XDG_RUNTIME_DIR="/run/user/${sigil_uid}" \
            PULSE_SERVER="unix:/run/user/${sigil_uid}/pulse/native" \
            PULSE_RUNTIME_PATH="/run/user/${sigil_uid}/pulse" \
            "$executable" "$@"
    else
        "$executable" "$@"
    fi
}

_pactl() {
    _audio_route_run_as_sigil pactl "$@"
}

_paplay() {
    # Keep timeout inside the wrapper. GNU timeout can execute paplay, but it
    # cannot execute this Bash function by name.
    _audio_route_run_as_sigil timeout 3 paplay "$@"
}

_audio_route_mac_is_valid() {
    [[ "${1:-}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

_audio_route_card_block() {
    local card_name="$1"
    _pactl list cards 2>/dev/null | awk -v wanted="$card_name" '
        /^Card #[0-9]+/ {
            if (started && matched) { printf "%s", block; done=1; exit }
            block=$0 ORS; matched=0; started=1; next
        }
        started {
            block=block $0 ORS
            if ($1 == "Name:" && $2 == wanted) matched=1
        }
        END { if (!done && matched) printf "%s", block }
    '
}

_audio_route_sink_block() {
    local sink_name="$1"
    _pactl list sinks 2>/dev/null | awk -v wanted="$sink_name" '
        /^Sink #[0-9]+/ {
            if (started && matched) { printf "%s", block; done=1; exit }
            block=$0 ORS; matched=0; started=1; next
        }
        started {
            block=block $0 ORS
            if ($1 == "Name:" && $2 == wanted) matched=1
        }
        END { if (!done && matched) printf "%s", block }
    '
}

_audio_route_sink_available() {
    local sink_name="$1"
    local block active_port port_line
    block=$(_audio_route_sink_block "$sink_name")
    [ -n "$block" ] || return 1

    # IDLE and SUSPENDED are intentionally accepted. Only an explicitly
    # unavailable active port/sink is rejected.
    if printf '%s\n' "$block" | grep -qiE '^[[:space:]]*Availability:[[:space:]]*no'; then
        return 1
    fi
    active_port=$(printf '%s\n' "$block" | awk -F': ' '/^[[:space:]]*Active Port:/ {print $2; exit}')
    if [ -n "$active_port" ]; then
        port_line=$(printf '%s\n' "$block" | grep -F "${active_port}:" | head -1 || true)
        if printf '%s\n' "$port_line" | grep -qi 'available: no'; then
            return 1
        fi
    fi
    return 0
}

_audio_route_silent_probe() {
    local sink_name="$1"
    command -v paplay >/dev/null 2>&1 || return 1
    # One stereo S16_LE frame of digital silence. This wakes a suspended sink
    # without producing an audible sample and proves PulseAudio accepts writes.
    head -c 4 /dev/zero \
        | _paplay --raw --device="$sink_name" --rate=48000 \
            --channels=2 --format=s16le >/dev/null 2>&1
}

_audio_route_connected_trusted() {
    local mac="$1"
    local info
    info=$(bluetoothctl info "$mac" 2>/dev/null) || return 1
    printf '%s\n' "$info" | grep -qiE '^[[:space:]]*Connected:[[:space:]]*yes$' || return 1
    printf '%s\n' "$info" | grep -qiE '^[[:space:]]*Trusted:[[:space:]]*yes$'
}

_audio_route_a2dp_profile() {
    local card_block="$1"
    printf '%s\n' "$card_block" | awk '
        /^[[:space:]]+a2dp[^:]*:/ && tolower($0) !~ /available:[[:space:]]*no/ {
            name=$1; sub(/:$/, "", name); print name; exit
        }
    '
}

audio_route_activate_bluetooth() {
    local mac="${1:-}"
    _audio_route_mac_is_valid "$mac" || return 1
    _audio_route_connected_trusted "$mac" || return 1

    local normalized card card_block profile active_profile sink
    normalized=$(printf '%s' "$mac" | tr '[:lower:]:' '[:upper:]_')
    card="bluez_card.${normalized}"
    card_block=$(_audio_route_card_block "$card")
    [ -n "$card_block" ] || return 1
    profile=$(_audio_route_a2dp_profile "$card_block")
    [ -n "$profile" ] || return 1
    active_profile=$(printf '%s\n' "$card_block" | awk -F': ' '/^[[:space:]]*Active Profile:/ {print $2; exit}')
    if [[ "$active_profile" != *a2dp* ]]; then
        _pactl set-card-profile "$card" "$profile" >/dev/null 2>&1 || return 1
    fi

    sink=$(_pactl list sinks short 2>/dev/null \
        | awk -v marker="bluez_sink.${normalized}" '$2 ~ marker && tolower($2) ~ /a2dp/ {print $2; exit}')
    [ -n "$sink" ] || return 1
    _audio_route_sink_available "$sink" || return 1
    _pactl set-default-sink "$sink" >/dev/null 2>&1 || return 1
    _audio_route_silent_probe "$sink" || return 1

    AUDIO_ROUTE_TYPE="bluetooth"
    AUDIO_ROUTE_SINK="$sink"
    AUDIO_ROUTE_DEVICE="$mac"
    AUDIO_ROUTE_REASON="bluetooth_connected_a2dp"
    return 0
}

_audio_route_bluetooth_candidates() {
    local preferred=""
    if [ -r "$AUDIO_ROUTE_PREFERRED_FILE" ]; then
        preferred=$(tr -d '[:space:]' < "$AUDIO_ROUTE_PREFERRED_FILE")
        if _audio_route_mac_is_valid "$preferred"; then
            printf '%s\n' "${preferred^^}"
        fi
    fi
    bluetoothctl devices Connected 2>/dev/null \
        | awk '$1 == "Device" {print toupper($2)}' \
        | awk '!seen[$0]++'
}

_audio_route_i2s_alsa_device() {
    local cards_output
    cards_output=$(aplay -l 2>/dev/null) || return 1
    printf '%s\n' "$cards_output" | awk '
        /^card [0-9]+:/ && tolower($0) ~ /snd_rpi_hifiberry_dac|hifiberry|pcm5102|soc[-_ ]sound/ {
            card=$2; sub(/:$/, "", card)
            device=0
            if (match($0, /device [0-9]+/)) {
                value=substr($0, RSTART, RLENGTH); sub(/device /, "", value); device=value
            }
            print card ":" device; exit
        }
    '
}

_audio_route_i2s_driver_present() {
    if [ -r "$AUDIO_ROUTE_ASOUND_CARDS" ] \
        && grep -qiE 'snd_rpi_hifiberry_dac|hifiberry|pcm5102|soc[-_ ]sound' "$AUDIO_ROUTE_ASOUND_CARDS"; then
        return 0
    fi
    aplay -l 2>/dev/null | grep -qiE 'snd_rpi_hifiberry_dac|hifiberry|pcm5102|soc[-_ ]sound'
}

_audio_route_i2s_declared() {
    [ "${SIGIL_I2S_DAC_PRESENT:-}" = "1" ]
}

audio_route_activate_i2s() {
    # Capability is authoritative. Kernel/card/sink presence can only prove
    # software readiness after hardware has been declared by provisioning.
    _audio_route_i2s_declared || return 1
    _audio_route_i2s_driver_present || return 1
    local alsa_device sink
    alsa_device=$(_audio_route_i2s_alsa_device)
    [ -n "$alsa_device" ] || return 1
    sink=$(_pactl list sinks short 2>/dev/null | awk '
        tolower($2) ~ /platform-soc_sound|hifiberry|pcm5102|soc[-_]sound/ {print $2; exit}
    ')
    [ -n "$sink" ] || return 1
    _audio_route_sink_available "$sink" || return 1
    _pactl set-default-sink "$sink" >/dev/null 2>&1 || return 1
    _audio_route_silent_probe "$sink" || return 1

    AUDIO_ROUTE_TYPE="i2s"
    AUDIO_ROUTE_SINK="$sink"
    AUDIO_ROUTE_DEVICE="plughw:${alsa_device/:/,}"
    AUDIO_ROUTE_REASON="pcm5102a_ready"
    return 0
}

select_audio_route() {
    AUDIO_ROUTE_TYPE=""
    AUDIO_ROUTE_SINK=""
    AUDIO_ROUTE_DEVICE=""
    AUDIO_ROUTE_REASON="no_audio_output"

    local candidate
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if audio_route_activate_bluetooth "$candidate"; then
            return 0
        fi
    done < <(_audio_route_bluetooth_candidates)

    if audio_route_activate_i2s; then
        return 0
    fi
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-select}" in
        select)
            if select_audio_route; then
                printf '%s\t%s\t%s\t%s\n' \
                    "$AUDIO_ROUTE_TYPE" "$AUDIO_ROUTE_SINK" "$AUDIO_ROUTE_DEVICE" "$AUDIO_ROUTE_REASON"
            else
                printf 'none\t\t\t%s\n' "$AUDIO_ROUTE_REASON"
                exit 1
            fi
            ;;
        *)
            printf 'usage: %s [select]\n' "$0" >&2
            exit 2
            ;;
    esac
fi
