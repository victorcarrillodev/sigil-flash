#!/bin/bash
# Behavioral test for the production flasher payload builder.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
BUILDER="${ROOT}/scripts/build-flasher-payload.sh"
if [ "${SIGIL_MANUFACTURING_TESTS:-0}" != "1" ] && [ -f /etc/sigil/device.conf ]; then
    printf 'SKIP: flasher payload tests are build/manufacturing-only; no on-device payload generation\n'
    exit 0
fi
TEST_ROOT=$(mktemp -d /tmp/sigil-flasher-payload.XXXXXX)
PAYLOAD="${TEST_ROOT}/payload"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

check() {
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

if SIGIL_PAYLOAD_ALLOW_DIRTY=true bash "$BUILDER" "$PAYLOAD" \
    >"${TEST_ROOT}/builder.out" 2>"${TEST_ROOT}/builder.err"; then
    check "production payload builder succeeds" true
else
    check "production payload builder succeeds" false
fi

check "payload manifest is generated" test -f "${PAYLOAD}/payload-manifest.json"
check "installer is included" test -x "${PAYLOAD}/install.sh"
check "runtime panel is included" test -f "${PAYLOAD}/panel/geolocation.py"
check "runtime scripts are included" test -f "${PAYLOAD}/scripts/firstboot.sh"
check "runtime cache metadata helper is included" \
    test -f "${PAYLOAD}/scripts/sigil-cache-meta-perms.sh"
check "installer installs runtime cache metadata helper" \
    grep -Eq '^[[:space:]]+sigil-cache-meta-perms\.sh$' "${PAYLOAD}/install.sh"
check "systemd units are included" test -f "${PAYLOAD}/services/ssh-monitor.service"
check "runtime configuration is included" test -f "${PAYLOAD}/conf/sigil-tmpfiles.conf"
check "development trees are excluded" test ! -e "${PAYLOAD}/tests"
check "Git and Python caches are excluded" \
    test -z "$(find "$PAYLOAD" \( -name .git -o -name .pytest_cache -o -name __pycache__ -o -name '*.pyc' \) -print -quit)"
check "manifest matches every payload file and checksum" \
    python3 - "$PAYLOAD" <<'PYEOF'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "payload-manifest.json").read_text(encoding="utf-8"))
declared = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
actual = {
    path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in root.rglob("*")
    if path.is_file() and path.name != "payload-manifest.json"
}
valid_target = manifest["target"] == {
    "os": "raspberry-pi-os-lite",
    "release": "trixie",
    "architecture": "arm64",
    "hardware": "raspberry-pi-zero-2-w",
}
raise SystemExit(0 if declared == actual and valid_target else 1)
PYEOF

printf '\nFlasher payload: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
