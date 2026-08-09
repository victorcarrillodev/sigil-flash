#!/usr/bin/env bash
# La documentación que cita nombres de imagen o recuentos debe salir del
# contrato: un dato desfasado le cuesta una hora al operario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="${ROOT}/sigil-hardware/manifests"

fail() { printf '  ✘ %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ✔ %s\n' "$*"; }

PAYLOAD_FILES=$(grep -cv '^\s*\(#.*\)\?$' "${MANIFESTS}/flasher-payload-files.txt")

# Cualquier recuento de archivos de payload citado en la documentación debe
# coincidir con el manifiesto real.
while IFS= read -r doc; do
    while IFS= read -r cited; do
        [ "$cited" = "$PAYLOAD_FILES" ] \
            || fail "$(basename "$doc") cita ${cited} archivos de payload; el manifiesto declara ${PAYLOAD_FILES}"
    done < <(grep -oE 'los ([0-9]+) archivos' "$doc" | grep -oE '[0-9]+' || true)
done < <(find "${ROOT}/docs" "${ROOT}/README.md" -type f -name '*.md')
ok "los recuentos de archivos de payload citados coinciden (${PAYLOAD_FILES})"

# Los nombres de imagen que aparecen en la documentación deben existir en algún
# contrato: un ejemplo inventado manda al operario a descargar la imagen mala.
IMAGES=$(python3 - "$MANIFESTS" <<'PYEOF'
import json, pathlib, sys
manifests = pathlib.Path(sys.argv[1])
names = set()
for contract in manifests.glob("offline-package-contract*.json"):
    names.add(json.loads(contract.read_text(encoding="utf-8"))["base_image_name"])
print("\n".join(sorted(names)))
PYEOF
)

while IFS= read -r doc; do
    while IFS= read -r cited; do
        grep -qxF "$cited" <<< "$IMAGES" \
            || fail "$(basename "$doc") cita la imagen '${cited}', que ningún contrato declara"
    done < <(grep -ohE '[0-9A-Za-z._-]*raspios[0-9A-Za-z._-]*\.img(\.xz)?' "$doc" | sort -u || true)
done < <(find "${ROOT}/docs" "${ROOT}/README.md" -type f -name '*.md')
ok "los nombres de imagen citados existen en algún contrato"

# Ningún secreto puede aparecer en el repositorio ni en los artefactos.
if grep -rInE '(enrollment[_-]?key|panel_pin|SIGIL_FACTORY_PASSWORD)\s*[:=]\s*["'"'"'][^"'"'"']{6,}' \
        "${ROOT}/src" "${ROOT}/src-tauri/src" "${ROOT}/scripts" "${ROOT}/docs" 2>/dev/null \
        | grep -v 'placeholder\|ejemplo\|example' ; then
    fail "hay un secreto con valor literal en el repositorio"
fi
ok "no hay secretos con valor literal en el código ni en la documentación"

# La documentación debe explicar los cuatro puntos exigidos.
GUIDE="${ROOT}/docs/manufacturing-guide.md"
for topic in "Alta de una Nueva Imagen" "payloads" "keyring" "Actualización de Versión"; do
    grep -qi "$topic" "$GUIDE" || fail "docs/manufacturing-guide.md no cubre: ${topic}"
done
ok "la guía de fabricación cubre alta de imagen, payloads, credencial y subida de versión"
