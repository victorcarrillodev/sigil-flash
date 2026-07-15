#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

python3 "${HERE}/test_panel_auth.py"

if grep -Eq 'panel_pin|panel-pin' "${ROOT}/manifests/services.json" "${ROOT}/conf/audio.conf"; then
    exit 1
fi
if grep -Eq -- '--panel-pin|SIGIL_PANEL_PIN=.*[0-9]' "${ROOT}/install.sh" "${ROOT}/scripts/firstboot.sh"; then
    exit 1
fi
grep -q 'panel/templates/login.html' "${ROOT}/manifests/flasher-payload-files.txt"
grep -q 'panel/panel_auth.py' "${ROOT}/manifests/flasher-payload-files.txt"
grep -q 'install -d -o root -g sigil -m 0750 /etc/sigil/secrets' "${ROOT}/install.sh"
grep -q 'install -d -o root -g root -m 0700 /etc/sigil/manufacturing' "${ROOT}/install.sh"
grep -q 'IDENTITY_HELPER="${SIGIL_IDENTITY_HELPER:-/opt/sigil/panel/device_identity.py}"' "${ROOT}/scripts/firstboot.sh"

echo "panel authentication contract: PASS"
