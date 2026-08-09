#!/usr/bin/env bash
# El repositorio construido debe superar TODAS las validaciones de
# sigil-hardware/scripts/install-offline-packages.sh.
#
# Ese validador exige que `dpkg --print-architecture` coincida con el contrato,
# porque está escrito para correr DENTRO de la imagen. En un PC de otra
# arquitectura se ejecuta en un contenedor emulado; si no hay emulación
# disponible, la suite lo dice y se salta en vez de dar un falso verde.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLES="${ROOT}/artifacts/bundles"

fail() { printf '  ✘ %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ✔ %s\n' "$*"; }
skip() { printf '  ○ %s\n' "$*"; }

if [ ! -d "$BUNDLES" ] || [ -z "$(ls -A "$BUNDLES" 2>/dev/null)" ]; then
    skip "No hay bundles construidos. Ejecute ./scripts/build-all-bundles.sh"
    exit 0
fi

HOST_ARCH=$(dpkg --print-architecture 2>/dev/null || echo desconocida)
VALIDATED=0

for repo in "$BUNDLES"/*-repo; do
    [ -d "$repo" ] || continue
    name=$(basename "$repo")
    contract_name="${name%-repo}"
    contract="${ROOT}/sigil-hardware/manifests/${contract_name}.json"
    [ -f "$contract" ] || fail "${name}: no existe su contrato ${contract_name}.json"

    arch=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["architecture"])' "$contract")
    distribution=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["distribution"])' "$contract")

    # El manifiesto debe emparejar con el contrato antes de nada.
    python3 - "$repo" "$contract" <<'PYEOF'
import hashlib, json, pathlib, sys
repo, contract_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
manifest = json.loads((repo / "package-manifest.json").read_text(encoding="utf-8"))
contract = json.loads(contract_path.read_text(encoding="utf-8"))

for field in ("bundle_version", "base_image_name", "base_image_sha256", "distribution",
              "distribution_version", "distribution_codename", "architecture"):
    if manifest[field] != contract[field]:
        raise SystemExit(f"{repo.name}: {field} no coincide con el contrato")

if manifest["package_contract_sha256"] != hashlib.sha256(contract_path.read_bytes()).hexdigest():
    raise SystemExit(f"{repo.name}: el bundle se generó desde otro contrato")
if manifest["unresolved_packages"]:
    raise SystemExit(f"{repo.name}: hay paquetes sin resolver")
PYEOF

    # Un bundle construido con reglas antiguas puede quedar con artefactos
    # huérfanos que el instalador ya no espera. El conjunto de checksums debe
    # coincidir EXACTAMENTE, así que esto rompería el flasheo en silencio.
    for orphan in Release.gpg InRelease sources-snapshot/keyrings/sigil-offline-repository.gpg; do
        [ ! -e "${repo}/${orphan}" ] \
            || fail "${name}: artefacto huérfano de firma '${orphan}'. Reconstruya el bundle."
    done
    python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
if m['keyrings']:
    raise SystemExit(sys.argv[2]+': el manifiesto declara keyrings de firma que ya no se generan')
" "${repo}/package-manifest.json" "$name" || fail "${name}: manifiesto desincronizado"
    ok "${name}: sin artefactos de firma huérfanos"

    if [ "$HOST_ARCH" = "$arch" ]; then
        SIGIL_PACKAGE_CONTRACT="$contract" SIGIL_OFFLINE_INSTALL_TEST_MODE=1 \
            bash "${ROOT}/sigil-hardware/scripts/install-offline-packages.sh" "$repo" >/dev/null \
            || fail "${name}: no supera install-offline-packages.sh"
        ok "${name}: supera install-offline-packages.sh (nativo ${arch})"
        VALIDATED=1
    elif [ "$distribution" != "debian" ]; then
        # El validador termina haciendo un `apt-get install` real contra la base
        # de datos dpkg del sistema donde corre. Para un bundle de Raspbian eso
        # exige una base Raspbian: en un contenedor Debian los paquetes +rpiN
        # chocan con los de Debian y el fallo sería del entorno, no del bundle.
        # No hay imagen oficial de contenedor de Raspbian trixie, así que esta
        # comprobación ocurre dentro de la imagen durante el flasheo.
        skip "${name}: validador completo omitido (base ${distribution}, sin contenedor equivalente)"
    elif command -v docker >/dev/null && [ -e "/proc/sys/fs/binfmt_misc/qemu-aarch64" ]; then
        docker run --rm --platform "linux/${arch}" \
            -e DEBIAN_FRONTEND=noninteractive \
            -e SIGIL_OFFLINE_INSTALL_TEST_MODE=1 \
            -e "SIGIL_PACKAGE_CONTRACT=${contract}" \
            -v "${ROOT}:${ROOT}" -w "${ROOT}" \
            debian:trixie \
            bash -c "apt-get update -qq >/dev/null 2>&1 && \
                     apt-get install -y --no-install-recommends python3 dpkg-dev >/dev/null 2>&1 && \
                     bash '${ROOT}/sigil-hardware/scripts/install-offline-packages.sh' '${repo}'" \
            >/dev/null || fail "${name}: no supera install-offline-packages.sh bajo emulación ${arch}"
        ok "${name}: supera install-offline-packages.sh (emulado ${arch})"
        VALIDATED=1
    else
        skip "${name}: validador omitido (host ${HOST_ARCH}, contrato ${arch}, sin emulación)"
    fi
done

[ "$VALIDATED" -eq 1 ] || skip "Ningún bundle pudo validarse con el instalador real en este PC"
