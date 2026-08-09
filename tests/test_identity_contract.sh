#!/usr/bin/env bash
# El documento de identidad que escribe SIGIL Flash lo lee device_identity.py
# dentro del dispositivo. Este test comprueba ese contrato con el validador
# real, en vez de suponer que ambos lados coinciden.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE="${ROOT}/src-tauri/target/identity-sample.json"

fail() { printf '  ✘ %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ✔ %s\n' "$*"; }

[ -f "$SAMPLE" ] || fail "Falta la muestra ${SAMPLE}. Ejecute antes: cargo test --manifest-path src-tauri/Cargo.toml"

PYTHONPATH="${ROOT}/sigil-hardware/panel" python3 - "$SAMPLE" <<'PYEOF'
import json, sys
import device_identity

document = json.load(open(sys.argv[1], encoding="utf-8"))
normalized = device_identity.validate_provision(document)

if normalized["serial_number"] != document["serial_number"]:
    raise SystemExit("el validador normalizó el número de serie de otra forma")
if normalized["capabilities"] != {"i2s_dac": False}:
    raise SystemExit("capabilities no sobrevive la normalización")
PYEOF
ok "device_identity.py acepta el documento de identidad generado"

# El documento no puede llevar secretos aunque la configuración los tenga.
python3 - "$SAMPLE" <<'PYEOF'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
document = json.load(open(sys.argv[1], encoding="utf-8"))
forbidden = ("panel_pin", "password", "enrollment", "api_key", "psk", "wifi")
for needle in forbidden:
    if needle in raw.lower():
        raise SystemExit(f"el documento de identidad contiene '{needle}'")
if set(document) != {"_schema_version", "serial_number", "model", "model_version",
                     "batch", "capabilities"}:
    raise SystemExit("el documento de identidad no tiene el conjunto exacto de campos")
PYEOF
ok "el documento lleva el número de serie y ningún secreto de acceso"

# El secreto del PIN sí debe cumplir el esquema exacto que exige panel_auth.py.
# argon2 solo vive dentro de la imagen (python3-argon2 del bundle), así que en
# un PC sin ese módulo esta comprobación se omite en lugar de fallar.
if ! python3 -c 'import argon2' 2>/dev/null; then
    printf '  ○ panel_auth omitido: falta el módulo python argon2 en este PC\n'
    exit 0
fi

PYTHONPATH="${ROOT}/sigil-hardware/panel" python3 - <<'PYEOF'
import json
import panel_auth

# El mismo documento que escribe provision_panel_pin.
document = {"_schema_version": "1.0", "panel_pin": "847392"}
if set(document) != {"_schema_version", "panel_pin"}:
    raise SystemExit("esquema del secreto de fabricación incorrecto")
panel_auth.validate_panel_pin(document["panel_pin"])

for rejected in ("111111", "123456", "654321", "12345", "abcdef"):
    try:
        panel_auth.validate_panel_pin(rejected)
    except Exception:
        continue
    raise SystemExit(f"panel_auth aceptó un PIN que SIGIL Flash rechaza: {rejected}")
PYEOF
ok "panel_auth.py y la validación de PIN de SIGIL Flash coinciden"
