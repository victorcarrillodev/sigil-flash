#!/bin/bash
# Build a minimal, integrity-manifested payload for flasher-rs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTION="${ROOT}/manifests/flasher-payload-files.txt"
DEFAULT_ARTIFACTS="$(cd "${ROOT}/.." && pwd)/artifacts"
CONTRACT="${ROOT}/manifests/offline-package-contract.json"
OUTPUT=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        "Usage: $(basename "$0") [--contract <file>] [output_dir]" \
        "  --contract <file>   Package contract to embed (default: canonical arm64 contract)."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --contract) [ "$#" -ge 2 ] || die "missing --contract value"; CONTRACT="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown argument: $1" ;;
        *) [ -z "$OUTPUT" ] || die "unexpected argument: $1"; OUTPUT="$1"; shift ;;
    esac
done
OUTPUT="${OUTPUT:-${DEFAULT_ARTIFACTS}/payloads/sigil-hardware-payload}"

[ -f "$SELECTION" ] || die "payload selection manifest is missing: ${SELECTION}"
[ -f "$CONTRACT" ] || die "package contract is missing: ${CONTRACT}"
[ ! -e "$OUTPUT" ] || die "refusing to replace existing payload: ${OUTPUT}"

CONTRACT_RELATIVE="manifests/offline-package-contract.json"
CONTRACT_ABS="$(cd "$(dirname "$CONTRACT")" && pwd)/$(basename "$CONTRACT")"
CONTRACT_IS_OVERRIDE=true
[ "$CONTRACT_ABS" = "${ROOT}/${CONTRACT_RELATIVE}" ] && CONTRACT_IS_OVERRIDE=false
if $CONTRACT_IS_OVERRIDE; then
    case "$CONTRACT_ABS" in
        "${ROOT}/"*) CONTRACT_GIT_RELATIVE="${CONTRACT_ABS#"${ROOT}/"}" ;;
        *) die "--contract must live inside ${ROOT}" ;;
    esac
fi

declare -a FILES=()
declare -A SOURCE_OF=()
while IFS= read -r relative || [ -n "$relative" ]; do
    relative="${relative%$'\r'}"
    case "$relative" in
        ''|'#'*) continue ;;
        /*|*'..'*|*\\*) die "unsafe payload selection path: ${relative}" ;;
    esac
    if $CONTRACT_IS_OVERRIDE && [ "$relative" = "$CONTRACT_RELATIVE" ]; then
        source_abs="$CONTRACT_ABS"
        git_relative="$CONTRACT_GIT_RELATIVE"
    else
        source_abs="${ROOT}/${relative}"
        git_relative="$relative"
    fi
    [ -f "$source_abs" ] || die "selected payload file is missing: ${relative}"
    [ ! -L "$source_abs" ] || die "payload symlinks are not allowed: ${relative}"
    if [ "${SIGIL_PAYLOAD_ALLOW_DIRTY:-false}" != "true" ]; then
        git -C "$ROOT" ls-files --error-unmatch -- "$git_relative" >/dev/null 2>&1 \
            || die "selected payload file is not tracked: ${git_relative}"
    fi
    SOURCE_OF["$relative"]="$source_abs"
    FILES+=("$relative")
done < "$SELECTION"

[ "${#FILES[@]}" -gt 0 ] || die "payload selection is empty"

if [ "${SIGIL_PAYLOAD_ALLOW_DIRTY:-false}" != "true" ]; then
    declare -a GIT_CHECK_PATHS=()
    for relative in "${FILES[@]}"; do
        if $CONTRACT_IS_OVERRIDE && [ "$relative" = "$CONTRACT_RELATIVE" ]; then
            GIT_CHECK_PATHS+=("$CONTRACT_GIT_RELATIVE")
        else
            GIT_CHECK_PATHS+=("$relative")
        fi
    done
    git -C "$ROOT" diff --quiet -- "${GIT_CHECK_PATHS[@]}" \
        || die "selected production payload files have uncommitted changes"
fi

SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
SOURCE_DIRTY=false
if [ -n "$(git -C "$ROOT" status --porcelain -- "${FILES[@]}")" ]; then
    SOURCE_DIRTY=true
fi
PARENT=$(dirname "$OUTPUT")
NAME=$(basename "$OUTPUT")
mkdir -p "$PARENT"
TEMP=$(mktemp -d "${PARENT}/.${NAME}.tmp.XXXXXX")

cleanup() {
    if [ -n "${TEMP:-}" ] && [ -d "$TEMP" ]; then
        rm -rf -- "$TEMP"
    fi
}
trap cleanup EXIT HUP INT TERM

for relative in "${FILES[@]}"; do
    source_abs="${SOURCE_OF[$relative]}"
    mode=$(stat -c '%a' "$source_abs")
    install -D -m "$mode" "$source_abs" "${TEMP}/${relative}"
done

python3 - "$TEMP" "$SOURCE_COMMIT" "$SOURCE_DIRTY" <<'PYEOF'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

root = pathlib.Path(sys.argv[1])
source_commit = sys.argv[2]
source_dirty = sys.argv[3] == "true"
forbidden_parts = {
    ".git", ".pytest_cache", "__pycache__", "tests", "docs", "target", "artifacts"
}

files = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    relative = path.relative_to(root)
    if any(part in forbidden_parts for part in relative.parts):
        raise SystemExit(f"forbidden payload path: {relative}")
    if path.suffix == ".pyc" or path.name.endswith("~"):
        raise SystemExit(f"temporary/generated payload file: {relative}")
    data = path.read_bytes()
    if b"-----BEGIN PRIVATE KEY-----" in data:
        raise SystemExit(f"private key material detected in: {relative}")
    mode = stat.S_IMODE(path.stat().st_mode)
    files.append({
        "path": relative.as_posix(),
        "sha256": hashlib.sha256(data).hexdigest(),
        "mode": f"{mode:04o}",
    })

audio_config = root / "conf" / "audio.conf"
text = audio_config.read_text(encoding="utf-8")
match = re.search(r'^API_KEY\s*=\s*["\']?([^"\'\n]*)', text, re.MULTILINE)
if match and match.group(1).strip() not in {"", "<placeholder>"}:
    raise SystemExit("conf/audio.conf contains a non-placeholder API key")

embedded_contract = json.loads((root / "manifests" / "offline-package-contract.json").read_text(encoding="utf-8"))
contract_architecture = embedded_contract["architecture"]
hardware_by_architecture = {
    "arm64": "raspberry-pi-zero-2-w",
    "armhf": "raspberry-pi",
}
target_hardware = hardware_by_architecture.get(contract_architecture, "raspberry-pi")

manifest = {
    "_schema_version": "1.0",
    "payload_type": "sigil-hardware-install",
    "source_commit": source_commit,
    "source_dirty": source_dirty,
    "target": {
        "os": "raspberry-pi-os-lite",
        "release": "trixie",
        "architecture": contract_architecture,
        "hardware": target_hardware,
    },
    "files": files,
}
manifest_path = root / "payload-manifest.json"
with manifest_path.open("w", encoding="utf-8", newline="\n") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PYEOF

mv -- "$TEMP" "$OUTPUT"
TEMP=""
trap - EXIT HUP INT TERM
printf 'payload: %s\n' "$OUTPUT"
printf 'source commit: %s\n' "$SOURCE_COMMIT"
printf 'files: %d\n' "${#FILES[@]}"
