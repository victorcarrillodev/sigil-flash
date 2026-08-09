#!/usr/bin/env bash
# =============================================================================
# run-all.sh — Suite de integración de SIGIL Flash
#
# No requiere root, red ni una microSD: valida los contratos, el binario, los
# payloads y la documentación. La escritura real en disco se prueba a mano
# siguiendo docs/manufacturing-guide.md.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0
FAILED=0
FAILED_NAMES=()

run_suite() {
    local name="$1"; shift
    printf '\n▶ %s\n' "$name"
    if "$@"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

run_suite "Pruebas unitarias de Rust" \
    cargo test --manifest-path "${ROOT}/src-tauri/Cargo.toml" \
        --all-targets --all-features --locked --offline

run_suite "Compilación del binario" \
    cargo build --manifest-path "${ROOT}/src-tauri/Cargo.toml" --locked --offline

run_suite "Pruebas del frontend (Vitest)" \
    bash -c "cd '${ROOT}' && npm run test --silent"

run_suite "Compilación estricta del frontend" \
    bash -c "cd '${ROOT}' && npm run build"

run_suite "Contrato de línea de comandos" bash "${ROOT}/tests/test_cli_modes.sh"
run_suite "Contrato de identidad y PIN"   bash "${ROOT}/tests/test_identity_contract.sh"
run_suite "Integridad de los payloads"    bash "${ROOT}/tests/test_payload_integrity.sh"
run_suite "Validación de los bundles"     bash "${ROOT}/tests/test_bundle_validation.sh"
run_suite "Documentación contra contrato" bash "${ROOT}/tests/test_docs_match_contract.sh"

printf '\n══════════════════════════════════════════\n'
printf '  Suites correctas : %s\n' "$PASSED"
printf '  Suites fallidas  : %s\n' "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    for name in "${FAILED_NAMES[@]}"; do
        printf '    ✘ %s\n' "$name"
    done
    exit 1
fi
printf '  ✔ Todas las suites pasaron\n'
