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
check "panel visual modules are included" \
    sh -c "test -f '$PAYLOAD/panel/static/css/tokens.css' && test -f '$PAYLOAD/panel/static/css/components.css' && test -f '$PAYLOAD/panel/static/css/layout.css'"
check "panel logo and login video are included" \
    sh -c "test -s '$PAYLOAD/panel/static/img/logo.png' && test -s '$PAYLOAD/panel/static/video/login-bg.mp4'"
check "every locally referenced panel asset exists" \
    python3 - "$PAYLOAD/panel" <<'PYEOF'
import pathlib
import re
import sys

panel = pathlib.Path(sys.argv[1])
references = set()
for path in [*panel.glob('templates/*.html'), *panel.glob('static/css/*.css')]:
    text = path.read_text(encoding='utf-8')
    references.update(re.findall(r"filename=['\"]([^'\"]+)['\"]", text))
    if path.suffix == '.css':
        for value in re.findall(r"@import\s+url\(['\"]?([^)'\"]+)", text):
            references.add(f"css/{value}")
missing = [value for value in sorted(references) if not (panel / 'static' / value).is_file()]
raise SystemExit(1 if missing else 0)
PYEOF
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
valid_source_state = isinstance(manifest.get("source_dirty"), bool)
raise SystemExit(0 if declared == actual and valid_target and valid_source_state else 1)
PYEOF

if [ -n "${SIGIL_FLASH_SERVICE:-}" ]; then
    FLASH_SERVICE="${SIGIL_FLASH_SERVICE}"
elif [ -f "${ROOT}/../src-tauri/src/services/flash_service.rs" ]; then
    FLASH_SERVICE="${ROOT}/../src-tauri/src/services/flash_service.rs"
else
    FLASH_SERVICE="${ROOT}/../sigil-flash/src-tauri/src/services/flash_service.rs"
fi
check "real flasher source is available" test -f "$FLASH_SERVICE"
check "real flasher resolves the generated payload artifact" \
    grep -q 'join("payloads")' "$FLASH_SERVICE"
check "real flasher copies the validated payload, not the source tree" \
    sh -c "grep -q 'copy_hardware_payload(hardware_payload' '$FLASH_SERVICE' && ! grep -q 'hardware_source = flash_root.join(\"sigil-hardware\")' '$FLASH_SERVICE'"
check "real flasher reads the package contract from the same payload" \
    grep -q 'let package_contract = hardware_payload' "$FLASH_SERVICE"
check "flasher plan matches production services and protected Bluetooth state" \
    sh -c "grep -q '\"audio-manager\"' '$ROOT/flasher-rs/src/model.rs' && grep -q '\"sigil-firstboot\"' '$ROOT/flasher-rs/src/model.rs' && grep -q '(\"/home/sigil/preferred_bt.txt\", \"sigil:sigil\", \"600\")' '$ROOT/flasher-rs/src/model.rs'"

printf '\nFlasher payload: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
