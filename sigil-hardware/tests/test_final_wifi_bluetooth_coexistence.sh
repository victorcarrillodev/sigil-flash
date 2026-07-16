#!/bin/bash
# Focused single-radio WiFi/Bluetooth coexistence regression suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PASS=0
FAIL=0

run_test() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$name"
    fi
}

run_test "cross-process scan/transition behavior" \
    python3 "${HERE}/test_wifi_bluetooth_coexistence.py"
run_test "Bluetooth SUSPENDED remains usable and route recovery is automatic" \
    bash "${HERE}/test_final_audio_routing.sh"
run_test "wifi-fallback keeps canonical AP/client ownership" \
    bash "${HERE}/test_final_wifi_fallback.sh"
run_test "WiFi and geolocation Python syntax" \
    python3 -m py_compile "${ROOT}/panel/wifi.py" "${ROOT}/panel/geolocation.py"
run_test "wifi-fallback shell syntax" \
    bash -n "${ROOT}/scripts/wifi-fallback.sh"

printf '\nWiFi/Bluetooth coexistence: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
