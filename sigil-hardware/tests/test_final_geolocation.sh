#!/bin/bash
# Python-focused tests for the WiFi geolocation integration.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PASS=0
FAIL=0

run_test() {
    local name="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s (exit %d)\n' "$name" "$rc"
    fi
}

echo "=== Geolocation integration tests ==="

python3 "${HERE}/test_geolocation.py" 2>/dev/null
run_test "geolocation Python unit tests" $?

python3 -m py_compile "${ROOT}/panel/geolocation.py"
run_test "geolocation.py syntax" $?

python3 -m py_compile "${ROOT}/panel/wifi.py"
run_test "wifi.py syntax" $?

bash -n "${ROOT}/conf/90-sigil-geolocate"
run_test "dispatcher shell syntax" $?

bash -n "${ROOT}/install.sh"
run_test "install.sh shell syntax" $?

echo ""
echo "Geolocation totals: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
