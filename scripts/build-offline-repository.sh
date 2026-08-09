#!/usr/bin/env bash
# =============================================================================
# build-offline-repository.sh — Constructor del repositorio APT offline
#
# La cadena de confianza arranca en la imagen oficial verificada por hash: las
# fuentes y los keyrings salen de DENTRO de la imagen, nunca del host.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="${1:-${ROOT}/sigil-hardware/manifests/offline-package-contract.json}"
OUTPUT_DIR="${2:-${ROOT}/artifacts/bundles/offline-package-contract-repo}"
BASE_IMAGE_PATH="${3:-}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -f "$CONTRACT" ] || die "Contrato de paquetes no encontrado: ${CONTRACT}"
[ -n "$BASE_IMAGE_PATH" ] || die "Se requiere la imagen base: es el origen de la cadena de confianza.
  Uso: build-offline-repository.sh <contrato> <directorio-salida> <imagen-base>"
[ -f "$BASE_IMAGE_PATH" ] || die "Imagen base no encontrada: ${BASE_IMAGE_PATH}"

# APT interpreta como relativas a /etc/apt las rutas de configuración que no
# son absolutas, así que todo se canonicaliza antes de usarse.
CONTRACT="$(cd "$(dirname "$CONTRACT")" && pwd)/$(basename "$CONTRACT")"
BASE_IMAGE_PATH="$(cd "$(dirname "$BASE_IMAGE_PATH")" && pwd)/$(basename "$BASE_IMAGE_PATH")"
mkdir -p "$(dirname "$OUTPUT_DIR")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")"

# ── 1. AUTODETECTAR TOOLING ──────────────────────────────────────────────────
MISSING_TOOLS=0
for tool in apt-get dpkg-scanpackages apt-ftparchive dpkg-deb gpgv; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS=1
done

if [ "$MISSING_TOOLS" -eq 1 ] && [ "${SIGIL_IN_DOCKER_BUILD:-0}" != "1" ]; then
    printf '▶ Herramientas de empaquetado Debian ausentes: re-ejecutando dentro de debian:trixie\n'
    command -v docker >/dev/null || die "Se requiere Docker para construir sin herramientas Debian nativas.
  Instálelo con ./setup.sh o ejecute este script en un entorno Debian equivalente
  fijando SIGIL_IN_DOCKER_BUILD=1."
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
    IMAGE_DIR=$(cd "$(dirname "$BASE_IMAGE_PATH")" && pwd)
    # Si la imagen es un enlace, su destino real también tiene que ser visible
    # dentro del contenedor.
    IMAGE_REAL_DIR=$(dirname "$(readlink -f "$BASE_IMAGE_PATH")")
    exec docker run --rm \
        -v "${ROOT}:${ROOT}" \
        -v "${IMAGE_DIR}:${IMAGE_DIR}" \
        -v "${IMAGE_REAL_DIR}:${IMAGE_REAL_DIR}" \
        -w "${ROOT}" \
        -e SIGIL_IN_DOCKER_BUILD=1 \
        -e "SIGIL_APT_MIRROR=${SIGIL_APT_MIRROR:-}" \
        -e "SIGIL_PACKAGE_PROFILES=${SIGIL_PACKAGE_PROFILES:-}" \
        -e DEBIAN_FRONTEND=noninteractive \
        debian:trixie \
        bash -c "apt-get update -qq && apt-get install -y --no-install-recommends \
                   apt-utils dpkg-dev gnupg python3 xz-utils fdisk e2fsprogs ca-certificates >/dev/null 2>&1 && \
                 setpriv --reuid=${HOST_UID} --regid=${HOST_GID} --clear-groups \
                   bash '${ROOT}/scripts/build-offline-repository.sh' '${CONTRACT}' '${OUTPUT_DIR}' '${BASE_IMAGE_PATH}'"
fi
printf '▶ Construyendo con las herramientas Debian del entorno actual\n'

# ── 2. VALIDAR EL CONTRATO ENTERO ANTES DE TOCAR LA RED ──────────────────────
eval "$(python3 - "$CONTRACT" <<'PYEOF'
import json, os, shlex, sys

contract = json.load(open(sys.argv[1]))
required = [
    "schema_version", "bundle_version", "distribution", "distribution_version",
    "distribution_codename", "architecture", "base_image_name", "base_image_sha256",
    "packages",
]
missing = [field for field in required if field not in contract]
if missing:
    raise SystemExit("el contrato no declara: " + ", ".join(missing))

packages = contract["packages"]
if not isinstance(packages, list) or not packages:
    raise SystemExit("el contrato no declara ningún paquete")
for package in packages:
    if "name" not in package or "required" not in package or "profile" not in package:
        raise SystemExit(f"paquete mal formado en el contrato: {package}")

required_names = [p["name"] for p in packages if p["required"]]

# Los paquetes de perfil (factory-debug, optional) no son obligatorios y por eso
# NO entran en `direct_packages`: el instalador exige que esa lista sea
# exactamente la de los obligatorios. Lo que sí comprueba es que existan entre
# los paquetes resueltos del repositorio, así que hay que descargarlos igual.
# Sin esto, activar el acceso remoto aborta el instalador dentro del chroot con
# la tarjeta ya escrita entera.
requested_profiles = {p for p in os.environ.get("SIGIL_PACKAGE_PROFILES", "").split(",") if p}
unknown_profiles = requested_profiles - {"factory-debug", "optional"}
if unknown_profiles:
    raise SystemExit("perfil de paquetes no soportado: " + ", ".join(sorted(unknown_profiles)))
profile_names = [
    p["name"] for p in packages
    if not p["required"] and p["profile"] in requested_profiles
]

values = {
    "BUNDLE_VERSION": contract["bundle_version"],
    "ARCH": contract["architecture"],
    "DISTRO": contract["distribution"],
    "DISTRO_VERSION": contract["distribution_version"],
    "CODENAME": contract["distribution_codename"],
    "BASE_IMAGE_NAME": contract["base_image_name"],
    "BASE_IMAGE_SHA": contract["base_image_sha256"],
    "REQUIRED_PACKAGES": " ".join(required_names),
    "REQUIRED_COUNT": str(len(required_names)),
    "PROFILE_PACKAGES": " ".join(profile_names),
    "PROFILE_COUNT": str(len(profile_names)),
    "SELECTED_PROFILES": ",".join(sorted(requested_profiles)),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PYEOF
)"

printf '▶ Contrato validado: %s %s (%s), %s paquetes obligatorios\n' \
    "$DISTRO" "$CODENAME" "$ARCH" "$REQUIRED_COUNT"
if [ "$PROFILE_COUNT" -gt 0 ]; then
    printf '▶ Perfiles seleccionados (%s): %s paquetes adicionales — %s\n' \
        "$SELECTED_PROFILES" "$PROFILE_COUNT" "$PROFILE_PACKAGES"
fi

if [ "$(basename "$BASE_IMAGE_PATH")" != "$BASE_IMAGE_NAME" ]; then
    die "La imagen entregada se llama '$(basename "$BASE_IMAGE_PATH")' pero el contrato exige '${BASE_IMAGE_NAME}'"
fi

# El trabajo intermedio (rootfs extraído y paquetes) ronda varios GB: vive en
# disco junto a la salida, no en un /tmp montado en memoria.
mkdir -p "$(dirname "$OUTPUT_DIR")"
WORK_DIR=$(mktemp -d "$(dirname "$OUTPUT_DIR")/.sigil-build.XXXXXX")
BACKUP_DIR=""
BUILD_OK=0

cleanup() {
    rm -rf -- "$WORK_DIR"
    # 12. Restauración automática si algo falló a mitad del reemplazo.
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        if [ "$BUILD_OK" -eq 1 ]; then
            rm -rf -- "$BACKUP_DIR"
        else
            printf '▶ Restaurando el repositorio anterior tras un fallo...\n' >&2
            rm -rf -- "$OUTPUT_DIR"
            mv -- "$BACKUP_DIR" "$OUTPUT_DIR"
        fi
    fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$WORK_DIR/repo/packages" "$WORK_DIR/repo/sources-snapshot/keyrings"
REPO="$WORK_DIR/repo"

# ── 3. EXTRAER LOS METADATOS DE LA IMAGEN OFICIAL ────────────────────────────
META_DIR="$WORK_DIR/image-metadata"
bash "${ROOT}/scripts/extract-official-apt-metadata.sh" "$BASE_IMAGE_PATH" "$META_DIR" "$CONTRACT"

BASE_DISTRIBUTION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_distribution"])' "$META_DIR/extraction.json")
if [ "$BASE_DISTRIBUTION" != "$DISTRO" ]; then
    die "La imagen trae fuentes firmadas de '${BASE_DISTRIBUTION}' pero el contrato declara '${DISTRO}'.
  Este control cruzado es deliberado: corrija el contrato o use la imagen correcta."
fi

IMAGE_CODENAME=$(grep -E '^VERSION_CODENAME=' "$META_DIR/os-release" | cut -d= -f2 | tr -d '"' || true)
if [ -n "$IMAGE_CODENAME" ] && [ "$IMAGE_CODENAME" != "$CODENAME" ]; then
    die "El os-release de la imagen dice '${IMAGE_CODENAME}' y el contrato '${CODENAME}'.
  Consulte docs/architecture-upgrade.md: hay que cambiar varios archivos a la vez."
fi

# ── Estado APT completamente aislado, con base de datos dpkg VACÍA ───────────
APT_STATE="$WORK_DIR/apt-state"
mkdir -p "$APT_STATE/lists/partial" "$APT_STATE/cache/archives/partial" \
         "$APT_STATE/etc/apt/sources.list.d" "$APT_STATE/etc/apt/preferences.d" \
         "$APT_STATE/etc/apt/trusted.gpg.d"
: > "$APT_STATE/dpkg-status"
: > "$APT_STATE/etc/apt/empty.list"
: > "$APT_STATE/etc/apt/empty.gpg"

# Los keyrings extraídos de la imagen son los ÚNICOS que autentican las firmas.
cp "$META_DIR"/keyrings/*.gpg "$APT_STATE/etc/apt/trusted.gpg.d/"
cp "$META_DIR"/keyrings/*.gpg "$REPO/sources-snapshot/keyrings/"
cp -r "$META_DIR/sources" "$REPO/sources-snapshot/"
cp "$META_DIR/os-release" "$REPO/sources-snapshot/os-release"

# Se copian las fuentes tal cual las trae la imagen. Signed-By se elimina
# porque los keyrings viven ahora en trusted.gpg.d del estado aislado: la firma
# se sigue verificando contra el mismo material extraído de la imagen.
python3 - "$META_DIR" "$APT_STATE/etc/apt/sources.list.d" "${SIGIL_APT_MIRROR:-}" <<'PYEOF'
import json, os, re, sys

meta_dir, destination, mirror = sys.argv[1], sys.argv[2], sys.argv[3]
summary = json.load(open(os.path.join(meta_dir, "extraction.json")))

for key in ("base_sources", "raspi_sources"):
    source_path = os.path.join(meta_dir, summary[key])
    text = open(source_path, encoding="utf-8", errors="replace").read()

    lines = [line for line in text.splitlines()
             if not line.strip().lower().startswith("signed-by:")]
    text = "\n".join(lines) + "\n"

    # 4. Espejo documentado: sustituye SOLO el URI, nunca la firma.
    if mirror and key == "base_sources":
        text = re.sub(r"https?://[^\s]+", mirror.rstrip("/"), text)

    name = os.path.basename(summary[key])
    with open(os.path.join(destination, name), "w", encoding="utf-8") as handle:
        handle.write(text)
PYEOF

[ -z "${SIGIL_APT_MIRROR:-}" ] || printf '▶ Espejo APT en uso para el archivo base: %s\n' "$SIGIL_APT_MIRROR"

APT_OPT=(
    -o "Dir::State=${APT_STATE}"
    -o "Dir::State::status=${APT_STATE}/dpkg-status"
    -o "Dir::Cache=${APT_STATE}/cache"
    -o "Dir::Etc::sourcelist=${APT_STATE}/etc/apt/empty.list"
    -o "Dir::Etc::sourceparts=${APT_STATE}/etc/apt/sources.list.d"
    -o "Dir::Etc::preferencesparts=${APT_STATE}/etc/apt/preferences.d"
    -o "Dir::Etc::trusted=${APT_STATE}/etc/apt/empty.gpg"
    -o "Dir::Etc::trustedparts=${APT_STATE}/etc/apt/trusted.gpg.d"
    -o "Acquire::Languages=none"
    -o "Acquire::IndexTargets::deb::DEP-11::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::CNF::DefaultEnabled=false"
    -o "APT::Install-Recommends=false"
    -o "APT::Install-Suggests=false"
    -o "APT::Architecture=${ARCH}"
    -o "APT::Architectures::=${ARCH}"
    -o "APT::Get::AllowUnauthenticated=false"
)

# ── 5. RESOLVER EL CIERRE TRANSITIVO ─────────────────────────────────────────
printf '▶ Actualizando índices APT aislados (arquitectura %s)...\n' "$ARCH"
apt-get "${APT_OPT[@]}" update || die "No se pudieron descargar los índices APT.
  Revise la conectividad o fije un espejo con SIGIL_APT_MIRROR."

printf '▶ Descargando el cierre transitivo de %s paquetes obligatorios...\n' "$REQUIRED_COUNT"
# shellcheck disable=SC2086
apt-get "${APT_OPT[@]}" --download-only --reinstall install -y $REQUIRED_PACKAGES \
    || die "APT no pudo resolver el cierre de dependencias del contrato"

# Los de perfil van en una pasada aparte: si uno de ellos no resolviera, el
# mensaje tiene que señalar al perfil y no al contrato obligatorio.
if [ "$PROFILE_COUNT" -gt 0 ]; then
    printf '▶ Descargando el cierre transitivo de %s paquetes de perfil (%s)...\n' \
        "$PROFILE_COUNT" "$SELECTED_PROFILES"
    # shellcheck disable=SC2086
    apt-get "${APT_OPT[@]}" --download-only --reinstall install -y $PROFILE_PACKAGES \
        || die "APT no pudo resolver las dependencias de los paquetes de perfil: ${PROFILE_PACKAGES}"
fi

find "$APT_STATE/cache/archives" -name '*.deb' -exec cp -f {} "$REPO/packages/" \;
DEB_COUNT=$(find "$REPO/packages" -name '*.deb' | wc -l)
[ "$DEB_COUNT" -gt 0 ] || die "No se descargó ningún paquete: el bundle quedaría vacío"
printf '▶ %s paquetes descargados\n' "$DEB_COUNT"

# ── 6. VERIFICAR LA ARQUITECTURA REAL DE CADA PAQUETE ────────────────────────
for deb in "$REPO/packages"/*.deb; do
    deb_arch=$(dpkg-deb -f "$deb" Architecture)
    if [ "$deb_arch" != "$ARCH" ] && [ "$deb_arch" != "all" ]; then
        die "Paquete con arquitectura no permitida: $(basename "$deb") (${deb_arch})"
    fi
done

# ── 7. GENERAR ÍNDICES ───────────────────────────────────────────────────────
cd "$REPO"
dpkg-scanpackages --multiversion packages /dev/null > Packages
gzip -n -9 -c Packages > Packages.gz

apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=SIGIL" \
    -o "APT::FTPArchive::Release::Label=SIGIL Offline Repository" \
    -o "APT::FTPArchive::Release::Suite=${CODENAME}" \
    -o "APT::FTPArchive::Release::Codename=${CODENAME}" \
    -o "APT::FTPArchive::Release::Architectures=${ARCH}" \
    -o "APT::FTPArchive::Release::Components=main" \
    -o "APT::FTPArchive::Release::Description=Repositorio APT offline autocontenido para SIGIL OS" \
    release . > Release

# ── 8. SIN FIRMA DEL REPOSITORIO LOCAL ───────────────────────────────────────
# El repositorio local no se firma. Su integridad la garantizan checksums.sha256
# sobre el conjunto exacto de artefactos y, paquete a paquete, el tamaño, el
# SHA-256 y los metadatos de control leídos del propio .deb. La autenticidad de
# lo DESCARGADO sigue verificándose con los keyrings extraídos de la imagen
# oficial: esa es la cadena de confianza que importa.

# ── 10. MANIFIESTO CON PROCEDENCIA COMPLETA ──────────────────────────────────
CONTRACT_HASH=$(sha256sum "$CONTRACT" | awk '{print $1}')
GIT_COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

python3 - "$REPO" "$CONTRACT" "$CONTRACT_HASH" "$GIT_COMMIT" "$BASE_DISTRIBUTION" <<'PYEOF'
import hashlib, json, pathlib, subprocess, sys, time

repo, contract_path, contract_hash, git_commit, base_distribution = sys.argv[1:6]
repo = pathlib.Path(repo)
contract = json.load(open(contract_path))

def field(deb, name):
    return subprocess.run(["dpkg-deb", "-f", str(deb), name],
                          capture_output=True, text=True, check=True).stdout.strip()

packages, total_bytes = [], 0
for deb in sorted((repo / "packages").glob("*.deb")):
    data = deb.read_bytes()
    total_bytes += len(data)
    packages.append({
        "name": field(deb, "Package"),
        "version": field(deb, "Version"),
        "architecture": field(deb, "Architecture"),
        "filename": f"packages/{deb.name}",
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    })

direct = [p["name"] for p in contract["packages"] if p["required"]]
resolved = {p["name"] for p in packages}
unresolved = sorted(set(direct) - resolved)

manifest = {
    "schema_version": "2.0",
    "repository_type": "offline-apt",
    "package_contract_schema_version": contract["schema_version"],
    "bundle_version": contract["bundle_version"],
    "package_contract_sha256": contract_hash,
    "source_sigil_hardware_commit": git_commit,
    "base_image_name": contract["base_image_name"],
    "base_image_sha256": contract["base_image_sha256"],
    "distribution": contract["distribution"],
    "distribution_version": contract["distribution_version"],
    "distribution_codename": contract["distribution_codename"],
    "architecture": contract["architecture"],
    "generation_timestamp": int(time.time()),
    "direct_packages": direct,
    "direct_package_count": len(direct),
    "resolved_package_count": len(packages),
    "total_bytes": total_bytes,
    "unresolved_packages": unresolved,
    "sources": [{
        "uri": "extraída de la imagen oficial",
        "distribution": contract["distribution_codename"],
        "component": "main",
        "base_distribution": base_distribution,
    }],
    # Sin firma local: solo viajan los keyrings extraídos de la imagen.
    "keyrings": [],
    "python_dependencies": {
        "wheels": [],
        "fully_satisfied_by_debian_packages": {
            "flask": "python3-flask",
            "argon2": "python3-argon2",
        },
    },
    "packages": packages,
}

if unresolved:
    raise SystemExit("paquetes obligatorios sin resolver: " + ", ".join(unresolved))

(repo / "package-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
PYEOF

# ── 11. CHECKSUMS QUE CUBREN EXACTAMENTE LOS ARTEFACTOS ──────────────────────
python3 - "$REPO" <<'PYEOF'
import hashlib, pathlib, sys

root = pathlib.Path(sys.argv[1])
lines = []
for item in sorted(root.rglob("*")):
    if item.is_file() and item.name != "checksums.sha256":
        digest = hashlib.sha256(item.read_bytes()).hexdigest()
        lines.append(f"{digest}  {item.relative_to(root).as_posix()}")
(root / "checksums.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")
PYEOF

# ── 9. DEMOSTRAR EL CIERRE EN SIMULACIÓN ─────────────────────────────────────
# Se reinstala DESDE el repositorio recién creado, sin descargar, con una base
# de datos dpkg vacía. Nunca se instala ni se ejecuta un paquete de otra
# arquitectura en el host: la operación es puramente de resolución.
printf '▶ Demostrando el cierre de dependencias en simulación...\n'
CLOSURE_STATE="$WORK_DIR/closure-state"
mkdir -p "$CLOSURE_STATE/lists/partial" "$CLOSURE_STATE/cache/archives/partial" \
         "$CLOSURE_STATE/etc/apt/sources.list.d" "$CLOSURE_STATE/etc/apt/trusted.gpg.d"
: > "$CLOSURE_STATE/dpkg-status"
: > "$CLOSURE_STATE/etc/apt/empty.list"
: > "$CLOSURE_STATE/etc/apt/empty.gpg"
# trusted=yes: el repositorio local no lleva firma, así que APT no puede
# autenticarlo. La integridad se comprueba por hash, no por firma.
printf 'deb [trusted=yes] file:%s ./\n' "$REPO" \
    > "$CLOSURE_STATE/etc/apt/sources.list.d/sigil-offline.list"

CLOSURE_OPT=(
    -o "Dir::State=${CLOSURE_STATE}"
    -o "Dir::State::status=${CLOSURE_STATE}/dpkg-status"
    -o "Dir::Cache=${CLOSURE_STATE}/cache"
    -o "Dir::Etc::sourcelist=${CLOSURE_STATE}/etc/apt/empty.list"
    -o "Dir::Etc::sourceparts=${CLOSURE_STATE}/etc/apt/sources.list.d"
    -o "Dir::Etc::trusted=${CLOSURE_STATE}/etc/apt/empty.gpg"
    -o "Dir::Etc::trustedparts=${CLOSURE_STATE}/etc/apt/trusted.gpg.d"
    -o "Acquire::Languages=none"
    -o "APT::Install-Recommends=false"
    -o "APT::Architecture=${ARCH}"
    -o "APT::Architectures::=${ARCH}"
)

apt-get "${CLOSURE_OPT[@]}" update >/dev/null \
    || die "El repositorio generado no se puede leer"

# shellcheck disable=SC2086
apt-get "${CLOSURE_OPT[@]}" --simulate --no-download --fix-missing=false \
    install $REQUIRED_PACKAGES >/dev/null \
    || die "El bundle no se autosatisface: faltan dependencias para instalarlo sin red"
printf '▶ Cierre demostrado: el bundle se instala sin descargar nada\n'

# El validador completo de sigil-hardware comprueba además que la arquitectura
# de dpkg coincida con el contrato, así que solo puede correr en un host de la
# misma arquitectura. Dentro de la imagen se ejecuta siempre durante el flasheo.
HOST_DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo desconocida)
if [ "$HOST_DPKG_ARCH" = "$ARCH" ]; then
    printf '▶ Ejecutando el validador completo de sigil-hardware...\n'
    SIGIL_PACKAGE_CONTRACT="$CONTRACT" \
    SIGIL_OFFLINE_INSTALL_TEST_MODE=1 \
        bash "$ROOT/sigil-hardware/scripts/install-offline-packages.sh" "$REPO" \
        || die "El repositorio no supera las validaciones de install-offline-packages.sh"
else
    printf '▶ Validador completo omitido: el host es %s y el contrato %s.\n' "$HOST_DPKG_ARCH" "$ARCH"
    printf '  Se ejecuta dentro de la imagen durante el flasheo, donde dpkg sí es %s.\n' "$ARCH"
fi

# ── 12. REEMPLAZO ATÓMICO CON RESPALDO ───────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT_DIR")"
if [ -d "$OUTPUT_DIR" ]; then
    BACKUP_DIR="${OUTPUT_DIR}.bak.$$"
    mv -- "$OUTPUT_DIR" "$BACKUP_DIR"
fi

# El staging vive en el mismo sistema de archivos que el destino, así el
# rename final es atómico.
STAGING="${OUTPUT_DIR}.new.$$"
rm -rf -- "$STAGING"
cp -a "$REPO" "$STAGING"
mv -- "$STAGING" "$OUTPUT_DIR"
BUILD_OK=1

printf '✔ Repositorio APT offline construido en: %s\n' "$OUTPUT_DIR"
