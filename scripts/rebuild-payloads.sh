#!/bin/bash
# Regenerate every sigil-hardware payload variant from the current source
# tree. Payloads are point-in-time snapshots (build-flasher-payload.sh copies
# files, it does not link them), so any change under sigil-hardware/ goes
# stale in artifacts/payloads/ until this runs again. Run this after every
# commit that touches sigil-hardware/ and before flashing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_BUILDER="${ROOT}/sigil-hardware/scripts/build-flasher-payload.sh"
MANIFESTS_DIR="${ROOT}/sigil-hardware/manifests"
PAYLOADS_DIR="${ROOT}/artifacts/payloads"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -x "$PAYLOAD_BUILDER" ] || die "payload builder is missing: ${PAYLOAD_BUILDER}"

rebuild() {
    local name="$1" contract="$2"
    local output="${PAYLOADS_DIR}/${name}"
    printf '\n== Rebuilding %s (contract: %s) ==\n' "$name" "$(basename "$contract")"
    rm -rf -- "$output"
    bash "$PAYLOAD_BUILDER" --contract "$contract" "$output"
}

# The canonical contract (offline-package-contract.json) always builds
# sigil-hardware-payload. Any sibling offline-package-contract.<variant>.json
# (e.g. .armhf.json) builds sigil-hardware-payload-<variant> -- drop a new
# contract file in to add an architecture, no script changes needed.
rebuild "sigil-hardware-payload" "${MANIFESTS_DIR}/offline-package-contract.json"

shopt -s nullglob
for contract in "${MANIFESTS_DIR}"/offline-package-contract.*.json; do
    variant="$(basename "$contract")"
    variant="${variant#offline-package-contract.}"
    variant="${variant%.json}"
    rebuild "sigil-hardware-payload-${variant}" "$contract"
done
shopt -u nullglob

SOURCE_COMMIT="$(git -C "${ROOT}/sigil-hardware" rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf '\nAll payloads rebuilt from commit %s.\n' "$SOURCE_COMMIT"
if ! git -C "$ROOT" diff --quiet -- sigil-hardware 2>/dev/null; then
    printf 'Warning: sigil-hardware/ has uncommitted changes -- rebuilt payloads embed working-tree content, not %s.\n' "$SOURCE_COMMIT"
fi
