#!/usr/bin/env bash
# Los payloads son fotos fijas: este test comprueba que lo generado coincide
# con su manifiesto y que una alteración posterior se detecta.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf '  ✘ %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ✔ %s\n' "$*"; }

PAYLOADS="${ROOT}/artifacts/payloads"
[ -d "$PAYLOADS" ] || fail "No hay payloads generados. Ejecute ./scripts/rebuild-payloads.sh"

CONTRACT_COUNT=$(find "${ROOT}/sigil-hardware/manifests" -maxdepth 1 -name 'offline-package-contract*.json' | wc -l)
PAYLOAD_COUNT=$(find "$PAYLOADS" -maxdepth 1 -type d -name '*-payload' | wc -l)
[ "$CONTRACT_COUNT" -eq "$PAYLOAD_COUNT" ] \
    || fail "Hay ${CONTRACT_COUNT} contratos y ${PAYLOAD_COUNT} payloads: regenere con ./scripts/rebuild-payloads.sh"
ok "un payload por contrato descubierto (${PAYLOAD_COUNT})"

EXPECTED_FILES=$(grep -cv '^\s*\(#.*\)\?$' "${ROOT}/sigil-hardware/manifests/flasher-payload-files.txt")

for payload in "$PAYLOADS"/*-payload; do
    name=$(basename "$payload")
    manifest="${payload}/payload-manifest.json"
    [ -f "$manifest" ] || fail "${name}: falta payload-manifest.json"

    python3 - "$payload" "$EXPECTED_FILES" <<'PYEOF'
import hashlib, json, pathlib, sys

payload = pathlib.Path(sys.argv[1])
expected_files = int(sys.argv[2])
manifest = json.loads((payload / "payload-manifest.json").read_text(encoding="utf-8"))

entries = manifest["files"]
if len(entries) != expected_files:
    raise SystemExit(f"{payload.name}: el manifiesto lista {len(entries)} archivos "
                     f"y flasher-payload-files.txt declara {expected_files}")

for entry in entries:
    target = payload / entry["path"]
    if not target.is_file():
        raise SystemExit(f"{payload.name}: falta el archivo {entry['path']}")
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if digest != entry["sha256"]:
        raise SystemExit(f"{payload.name}: checksum distinto en {entry['path']}")

# Ni un archivo de más: el conjunto debe ser exacto.
declared = {entry["path"] for entry in entries} | {"payload-manifest.json"}
present = {p.relative_to(payload).as_posix() for p in payload.rglob("*") if p.is_file()}
extra = present - declared
if extra:
    raise SystemExit(f"{payload.name}: archivos no declarados en el manifiesto: {sorted(extra)}")

contract = json.loads((payload / "manifests/offline-package-contract.json").read_text(encoding="utf-8"))
for field in ("base_image_name", "architecture"):
    if field not in contract:
        raise SystemExit(f"{payload.name}: el contrato embebido no declara {field}")
PYEOF

    ok "${name}: ${EXPECTED_FILES} archivos coinciden con su manifiesto"
done

# Una alteración posterior a la generación debe detectarse.
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/sigil-payload-tamper.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT

CANONICAL="${PAYLOADS}/offline-package-contract-payload"
cp -a "$CANONICAL" "$SANDBOX/payload"
printf '\n# alterado tras generar el payload\n' >> "$SANDBOX/payload/install.sh"

if python3 - "$SANDBOX/payload" <<'PYEOF'
import hashlib, json, pathlib, sys
payload = pathlib.Path(sys.argv[1])
manifest = json.loads((payload / "payload-manifest.json").read_text(encoding="utf-8"))
for entry in manifest["files"]:
    digest = hashlib.sha256((payload / entry["path"]).read_bytes()).hexdigest()
    if digest != entry["sha256"]:
        raise SystemExit(1)
PYEOF
then
    fail "una modificación posterior del payload NO fue detectada"
fi
ok "una modificación posterior a la generación se detecta"
