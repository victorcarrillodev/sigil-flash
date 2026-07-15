#!/bin/bash
# Extract authenticated APT source definitions and archive keyrings from a verified image.
set -euo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || die "usage: $(basename "$0") <contract.json> <base-image.img[.xz]> <destination>"
CONTRACT="$1"
BASE_IMAGE="$2"
DESTINATION="$3"

for command in python3 sha256sum xz sfdisk dd debugfs gpg; do
    command -v "$command" >/dev/null || die "required command is unavailable: ${command}"
done
[ -f "$CONTRACT" ] || die "package contract is missing: ${CONTRACT}"
[ -f "$BASE_IMAGE" ] || die "official base image is missing: ${BASE_IMAGE}"

mapfile -t IMAGE_CONTRACT < <(python3 - "$CONTRACT" <<'PYEOF'
import json, pathlib, re, sys
contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
name = contract.get("base_image_name")
digest = contract.get("base_image_sha256")
if not isinstance(name, str) or not name:
    raise SystemExit("contract base_image_name is missing")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("contract base_image_sha256 is invalid")
print(name)
print(digest)
print(contract.get("distribution", ""))
print(contract.get("distribution_version", ""))
print(contract.get("distribution_codename", ""))
print(contract.get("architecture", ""))
PYEOF
)
[ "${#IMAGE_CONTRACT[@]}" -eq 6 ] || die "could not read base-image contract"

EXPECTED_NAME="${IMAGE_CONTRACT[0]}"
EXPECTED_SHA256="${IMAGE_CONTRACT[1]}"
[ "$(basename "$BASE_IMAGE")" = "$EXPECTED_NAME" ] \
    || die "base image filename mismatch: expected ${EXPECTED_NAME}"
ACTUAL_SHA256=$(sha256sum "$BASE_IMAGE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] \
    || die "base image SHA-256 mismatch: expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}"

WORK=$(mktemp -d /tmp/sigil-image-apt-metadata.XXXXXX)
cleanup() {
    rm -rf -- "$WORK"
}
trap cleanup EXIT HUP INT TERM

RAW_IMAGE="${WORK}/base.img"
if [[ "$BASE_IMAGE" == *.xz ]]; then
    xz -d -c -- "$BASE_IMAGE" > "$RAW_IMAGE"
else
    cp -- "$BASE_IMAGE" "$RAW_IMAGE"
fi

mapfile -t PARTITION < <(sfdisk --json "$RAW_IMAGE" | python3 -c '
import json, sys
table = json.load(sys.stdin)["partitiontable"]
sector_size = int(table.get("sectorsize", 512))
linux = [part for part in table["partitions"] if str(part.get("type", "")).lower() in {"83", "0x83"}]
if len(linux) != 1:
    raise SystemExit(f"expected exactly one Linux root partition, found {len(linux)}")
part = linux[0]
print(int(part["start"]) * sector_size)
print(int(part["size"]) * sector_size)
')
[ "${#PARTITION[@]}" -eq 2 ] || die "could not identify the official root partition"

ROOTFS="${WORK}/rootfs.ext4"
dd if="$RAW_IMAGE" of="$ROOTFS" bs=4M iflag=skip_bytes,count_bytes \
    skip="${PARTITION[0]}" count="${PARTITION[1]}" status=none

EXTRACTED="${WORK}/snapshot"
mkdir -p "$EXTRACTED/keyrings"
extract_file() {
    local source="$1"
    local destination="$2"
    debugfs -R "dump -p ${source} ${destination}" "$ROOTFS" >/dev/null 2>&1
    [ -s "$destination" ] || die "official image file is missing or empty: ${source}"
}

extract_file /etc/apt/sources.list.d/debian.sources "$EXTRACTED/debian.sources"
extract_file /etc/apt/sources.list.d/raspi.sources "$EXTRACTED/raspi.sources"
extract_file /usr/share/keyrings/debian-archive-keyring.pgp \
    "$EXTRACTED/keyrings/debian-archive-keyring.pgp"
extract_file /usr/share/keyrings/raspberrypi-archive-keyring.pgp \
    "$EXTRACTED/keyrings/raspberrypi-archive-keyring.pgp"
extract_file /usr/lib/os-release "$EXTRACTED/os-release"
extract_file /var/lib/dpkg/status "$WORK/dpkg-status"

python3 - "$CONTRACT" "$BASE_IMAGE" "$EXTRACTED" "$WORK/dpkg-status" <<'PYEOF'
import hashlib
import json
import pathlib
import re
import subprocess
import sys

contract_path = pathlib.Path(sys.argv[1]).resolve()
base_image = pathlib.Path(sys.argv[2]).resolve()
snapshot = pathlib.Path(sys.argv[3]).resolve()
status_path = pathlib.Path(sys.argv[4])
contract = json.loads(contract_path.read_text(encoding="utf-8"))

os_release = {}
for line in (snapshot / "os-release").read_text(encoding="utf-8").splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        os_release[key] = value.strip().strip("\"'")
if (
    os_release.get("ID") != contract["distribution"]
    or os_release.get("VERSION_ID") != contract["distribution_version"]
    or os_release.get("VERSION_CODENAME") != contract["distribution_codename"]
):
    raise SystemExit("verified image distribution does not match package contract")

status = {}
for stanza in status_path.read_text(encoding="utf-8", errors="strict").split("\n\n"):
    fields = {}
    for line in stanza.splitlines():
        if ": " in line and not line.startswith((" ", "\t")):
            key, value = line.split(": ", 1)
            fields[key] = value
    if fields.get("Package"):
        status[fields["Package"]] = fields

source_expectations = {
    "debian.sources": {
        "signed_by": "/usr/share/keyrings/debian-archive-keyring.pgp",
        "uris": {"http://deb.debian.org/debian/", "http://deb.debian.org/debian-security/"},
        "scope": "Debian 13 Trixie and security archives",
    },
    "raspi.sources": {
        "signed_by": "/usr/share/keyrings/raspberrypi-archive-keyring.pgp",
        "uris": {"http://archive.raspberrypi.com/debian/"},
        "scope": "Raspberry Pi Trixie archive",
    },
}
sources = []
for filename, expectation in source_expectations.items():
    path = snapshot / filename
    text = path.read_text(encoding="utf-8")
    if re.search(r"(?i)(trusted\s*:\s*yes|allow-unauthenticated|allow-insecure)", text):
        raise SystemExit(f"unauthenticated APT setting in official source: {filename}")
    paragraphs = []
    for stanza in text.strip().split("\n\n"):
        fields = {}
        for line in stanza.splitlines():
            if ": " in line:
                key, value = line.split(": ", 1)
                fields[key] = value
        paragraphs.append(fields)
    uris = {uri for fields in paragraphs for uri in fields.get("URIs", "").split()}
    signed_by = {fields.get("Signed-By") for fields in paragraphs}
    suites = {suite for fields in paragraphs for suite in fields.get("Suites", "").split()}
    if uris != expectation["uris"] or signed_by != {expectation["signed_by"]}:
        raise SystemExit(f"unexpected official APT source contract: {filename}")
    if contract["distribution_codename"] not in " ".join(sorted(suites)):
        raise SystemExit(f"official source does not target contract codename: {filename}")
    sources.append({
        "file": filename,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "uris": sorted(uris),
        "effective_uris": sorted(uris),
        "suites": sorted(suites),
        "signed_by": expectation["signed_by"],
        "scope": expectation["scope"],
    })

keyring_specs = [
    (
        "debian-archive-keyring",
        "/usr/share/keyrings/debian-archive-keyring.pgp",
        "keyrings/debian-archive-keyring.pgp",
        "Debian 13 Trixie and security archives",
    ),
    (
        "raspberrypi-archive-keyring",
        "/usr/share/keyrings/raspberrypi-archive-keyring.pgp",
        "keyrings/raspberrypi-archive-keyring.pgp",
        "Raspberry Pi Trixie archive",
    ),
]
keyrings = []
for package_name, source_path, relative, scope in keyring_specs:
    package = status.get(package_name)
    if package is None or package.get("Status") != "install ok installed":
        raise SystemExit(f"official image does not contain installed {package_name}")
    path = snapshot / relative
    output = subprocess.run(
        ["gpg", "--batch", "--show-keys", "--with-colons", str(path)],
        check=True,
        text=True,
        capture_output=True,
    ).stdout
    fingerprints = sorted({
        fields[9]
        for line in output.splitlines()
        if (fields := line.split(":"))[0] == "fpr" and len(fields) > 9
    })
    if not fingerprints:
        raise SystemExit(f"no OpenPGP fingerprints found in {relative}")
    keyrings.append({
        "package": package_name,
        "package_version": package.get("Version"),
        "source_image": str(base_image),
        "source_path": source_path,
        "artifact_path": relative,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "fingerprints": fingerprints,
        "scope": scope,
    })

(snapshot / "sources-metadata.json").write_text(
    json.dumps({"sources": sources}, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
(snapshot / "keyring-metadata.json").write_text(
    json.dumps({"keyrings": keyrings}, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
(snapshot / "base-image-metadata.json").write_text(
    json.dumps({
        "filename": base_image.name,
        "sha256": hashlib.sha256(base_image.read_bytes()).hexdigest(),
        "distribution": contract["distribution"],
        "distribution_version": contract["distribution_version"],
        "distribution_codename": contract["distribution_codename"],
        "architecture": contract["architecture"],
    }, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYEOF

rm -rf -- "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
mv -- "$EXTRACTED" "$DESTINATION"
printf 'APT metadata extracted from verified image: %s\n' "$BASE_IMAGE"
python3 - "$DESTINATION/keyring-metadata.json" <<'PYEOF'
import json, pathlib, sys
metadata = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for keyring in metadata["keyrings"]:
    print(f"keyring: {keyring['artifact_path']} ({keyring['package']} {keyring['package_version']})")
    for fingerprint in keyring["fingerprints"]:
        print(f"  fingerprint: {fingerprint}")
PYEOF
