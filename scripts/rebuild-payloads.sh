#!/usr/bin/env bash
# =============================================================================
# rebuild-payloads.sh — Orquestador de generación de payloads para flasher-rs
# Descubre automáticamente todos los contratos en sigil-hardware/manifests/
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="${ROOT}/sigil-hardware/manifests"
ARTIFACTS_PAYLOADS="${ROOT}/artifacts/payloads"
BUILDER_SCRIPT="${ROOT}/sigil-hardware/scripts/build-flasher-payload.sh"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -d "$MANIFESTS_DIR" ] || die "Directorio de manifiestos no existe: ${MANIFESTS_DIR}"
[ -f "$BUILDER_SCRIPT" ] || die "Script generador de payloads no existe: ${BUILDER_SCRIPT}"

# DEPENDENCIA DE GIT: comprobar que estamos dentro de un repo git limpio
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "REQUISITO OBLIGATORIO: Se requiere un repositorio Git inicializado para generar payloads."
fi

mkdir -p "$ARTIFACTS_PAYLOADS"

printf '▶ Buscando contratos de paquetes en: %s\n' "$MANIFESTS_DIR"

for contract in "$MANIFESTS_DIR"/offline-package-contract*.json; do
    [ -f "$contract" ] || continue
    
    contract_name=$(basename "$contract" .json)
    payload_output="${ARTIFACTS_PAYLOADS}/${contract_name}-payload"

    # Se construye a un lado y solo se sustituye al terminar bien. Borrar
    # primero deja sin payload cuando la construcción falla —el guardián de
    # archivos sin confirmar la aborta a menudo— y el flasheo siguiente muere
    # sin explicar por qué el payload desapareció.
    staging="${payload_output}.nuevo"
    rm -rf -- "$staging"

    printf '▶ Regenerando payload para contrato: %s -> %s\n' "$contract_name" "$payload_output"
    if ! bash "$BUILDER_SCRIPT" --contract "$contract" "$staging"; then
        rm -rf -- "$staging"
        die "No se pudo regenerar el payload de ${contract_name}; se conserva el anterior intacto"
    fi

    # El intercambio: el payload viejo no se toca hasta tener el nuevo entero.
    previo="${payload_output}.previo"
    rm -rf -- "$previo"
    if [ -d "$payload_output" ]; then
        mv -- "$payload_output" "$previo"
    fi
    if ! mv -- "$staging" "$payload_output"; then
        [ -d "$previo" ] && mv -- "$previo" "$payload_output"
        die "No se pudo instalar el payload de ${contract_name}"
    fi
    rm -rf -- "$previo"
done

printf '✔ Todos los payloads fueron regenerados exitosamente.\n'
printf 'NOTA IMPORTANTE: Los payloads son fotos fijas. Si modificas el software de dispositivo en sigil-hardware/, DEBES ejecutar este script nuevamente.\n'
