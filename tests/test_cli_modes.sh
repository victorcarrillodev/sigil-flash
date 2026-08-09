#!/usr/bin/env bash
# Comprueba el contrato de línea de comandos de los tres modos de ejecución.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${SIGIL_FLASH_BINARY:-${ROOT}/src-tauri/target/debug/sigil-flash}"

fail() { printf '  ✘ %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ✔ %s\n' "$*"; }

[ -x "$BINARY" ] || fail "Binario no compilado: ${BINARY} (ejecute: cargo build --manifest-path src-tauri/Cargo.toml)"

export SIGIL_LOG=error

# Cada parámetro obligatorio ausente debe nombrarse por su flag exacto.
for flag in --src --dest --progress-file --offline-packages --payload --config-file; do
    output=$("$BINARY" --flash-raw 2>&1 || true)
    case "$output" in
        *"'--src'"*) ;;
        *) fail "El error de --flash-raw sin argumentos no nombra el flag faltante: ${output}" ;;
    esac
done
ok "--flash-raw nombra el flag obligatorio que falta"

output=$("$BINARY" --flash-raw --src /tmp/x 2>&1 || true)
case "$output" in
    *"'--dest'"*) ok "el error avanza al siguiente flag faltante" ;;
    *) fail "no se detectó la ausencia de --dest: ${output}" ;;
esac

if "$BINARY" --flash-raw --src /tmp/x >/dev/null 2>&1; then
    fail "--flash-raw con argumentos incompletos debería salir con código distinto de cero"
fi
ok "--flash-raw sale con código de error cuando falta un parámetro"

output=$("$BINARY" --configure-device 2>&1 || true)
case "$output" in
    *"'--device'"*) ok "--configure-device nombra su flag obligatorio" ;;
    *) fail "--configure-device no valida --device: ${output}" ;;
esac

# El modo --configure-device debe intentar trabajar de verdad, no salir en cero
# silenciosamente: sin configuración válida tiene que fallar.
missing_config="$(mktemp -u "${TMPDIR:-/tmp}/sigil-config-inexistente.XXXXXX")"
if "$BINARY" --configure-device --device /dev/null --config-file "$missing_config" >/dev/null 2>&1; then
    fail "--configure-device aceptó una configuración inexistente y salió con éxito"
fi
ok "--configure-device falla cerrado ante una configuración inexistente"

# Una configuración con permisos relajados debe rechazarse.
loose_config=$(mktemp "${TMPDIR:-/tmp}/sigil-config.XXXXXX.json")
printf '{}' > "$loose_config"
chmod 0644 "$loose_config"
output=$("$BINARY" --configure-device --device /dev/null --config-file "$loose_config" 2>&1 || true)
rm -f -- "$loose_config"
case "$output" in
    *"Permisos inseguros"*) ok "rechaza una configuración privada con permisos de grupo u otros" ;;
    *) fail "no se rechazó una configuración 0644: ${output}" ;;
esac

if ! "$BINARY" --help >/dev/null 2>&1; then
    fail "--help debería salir con código 0"
fi
ok "--help documenta los tres modos"

output=$("$BINARY" --modo-inventado 2>&1 || true)
case "$output" in
    *"Argumento desconocido"*) ok "un argumento desconocido se rechaza" ;;
    *) fail "no se rechazó un argumento desconocido: ${output}" ;;
esac
