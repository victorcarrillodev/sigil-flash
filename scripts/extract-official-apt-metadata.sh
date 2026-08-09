#!/usr/bin/env bash
# =============================================================================
# extract-official-apt-metadata.sh — Extrae fuentes y keyrings de la imagen
# oficial verificada por hash.
#
# LOS KEYRINGS DEL HOST NUNCA SE CONFÍAN: la cadena de confianza arranca en la
# imagen oficial, no en el equipo que fabrica.
# =============================================================================
set -euo pipefail

IMAGE_FILE="${1:-}"
OUTPUT_DIR="${2:-}"
CONTRACT="${3:-sigil-hardware/manifests/offline-package-contract.json}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -n "$IMAGE_FILE" ] || die "Uso: extract-official-apt-metadata.sh <imagen.img[.xz]> <dir_salida> [contrato]"
[ -f "$IMAGE_FILE" ] || die "Archivo de imagen no existe: ${IMAGE_FILE}"
[ -n "$OUTPUT_DIR" ] || die "Se requiere directorio de salida"
[ -f "$CONTRACT" ] || die "Contrato no encontrado: ${CONTRACT}"

for tool in sfdisk debugfs dd sha256sum python3; do
    command -v "$tool" >/dev/null || die "Falta la herramienta '${tool}' en el PC de fabricación"
done

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# ── Verificar el hash de la imagen contra el contrato ────────────────────────
EXPECTED_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_image_sha256"])' "$CONTRACT")
ACTUAL_SHA=$(sha256sum "$IMAGE_FILE" | awk '{print $1}')
if [ "${SIGIL_SKIP_IMAGE_HASH_CHECK:-0}" = "1" ]; then
    # Solo al DAR DE ALTA una imagen nueva: todavía no existe un contrato que
    # declare su hash. El contrato derivado lo fija a partir de este valor.
    printf '▶ Alta de imagen nueva: SHA-256 calculado %s\n' "$ACTUAL_SHA"
elif [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    die "SHA-256 de la imagen no coincide con el contrato.
  Esperado : ${EXPECTED_SHA}
  Obtenido : ${ACTUAL_SHA}
  Descargue de nuevo la imagen oficial, o dé de alta un contrato para esta
  imagen con ./scripts/onboard-base-image.sh"
else
    printf '✔ SHA-256 de la imagen base verificado: %s\n' "$ACTUAL_SHA"
fi

# El rootfs de una imagen de Raspberry Pi ronda los 2,5 GB: el directorio de
# trabajo va junto a la salida, en disco, y no en un /tmp en memoria.
SCRATCH_BASE="${SIGIL_SCRATCH_DIR:-$(dirname "$OUTPUT_DIR")}"
mkdir -p "$SCRATCH_BASE"
SCRATCH=$(mktemp -d "${SCRATCH_BASE}/sigil-image-extract.XXXXXX")
cleanup() { rm -rf -- "$SCRATCH"; }
trap cleanup EXIT HUP INT TERM

# La tabla de particiones vive en el primer MiB: basta con leer ese trozo del
# flujo descomprimido para localizar la partición sin materializar la imagen.
PART_TABLE="$SCRATCH/partition-table.json"
if [[ "$IMAGE_FILE" == *.xz ]]; then
    xz -d -c "$IMAGE_FILE" 2>/dev/null | head -c 1048576 > "$SCRATCH/head.bin" || true
    sfdisk --json "$SCRATCH/head.bin" > "$PART_TABLE" 2>/dev/null
else
    sfdisk --json "$IMAGE_FILE" > "$PART_TABLE"
fi
[ -s "$PART_TABLE" ] || die "No se pudo leer la tabla de particiones de la imagen"

read -r START_SECTOR SECTOR_COUNT <<< "$(python3 - "$PART_TABLE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
table = data.get("partitiontable", {})
partitions = table.get("partitions", [])
linux = [p for p in partitions
         if str(p.get("type", "")).lower() in ("83", "0x83",
                                               "0fc63daf-8483-4772-8e79-3d69d8477de4")]
if len(linux) != 1:
    raise SystemExit(f"se esperaba exactamente 1 partición Linux, se encontraron {len(linux)}")
print(linux[0]["start"], linux[0]["size"])
PYEOF
)"

printf '▶ Partición Linux en el sector %s (%s sectores); extrayendo el rango...\n' "$START_SECTOR" "$SECTOR_COUNT"
ROOTFS="$SCRATCH/rootfs.img"
if [[ "$IMAGE_FILE" == *.xz ]]; then
    # Se extrae SOLO el rango de la partición del flujo descomprimido: nunca
    # se materializa la imagen entera en disco.
    xz -d -c "$IMAGE_FILE" \
        | dd of="$ROOTFS" bs=512 skip="$START_SECTOR" count="$SECTOR_COUNT" \
             iflag=fullblock status=none
else
    dd if="$IMAGE_FILE" of="$ROOTFS" bs=512 skip="$START_SECTOR" count="$SECTOR_COUNT" status=none
fi
[ -s "$ROOTFS" ] || die "No se pudo extraer la partición raíz de la imagen"

mkdir -p "$OUTPUT_DIR/sources" "$OUTPUT_DIR/keyrings"

# debugfs no sigue enlaces simbólicos: `cat` sobre uno falla con un error de
# lectura confuso, así que se resuelve el destino antes de leer.
dump_file() {
    local internal="$1" dest="$2"
    if debugfs -R "stat ${internal}" "$ROOTFS" 2>/dev/null | head -1 | grep -q 'Type: symlink'; then
        local target
        target=$(debugfs -R "stat ${internal}" "$ROOTFS" 2>/dev/null | sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p')
        [ -n "$target" ] || return 0
        case "$target" in
            /*) internal="$target" ;;
            *)  internal="$(dirname "$internal")/${target}" ;;
        esac
    fi
    debugfs -R "cat ${internal}" "$ROOTFS" > "$dest" 2>/dev/null || true
    [ -s "$dest" ] || rm -f -- "$dest"
}

printf '▶ Extrayendo os-release, base de datos dpkg, fuentes y keyrings...\n'
dump_file /etc/os-release      "$OUTPUT_DIR/os-release"
dump_file /var/lib/dpkg/status "$OUTPUT_DIR/dpkg-status"

# Binario REAL del rootfs para determinar la arquitectura por cabecera ELF.
# Nunca se deduce del nombre del archivo de imagen.
for candidate in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh /usr/lib/systemd/systemd; do
    dump_file "$candidate" "$OUTPUT_DIR/arch-probe.elf"
    [ -s "$OUTPUT_DIR/arch-probe.elf" ] && break
done
[ -s "$OUTPUT_DIR/arch-probe.elf" ] || die "No se pudo extraer ningún binario del rootfs para leer su cabecera ELF"

# Descubrir los archivos de fuentes que la imagen realmente trae.
BASE_SOURCES=""
RASPI_SOURCES=""
while read -r candidate; do
    [ -n "$candidate" ] || continue
    local_name=$(basename "$candidate")
    dump_file "$candidate" "$OUTPUT_DIR/sources/${local_name}"
    [ -s "$OUTPUT_DIR/sources/${local_name}" ] || continue
    # El archivo de Raspberry Pi vive SIEMPRE en archive.raspberrypi.com; el
    # archivo base es Debian en 64 bits y Raspbian en 32. Ojo: Raspbian se
    # sirve desde raspbian.raspberrypi.com, así que el discriminante es la
    # ruta del archivo, no el dominio.
    if grep -Eqi 'archive\.raspberrypi\.com' "$OUTPUT_DIR/sources/${local_name}"; then
        RASPI_SOURCES="$OUTPUT_DIR/sources/${local_name}"
    elif grep -Eqi 'deb\.debian\.org|/raspbian|archive\.raspbian\.org' "$OUTPUT_DIR/sources/${local_name}"; then
        BASE_SOURCES="$OUTPUT_DIR/sources/${local_name}"
    fi
done < <(
    printf '/etc/apt/sources.list\n'
    debugfs -R "ls -p /etc/apt/sources.list.d" "$ROOTFS" 2>/dev/null \
        | awk -F'/' 'NF>=6 && $6 != "" && $6 != "." && $6 != ".." {print "/etc/apt/sources.list.d/" $6}'
)

[ -s "$OUTPUT_DIR/os-release" ]  || die "No se pudo extraer os-release de la imagen"
[ -s "$OUTPUT_DIR/dpkg-status" ] || die "No se pudo extraer /var/lib/dpkg/status de la imagen"
[ -n "$BASE_SOURCES" ]  || die "La imagen no declara ningún archivo de fuentes del archivo base (Debian o Raspbian)"
[ -n "$RASPI_SOURCES" ] || die "La imagen no declara el archivo de fuentes del archivo de Raspberry Pi"

# En 64 bits el archivo base es Debian; en 32 bits es Raspbian, la
# recompilación ARMv6 de la Fundación. Debe ser exactamente uno de los dos.
if grep -Eqi 'raspbian' "$BASE_SOURCES"; then
    BASE_DISTRIBUTION="raspbian"
else
    BASE_DISTRIBUTION="debian"
fi

# Los keyrings se extraen por la ruta que las PROPIAS fuentes declaran en
# Signed-By: así seguimos la cadena que la imagen firma, no una suposición.
extract_declared_keyrings() {
    local sources_file="$1" role="$2" found=0
    while read -r keyring_path; do
        [ -n "$keyring_path" ] || continue
        local dest="$OUTPUT_DIR/keyrings/${role}-$(basename "${keyring_path%.*}").gpg"
        dump_file "$keyring_path" "$dest"
        [ -s "$dest" ] && found=1
    done < <(grep -Ei '^\s*Signed-By:' "$sources_file" | sed -E 's/^\s*Signed-By:\s*//' | tr ' ' '\n' | grep '^/' | sort -u)

    if [ "$found" -eq 0 ]; then
        # Fuentes en formato antiguo sin Signed-By: se recurre al keyring
        # canónico del archivo, siempre leído de dentro de la imagen.
        local fallback
        case "$role" in
            base)  fallback="/usr/share/keyrings/${BASE_DISTRIBUTION}-archive-keyring" ;;
            raspi) fallback="/usr/share/keyrings/raspberrypi-archive-keyring" ;;
        esac
        for extension in pgp gpg; do
            dump_file "${fallback}.${extension}" "$OUTPUT_DIR/keyrings/${role}-archive.gpg"
            [ -s "$OUTPUT_DIR/keyrings/${role}-archive.gpg" ] && { found=1; break; }
        done
    fi

    [ "$found" -eq 1 ] || die "No se pudo extraer el keyring del archivo '${role}' de la imagen"
}

extract_declared_keyrings "$BASE_SOURCES" base
extract_declared_keyrings "$RASPI_SOURCES" raspi

python3 - "$OUTPUT_DIR" "$BASE_DISTRIBUTION" "$BASE_SOURCES" "$RASPI_SOURCES" <<'PYEOF'
import json, os, sys
output, distribution, base_sources, raspi_sources = sys.argv[1:5]
keyrings = sorted(os.listdir(os.path.join(output, "keyrings")))
summary = {
    "base_distribution": distribution,
    "base_sources": os.path.relpath(base_sources, output),
    "raspi_sources": os.path.relpath(raspi_sources, output),
    "keyrings": [f"keyrings/{name}" for name in keyrings],
}
with open(os.path.join(output, "extraction.json"), "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
PYEOF

printf '✔ Metadatos extraídos de la imagen oficial (%s): %s\n' "$BASE_DISTRIBUTION" "$OUTPUT_DIR"
