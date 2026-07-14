#!/bin/bash
# Canonical provisioning helpers for the explicit SIGIL I2S DAC capability.
# This file is sourced by install.sh and by focused behavioral tests.

sigil_model_has_i2s_dac() {
    case "${1:-}" in
        # Backward-compatible legacy model confirmed to ship with PCM5102A.
        Sigil-Streamer-v1) return 0 ;;
        *) return 1 ;;
    esac
}

sigil_provision_i2s_value() {
    local provision_file="$1"
    python3 - "$provision_file" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
capabilities = document.get("capabilities", {})
if capabilities is None:
    capabilities = {}
if not isinstance(capabilities, dict):
    raise SystemExit("capabilities must be an object")
value = capabilities.get("i2s_dac")
if value is True:
    print("1")
elif value is False:
    print("0")
elif value is None:
    print("unset")
else:
    raise SystemExit("capabilities.i2s_dac must be boolean")
PYEOF
}

sigil_provision_model() {
    local provision_file="$1"
    python3 - "$provision_file" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
model = document.get("model", "")
if not isinstance(model, str) or "\n" in model or "\r" in model:
    raise SystemExit("model must be a single-line string")
print(model)
PYEOF
}

sigil_audio_conf_i2s_value() {
    local audio_conf="$1"
    if [ ! -f "$audio_conf" ]; then
        printf 'unset\n'
        return 0
    fi
    local value
    value=$(awk -F= '
        /^[[:space:]]*SIGIL_I2S_DAC_PRESENT[[:space:]]*=/ {
            value=$2
            gsub(/[[:space:]"\047]/, "", value)
        }
        END { print value }
    ' "$audio_conf")
    case "$value" in
        0|1) printf '%s\n' "$value" ;;
        '') printf 'unset\n' ;;
        *) printf 'invalid\n' ;;
    esac
}

sigil_resolve_i2s_capability() {
    local provision_file="${1:-}"
    local existing_audio_conf="${2:-}"
    local provision_value="unset" model="" configured_value

    if [ -n "$provision_file" ]; then
        [ -f "$provision_file" ] || {
            printf 'provision file not found: %s\n' "$provision_file" >&2
            return 1
        }
        provision_value=$(sigil_provision_i2s_value "$provision_file") || return 1
        case "$provision_value" in
            0|1) printf '%s\n' "$provision_value"; return 0 ;;
            unset) ;;
            *) return 1 ;;
        esac
        model=$(sigil_provision_model "$provision_file") || return 1
        if sigil_model_has_i2s_dac "$model"; then
            printf '1\n'
            return 0
        fi
    fi

    configured_value=$(sigil_audio_conf_i2s_value "$existing_audio_conf") || return 1
    case "$configured_value" in
        0|1) printf '%s\n' "$configured_value" ;;
        unset) printf '0\n' ;;
        invalid)
            printf 'invalid SIGIL_I2S_DAC_PRESENT in %s\n' "$existing_audio_conf" >&2
            return 1
            ;;
        *) return 1 ;;
    esac
}

sigil_configure_i2s_overlay() {
    local config_txt="$1"
    local capability="$2"
    [ -f "$config_txt" ] || return 1
    case "$capability" in
        1)
            sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$config_txt"
            grep -qxF 'dtoverlay=hifiberry-dac' "$config_txt" \
                || printf '%s\n' 'dtoverlay=hifiberry-dac' >> "$config_txt"
            ;;
        0)
            sed -i '/^[[:space:]]*dtoverlay=hifiberry-dac[[:space:]]*$/d' "$config_txt"
            ;;
        *)
            printf 'invalid I2S capability: %s\n' "$capability" >&2
            return 1
            ;;
    esac
}

sigil_write_i2s_capability() {
    local audio_conf="$1"
    local capability="$2"
    case "$capability" in 0|1) ;; *) return 1 ;; esac
    if grep -q '^[[:space:]]*SIGIL_I2S_DAC_PRESENT[[:space:]]*=' "$audio_conf"; then
        sed -i "s/^[[:space:]]*SIGIL_I2S_DAC_PRESENT[[:space:]]*=.*/SIGIL_I2S_DAC_PRESENT=${capability}/" "$audio_conf"
    else
        printf '\nSIGIL_I2S_DAC_PRESENT=%s\n' "$capability" >> "$audio_conf"
    fi
}
