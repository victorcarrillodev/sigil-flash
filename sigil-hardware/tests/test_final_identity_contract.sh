#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/sigil-identity-contract.XXXXXX)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok() { echo "ok: $1"; PASS=$((PASS + 1)); }
not_ok() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cat > "$TMP/provision.json" <<'EOF'
{
  "_schema_version": "1.0",
  "serial_number": "SIGIL-TEST-0001",
  "model": "Sigil-Streamer",
  "model_version": "v1",
  "batch": "2026-TEST",
  "capabilities": {"i2s_dac": true}
}
EOF
printf '%s\n' 'Serial : 1234abcd' > "$TMP/cpuinfo"
printf '%s\n' 'machine-test-id' > "$TMP/machine-id"
printf '%s\n' 'SIGIL_I2S_DAC_PRESENT=1' > "$TMP/audio.conf"

python3 - "$ROOT/panel/device_identity.py" "$TMP" <<'PYEOF'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("device_identity", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = sys.argv[2]
module.persist_provision(
    f"{root}/provision.json",
    f"{root}/device.conf",
    uid=os.getuid(),
    gid=os.getgid(),
)
PYEOF

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
: > "$CAPTURE_DIR/argv"
while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$CAPTURE_DIR/argv"
    case "$1" in
        --config) shift; cp "$1" "$CAPTURE_DIR/header" ;;
        -d) shift; printf '%s' "$1" > "$CAPTURE_DIR/body" ;;
        http*) printf '%s' "$1" > "$CAPTURE_DIR/url" ;;
    esac
    shift
done
printf '%s\n' '{"ok":true}'
EOF
chmod +x "$TMP/bin/curl"

# shellcheck source=scripts/firstboot.sh
source "$ROOT/scripts/firstboot.sh"
export CAPTURE_DIR="$TMP"
PATH="$TMP/bin:$PATH"
DEVICE_CONF="$TMP/device.conf"
AUDIO_CONF="$TMP/audio.conf"
IDENTITY_HELPER="$ROOT/panel/device_identity.py"
REGISTRATION_FILE="$TMP/registration.json"
SERVER_URL="https://server.invalid"
API_KEY="fake-device-token"
printf '%s\n' '{"_schema_version":"1.0","registered":false,"registered_at":null}' > "$REGISTRATION_FILE"
init_curl_auth
registration_output=$(register_device 2>&1)
cleanup_curl_auth

if python3 - "$TMP/body" <<'PYEOF'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
required = {"_schema_version", "device_id", "serial_number", "model", "model_version", "batch", "capabilities"}
raise SystemExit(0 if set(document) == required and isinstance(document["capabilities"]["i2s_dac"], bool) else 1)
PYEOF
then
    ok "registration contains the complete canonical identity"
else
    not_ok "registration contains the complete canonical identity"
fi

if grep -qxF 'header = "x-api-key: fake-device-token"' "$TMP/header"; then
    ok "x-api-key is sent through the protected curl config"
else
    not_ok "x-api-key is sent through the protected curl config"
fi

if ! grep -Fq 'fake-device-token' "$TMP/argv" \
    && ! grep -Fq 'fake-device-token' "$TMP/body" \
    && ! grep -Fq 'fake-device-token' "$TMP/url"; then
    ok "token is absent from argv, request body, and URL"
else
    not_ok "token is absent from argv, request body, and URL"
fi

if ! grep -Fq 'fake-device-token' <<< "$registration_output"; then
    ok "token is absent from registration logs"
else
    not_ok "token is absent from registration logs"
fi

if python3 - "$TMP/registration.json" <<'PYEOF'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if document == {
    "_schema_version": "1.0", "registered": True,
    "registered_at": document["registered_at"],
} and document["registered_at"] else 1)
PYEOF
then
    ok "registration state does not duplicate identity values"
else
    not_ok "registration state does not duplicate identity values"
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
