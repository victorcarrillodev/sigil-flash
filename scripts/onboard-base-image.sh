#!/usr/bin/env bash
# =============================================================================
# onboard-base-image.sh — Alta de una imagen oficial nueva y derivación de su
# contrato A PARTIR DE LA PROPIA IMAGEN.
#
# La arquitectura NUNCA se deduce del nombre del archivo: una descarga mal
# etiquetada debe detectarse en segundos, no dentro del chroot tras veinte
# minutos de escritura.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_CONTRACT="${ROOT}/sigil-hardware/manifests/offline-package-contract.json"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Uso: onboard-base-image.sh <imagen.img[.xz]> <nombre_variante> [--build]\n'
    printf 'Ejemplo: onboard-base-image.sh artifacts/images/32bits2026-06-18-raspios-trixie-armhf-lite.img.xz armhf --build\n'
    exit 1
}

IMAGE_FILE="${1:-}"
VARIANT_NAME="${2:-}"
DO_BUILD=false
[ "${3:-}" = "--build" ] && DO_BUILD=true

[ -n "$IMAGE_FILE" ] && [ -n "$VARIANT_NAME" ] || usage
[ "$VARIANT_NAME" != "--build" ] || usage
[ -f "$IMAGE_FILE" ] || die "Archivo de imagen no existe: ${IMAGE_FILE}"
[ -f "$CANONICAL_CONTRACT" ] || die "Contrato canónico no encontrado: ${CANONICAL_CONTRACT}"

# El nombre de variante acaba siendo una ruta de archivo.
case "$VARIANT_NAME" in
    *[!A-Za-z0-9._-]*|*..*) die "Nombre de variante inválido: '${VARIANT_NAME}' (solo [A-Za-z0-9._-])" ;;
esac

printf '▶ Alta de nueva imagen base: %s\n' "$IMAGE_FILE"

SHA256=$(sha256sum "$IMAGE_FILE" | awk '{print $1}')
IMAGE_BASENAME=$(basename "$IMAGE_FILE")

TEMP_META=$(mktemp -d "${ROOT}/artifacts/.sigil-onboard.XXXXXX")
cleanup() { rm -rf -- "$TEMP_META"; }
trap cleanup EXIT HUP INT TERM

# Todavía no hay contrato que declare esta imagen: el hash se fija ahora.
SIGIL_SKIP_IMAGE_HASH_CHECK=1 \
    bash "${ROOT}/scripts/extract-official-apt-metadata.sh" "$IMAGE_FILE" "$TEMP_META" "$CANONICAL_CONTRACT"

# ── Codename y versión desde os-release ──────────────────────────────────────
CODENAME=$(grep '^VERSION_CODENAME=' "$TEMP_META/os-release" | cut -d= -f2 | tr -d '"')
VERSION_ID=$(grep '^VERSION_ID=' "$TEMP_META/os-release" | cut -d= -f2 | tr -d '"')
[ -n "$CODENAME" ] && [ -n "$VERSION_ID" ] || die "El os-release de la imagen no declara codename o versión"

# ── Distribución según el archivo de fuentes que la imagen trae firmado ──────
DISTRO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_distribution"])' \
    "$TEMP_META/extraction.json")

# ── Arquitectura por cabecera ELF de un binario real del rootfs ──────────────
ELF_ARCH=$(python3 - "$TEMP_META/arch-probe.elf" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read(20)
if len(data) < 20 or data[0:4] != b"\x7fELF":
    print("unknown")
    raise SystemExit(0)
machine = int.from_bytes(data[18:20], "little" if data[5] == 1 else "big")
print({183: "arm64", 40: "armhf", 62: "x86_64", 3: "x86"}.get(machine, f"unknown({machine})"))
PYEOF
)

case "$ELF_ARCH" in
    arm64|armhf) ;;
    *) die "Arquitectura no soportada leída del rootfs: ${ELF_ARCH}" ;;
esac
printf '✔ Arquitectura verificada desde el rootfs de la imagen: %s\n' "$ELF_ARCH"
printf '✔ Distribución según las fuentes firmadas de la imagen: %s %s (%s)\n' "$DISTRO" "$VERSION_ID" "$CODENAME"

CONTRACT_NAME="offline-package-contract.${VARIANT_NAME}"
NEW_CONTRACT_PATH="${ROOT}/sigil-hardware/manifests/${CONTRACT_NAME}.json"

# La lista de paquetes se COPIA del contrato canónico sin modificarla: las
# variantes no pueden divergir del contrato de producto.
python3 - "$CANONICAL_CONTRACT" "$NEW_CONTRACT_PATH" "$IMAGE_BASENAME" "$SHA256" \
         "$ELF_ARCH" "$DISTRO" "$VERSION_ID" "$CODENAME" <<'PYEOF'
import json, sys

contract = json.load(open(sys.argv[1]))
out_path, image, sha, arch, distro, version, codename = sys.argv[2:9]

contract["base_image_name"] = image
contract["base_image_sha256"] = sha
contract["architecture"] = arch
contract["allowed_package_architectures"] = [arch, "all"]
contract["distribution"] = distro
contract["distribution_version"] = version
contract["distribution_codename"] = codename

# Raspbian solo acompaña a las imágenes oficiales de 32 bits.
if distro == "raspbian" and arch != "armhf":
    raise SystemExit(f"contrato incoherente: raspbian con arquitectura {arch}")

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(contract, handle, indent=2)
    handle.write("\n")
PYEOF

printf '✔ Contrato derivado creado: %s\n' "$NEW_CONTRACT_PATH"

if $DO_BUILD; then
    printf '▶ Construyendo bundle y regenerando payloads...\n'
    # El nombre del directorio debe ser <contrato>-repo: así lo empareja la
    # resolución del par bundle/payload en tiempo de flasheo.
    bash "${ROOT}/scripts/build-offline-repository.sh" \
        "$NEW_CONTRACT_PATH" \
        "${ROOT}/artifacts/bundles/${CONTRACT_NAME}-repo" \
        "$IMAGE_FILE"
    bash "${ROOT}/scripts/rebuild-payloads.sh"
fi

printf '✔ Alta de imagen base completada.\n'
