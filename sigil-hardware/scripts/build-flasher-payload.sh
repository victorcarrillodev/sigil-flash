#!/bin/bash
# Build a minimal, integrity-manifested payload for flasher-rs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTION="${ROOT}/manifests/flasher-payload-files.txt"
DEFAULT_ARTIFACTS="$(cd "${ROOT}/.." && pwd)/artifacts"
OUTPUT="${1:-${DEFAULT_ARTIFACTS}/payloads/sigil-hardware-payload}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -f "$SELECTION" ] || die "payload selection manifest is missing: ${SELECTION}"
[ ! -e "$OUTPUT" ] || die "refusing to replace existing payload: ${OUTPUT}"

declare -a FILES=()
while IFS= read -r relative || [ -n "$relative" ]; do
    relative="${relative%$'\r'}"
    case "$relative" in
        ''|'#'*) continue ;;
        /*|*'..'*|*\\*) die "unsafe payload selection path: ${relative}" ;;
    esac
    [ -f "${ROOT}/${relative}" ] || die "selected payload file is missing: ${relative}"
    [ ! -L "${ROOT}/${relative}" ] || die "payload symlinks are not allowed: ${relative}"
    if [ "${SIGIL_PAYLOAD_ALLOW_DIRTY:-false}" != "true" ]; then
        git -C "$ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
            || die "selected payload file is not tracked: ${relative}"
    fi
    FILES+=("$relative")
done < "$SELECTION"

[ "${#FILES[@]}" -gt 0 ] || die "payload selection is empty"

if [ "${SIGIL_PAYLOAD_ALLOW_DIRTY:-false}" != "true" ] \
    && ! git -C "$ROOT" diff --quiet -- "${FILES[@]}"; then
    die "selected production payload files have uncommitted changes"
fi

SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
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
    mode=$(stat -c '%a' "${ROOT}/${relative}")
    install -D -m "$mode" "${ROOT}/${relative}" "${TEMP}/${relative}"
done

python3 - "$TEMP" "$SOURCE_COMMIT" <<'PYEOF'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

root = pathlib.Path(sys.argv[1])
source_commit = sys.argv[2]
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

manifest = {
    "_schema_version": "1.0",
    "payload_type": "sigil-hardware-install",
    "source_commit": source_commit,
    "target": {
        "os": "raspberry-pi-os-lite",
        "release": "trixie",
        "architecture": "arm64",
        "hardware": "raspberry-pi-zero-2-w",
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
