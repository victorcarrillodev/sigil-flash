#!/bin/bash
# Test runner for sigil-hardware regression suite
#
# Usage:
#   ./tests/run.sh                    # run all tests
#   ./tests/run.sh --list             # list tests
#   ./tests/run.sh --name "test_*"    # run matching tests
#   ./tests/run.sh --verbose           # include stdout/stderr

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERBOSE=false

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) VERBOSE=true; shift ;;
        *) args+=("$1"); shift ;;
    esac
done

OVERALL_PASS=0
OVERALL_FAIL=0
OVERALL_FAILED_SUITES=()

run_suite() {
    local suite="$1"
    local label="$2"
    shift 2
    echo ""
    echo "────────────────────────────────────────"
    echo " Suite: ${label}"
    echo "────────────────────────────────────────"
    local rc=0
    local suite_path="$suite"
    if [[ "$suite_path" != /* ]]; then
        suite_path="${HERE}/${suite_path}"
    fi
    if [ "$VERBOSE" = true ]; then
        bash "$suite_path" "${args[@]}" || rc=$?
    else
        bash "$suite_path" "${args[@]}" 2>/dev/null || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        OVERALL_PASS=$((OVERALL_PASS + 1))
    else
        OVERALL_FAIL=$((OVERALL_FAIL + 1))
        OVERALL_FAILED_SUITES+=("${label}")
    fi
    return "$rc"
}

SUITES=()
if [ -n "${SIGIL_TEST_SUITES:-}" ]; then
    IFS=':' read -r -a SUITES <<< "$SIGIL_TEST_SUITES"
else
    SUITES=("test_suite.sh" "test_cutover.sh")
    while IFS= read -r suite_path; do
        SUITES+=("$(basename "$suite_path")")
    done < <(find "$HERE" -maxdepth 1 -type f -name 'test_final_*.sh' -print | sort)
fi

for suite in "${SUITES[@]}"; do
    # Invoke in an if-condition so `set -e` cannot terminate the runner before
    # later suites execute. run_suite records the result for the final summary.
    if run_suite "$suite" "$(basename "$suite")" "${args[@]}"; then
        :
    else
        :
    fi
done

echo ""
echo "========================================"
echo "Overall: ${OVERALL_PASS} suite(s) passed, ${OVERALL_FAIL} suite(s) failed"
if [ "$OVERALL_FAIL" -gt 0 ]; then
    echo ""
    echo "Failed suites:"
    for fs in "${OVERALL_FAILED_SUITES[@]}"; do
        echo "  - $fs"
    done
    exit 1
fi
exit 0
