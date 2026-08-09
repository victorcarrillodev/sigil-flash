#!/usr/bin/env bash
# =============================================================================
# build-all-bundles.sh — Constructor por lotes de todos los bundles y payloads
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="${ROOT}/sigil-hardware/manifests"
ARTIFACTS_DIR="${ROOT}/artifacts"
IMAGES_DIR="${ROOT}/artifacts/images"

mkdir -p "$ARTIFACTS_DIR/bundles" "$IMAGES_DIR"

printf '▶ Iniciando construcción por lotes para todos los contratos en: %s\n' "$MANIFESTS_DIR"

for contract in "$MANIFESTS_DIR"/offline-package-contract*.json; do
    [ -f "$contract" ] || continue
    
    contract_name=$(basename "$contract" .json)
    base_image_name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["base_image_name"])' "$contract")
    base_image_path="${IMAGES_DIR}/${base_image_name}"

    if [ ! -f "$base_image_path" ]; then
        printf '⚠ AVISO: Imagen base "%s" para contrato "%s" no existe en %s. Saltando contrato.\n' "$base_image_name" "$contract_name" "$IMAGES_DIR"
        continue
    fi

    output_repo="${ARTIFACTS_DIR}/bundles/${contract_name}-repo"
    printf '▶ Construyendo bundle para contrato: %s -> %s\n' "$contract_name" "$output_repo"

    bash "${ROOT}/scripts/build-offline-repository.sh" "$contract" "$output_repo" "$base_image_path"
done

printf '▶ Regenerando todos los payloads...\n'
bash "${ROOT}/scripts/rebuild-payloads.sh"

printf '✔ Construcción por lotes completada.\n'
