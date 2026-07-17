#!/bin/bash
# Build a signed, complete ARM64 APT repository for offline image manufacturing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="${ROOT}/sigil-hardware/manifests/offline-package-contract.json"
OUTPUT="${ROOT}/artifacts/offline-packages/trixie-arm64"
BASE_IMAGE="${SIGIL_BASE_IMAGE:-}"
KEYRING_HELPER="${ROOT}/scripts/extract-official-apt-metadata.sh"
REBUILD=false
APT_GET="${APT_GET:-apt-get}"
DPKG_SCANPACKAGES="${DPKG_SCANPACKAGES:-dpkg-scanpackages}"
SIGNING_HOME="${SIGIL_OFFLINE_SIGNING_HOME:-${ROOT}/artifacts/offline-packages/.signing-gnupg}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        "Usage: $(basename "$0") [options]" \
        "  --contract <file>       Canonical sigil-hardware package contract" \
        "  --base-image <file>     Verified official Raspberry Pi OS image" \
        "  --output <directory>    Bundle destination" \
        "  --rebuild               Atomically replace an existing bundle"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --contract) [ "$#" -ge 2 ] || die "missing --contract value"; CONTRACT="$2"; shift 2 ;;
        --base-image) [ "$#" -ge 2 ] || die "missing --base-image value"; BASE_IMAGE="$2"; shift 2 ;;
        --output) [ "$#" -ge 2 ] || die "missing --output value"; OUTPUT="$2"; shift 2 ;;
        --rebuild) REBUILD=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -f "$CONTRACT" ] || die "canonical package contract is missing: ${CONTRACT}"
[ -x "$KEYRING_HELPER" ] || die "official-image keyring helper is missing: ${KEYRING_HELPER}"
for command in "$APT_GET" "$DPKG_SCANPACKAGES" dpkg-deb apt-ftparchive gpg gzip python3; do
    command -v "$command" >/dev/null || die "required command is unavailable: ${command}"
done

mapfile -t CONTRACT_VALUES < <(python3 - "$CONTRACT" <<'PYEOF'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
try:
    contract = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid package contract: {error}")

expected = {
    "schema_version", "bundle_version", "distribution", "distribution_version",
    "distribution_codename", "architecture", "allowed_package_architectures",
    "base_image_name", "base_image_sha256", "install_recommends",
    "version_policy", "packages",
}
if set(contract) != expected:
    raise SystemExit("package contract has missing or unknown fields")
if contract["schema_version"] != "2.0":
    raise SystemExit("unsupported package contract schema")
if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*", contract["bundle_version"]):
    raise SystemExit("bundle_version must be YYYY.MM.DD.N")
if (
    contract["distribution"] != "debian"
    or contract["distribution_version"] != "13"
    or contract["distribution_codename"] != "trixie"
    or contract["architecture"] != "arm64"
):
    raise SystemExit("only the Debian 13 Trixie ARM64 contract is supported")
if set(contract["allowed_package_architectures"]) != {"arm64", "all"}:
    raise SystemExit("allowed package architectures must be arm64 and all")
if contract["install_recommends"] is not False or contract["version_policy"] != "distribution-candidate":
    raise SystemExit("unsupported package installation policy")
if not re.fullmatch(r"[0-9a-f]{64}", contract["base_image_sha256"]):
    raise SystemExit("invalid base image SHA-256")

names = set()
direct_names = []
included_names = []
included_specifications = []
valid_profiles = {"runtime", "factory-debug", "optional"}
for item in contract["packages"]:
    if set(item) != {"name", "required", "version", "profile"}:
        raise SystemExit("invalid package contract entry")
    name = item["name"]
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", name):
        raise SystemExit(f"invalid package name: {name!r}")
    if name in names:
        raise SystemExit(f"duplicate package name: {name}")
    names.add(name)
    if not isinstance(item["required"], bool) or item["profile"] not in valid_profiles:
        raise SystemExit(f"invalid package profile: {name}")
    version = item["version"]
    if version is not None and (not isinstance(version, str) or not version):
        raise SystemExit(f"invalid version constraint for {name}")
    if item["required"]:
        direct_names.append(name)
    if item["required"] or item["profile"] == "factory-debug":
        included_names.append(name)
        included_specifications.append(f"{name}={version}" if version else name)
if len(direct_names) != 23:
    raise SystemExit(f"expected 23 required packages, found {len(direct_names)}")
optional_ssh = [item for item in contract["packages"] if item["name"] == "openssh-server"]
if optional_ssh != [{"name": "openssh-server", "required": False, "version": None, "profile": "factory-debug"}]:
    raise SystemExit("openssh-server factory-debug contract changed")

print(contract["distribution_codename"])
print(contract["architecture"])
print("\t".join(direct_names))
print("\t".join(included_names))
print("\t".join(included_specifications))
print(contract["base_image_name"])
print(contract["base_image_sha256"])
print(contract["bundle_version"])
print(contract["schema_version"])
print(contract["distribution"])
print(contract["distribution_version"])
PYEOF
)
[ "${#CONTRACT_VALUES[@]}" -eq 11 ] || die "could not load canonical package contract"
CODENAME="${CONTRACT_VALUES[0]}"
ARCHITECTURE="${CONTRACT_VALUES[1]}"
IFS=$'\t' read -r -a REQUIRED_NAMES <<< "${CONTRACT_VALUES[2]}"
IFS=$'\t' read -r -a INCLUDED_NAMES <<< "${CONTRACT_VALUES[3]}"
IFS=$'\t' read -r -a PACKAGE_SPECS <<< "${CONTRACT_VALUES[4]}"
BASE_IMAGE_NAME="${CONTRACT_VALUES[5]}"
BUNDLE_VERSION="${CONTRACT_VALUES[7]}"

if [ -z "$BASE_IMAGE" ]; then
    BASE_IMAGE="${ROOT}/../artifacts/base-images/${BASE_IMAGE_NAME}"
fi
[ -f "$BASE_IMAGE" ] || die "verified official base image is missing: ${BASE_IMAGE}"
if [ -e "$OUTPUT" ] && ! $REBUILD; then
    die "bundle already exists; use --rebuild to replace it: ${OUTPUT}"
fi

PARENT=$(dirname "$OUTPUT")
NAME=$(basename "$OUTPUT")
mkdir -p "$PARENT"
STAGING=$(mktemp -d "${PARENT}/.${NAME}.build.XXXXXX")
APT_ROOT=$(mktemp -d /tmp/sigil-offline-apt-build.XXXXXX)
BACKUP=""

cleanup() {
    rm -rf -- "${STAGING:-}" "${APT_ROOT:-}"
    if [ -n "${BACKUP:-}" ] && [ -e "$BACKUP" ] && [ ! -e "$OUTPUT" ]; then
        mv -- "$BACKUP" "$OUTPUT"
    fi
}
trap cleanup EXIT HUP INT TERM

install -d -m 0755 \
    "$APT_ROOT/state/lists/partial" \
    "$APT_ROOT/cache/archives/partial" \
    "$APT_ROOT/sources" \
    "$STAGING/packages"
: > "$APT_ROOT/status"

"$KEYRING_HELPER" "$CONTRACT" "$BASE_IMAGE" "$STAGING/sources-snapshot"

python3 - "$STAGING/sources-snapshot" "$APT_ROOT/sources/official.sources" <<'PYEOF'
import json, pathlib, sys
snapshot = pathlib.Path(sys.argv[1]).resolve()
destination = pathlib.Path(sys.argv[2])
replacements = {
    "/usr/share/keyrings/debian-archive-keyring.pgp": str(snapshot / "keyrings/debian-archive-keyring.pgp"),
    "/usr/share/keyrings/raspberrypi-archive-keyring.pgp": str(snapshot / "keyrings/raspberrypi-archive-keyring.pgp"),
}
parts = []
for filename in ("debian.sources", "raspi.sources"):
    text = (snapshot / filename).read_text(encoding="utf-8")
    # Some manufacturing networks cannot reach the primary Pi archive. This
    # university mirror serves the same archive; APT must still authenticate
    # its InRelease with the keyring extracted from the official image.
    if filename == "raspi.sources":
        text = text.replace(
            "http://archive.raspberrypi.com/debian/",
            "https://ftp.uni-hannover.de/raspberrypi/",
        )
    for original, replacement in replacements.items():
        text = text.replace(original, replacement)
    parts.append(text.strip())
destination.write_text("\n\n".join(parts) + "\n", encoding="utf-8")

metadata_path = snapshot / "sources-metadata.json"
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
for source in metadata["sources"]:
    if source["file"] == "raspi.sources":
        source["effective_uris"] = ["https://ftp.uni-hannover.de/raspberrypi/"]
metadata_path.write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYEOF

APT_OPTIONS=(
    -o "Dir::Etc::sourcelist=${APT_ROOT}/sources/official.sources"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State=${APT_ROOT}/state"
    -o "Dir::State::status=${APT_ROOT}/status"
    -o "Dir::Cache=${APT_ROOT}/cache"
    -o "Dir::Cache::archives=${APT_ROOT}/cache/archives"
    -o "APT::Architecture=${ARCHITECTURE}"
    -o "APT::Architectures::=${ARCHITECTURE}"
    -o "Acquire::Languages=none"
    -o "Acquire::IndexTargets::deb::DEP-11::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::CNF::DefaultEnabled=false"
    -o "Acquire::Retries=3"
    -o "APT::Update::Error-Mode=any"
    -o "APT::Install-Recommends=false"
    -o "Debug::NoLocking=1"
)

printf 'Resolving %d bundle roots (%d required, factory-debug included) for %s-%s (bundle %s)...\n' \
    "${#INCLUDED_NAMES[@]}" "${#REQUIRED_NAMES[@]}" "$CODENAME" "$ARCHITECTURE" "$BUNDLE_VERSION"
"$APT_GET" "${APT_OPTIONS[@]}" update
DEBIAN_FRONTEND=noninteractive "$APT_GET" "${APT_OPTIONS[@]}" \
    --assume-yes --download-only --no-install-recommends install "${PACKAGE_SPECS[@]}"

find "$APT_ROOT/cache/archives" -maxdepth 1 -type f -name '*.deb' \
    -exec cp -p -- {} "$STAGING/packages/" \;
[ -n "$(find "$STAGING/packages" -maxdepth 1 -type f -name '*.deb' -print -quit)" ] \
    || die "dependency resolver downloaded no .deb packages"

while IFS= read -r -d '' package_file; do
    [ -s "$package_file" ] || die "zero-byte package: $(basename "$package_file")"
    package_arch=$(dpkg-deb -f "$package_file" Architecture) \
        || die "unreadable Debian package: $(basename "$package_file")"
    case "$package_arch" in
        "$ARCHITECTURE"|all) ;;
        *) die "wrong package architecture ${package_arch}: $(basename "$package_file")" ;;
    esac
done < <(find "$STAGING/packages" -maxdepth 1 -type f -name '*.deb' -print0)

(
    cd "$STAGING"
    "$DPKG_SCANPACKAGES" --multiversion packages /dev/null > Packages
    gzip -n -9 -c Packages > Packages.gz
    apt-ftparchive release . > Release
)

install -d -m 0700 "$SIGNING_HOME"
if ! gpg --homedir "$SIGNING_HOME" --batch --list-secret-keys \
    --with-colons 'SIGIL Offline Repository' 2>/dev/null | grep -q '^sec:'; then
    gpg --homedir "$SIGNING_HOME" --batch --passphrase '' \
        --quick-generate-key 'SIGIL Offline Repository <manufacturing@sigil.local>' ed25519 sign 0
fi
SIGNING_FINGERPRINT=$(gpg --homedir "$SIGNING_HOME" --batch --list-secret-keys \
    --with-colons 'SIGIL Offline Repository' | awk -F: '$1 == "fpr" {print $10; exit}')
[ -n "$SIGNING_FINGERPRINT" ] || die "could not determine local repository signing fingerprint"
gpg --homedir "$SIGNING_HOME" --batch --yes --export "$SIGNING_FINGERPRINT" \
    > "$STAGING/sources-snapshot/keyrings/sigil-offline-repository.gpg"
gpg --homedir "$SIGNING_HOME" --batch --yes --local-user "$SIGNING_FINGERPRINT" \
    --clearsign --output "$STAGING/InRelease" "$STAGING/Release"
gpg --homedir "$SIGNING_HOME" --batch --yes --local-user "$SIGNING_FINGERPRINT" \
    --detach-sign --output "$STAGING/Release.gpg" "$STAGING/Release"

# Prove that the generated repository alone satisfies the complete Depends and
# Pre-Depends closure. This uses an empty dpkg status database and never
# installs or executes an ARM64 package on the manufacturing host.
VERIFY_ROOT="${APT_ROOT}/verify"
install -d -m 0755 \
    "$VERIFY_ROOT/state/lists/partial" \
    "$VERIFY_ROOT/cache/archives/partial" \
    "$VERIFY_ROOT/sources"
: > "$VERIFY_ROOT/status"
printf 'deb [arch=%s signed-by=%s] file:%s ./\n' \
    "$ARCHITECTURE" \
    "$STAGING/sources-snapshot/keyrings/sigil-offline-repository.gpg" \
    "$STAGING" > "$VERIFY_ROOT/sources/offline.list"
VERIFY_OPTIONS=(
    -o "Dir::Etc::sourcelist=${VERIFY_ROOT}/sources/offline.list"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State=${VERIFY_ROOT}/state"
    -o "Dir::State::status=${VERIFY_ROOT}/status"
    -o "Dir::Cache=${VERIFY_ROOT}/cache"
    -o "Dir::Cache::archives=${VERIFY_ROOT}/cache/archives"
    -o "APT::Architecture=${ARCHITECTURE}"
    -o "APT::Architectures::=${ARCHITECTURE}"
    -o "Acquire::Languages=none"
    -o "Acquire::IndexTargets::deb::DEP-11::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled=false"
    -o "Acquire::IndexTargets::deb::CNF::DefaultEnabled=false"
    -o "APT::Update::Error-Mode=any"
    -o "APT::Install-Recommends=false"
    -o "Debug::NoLocking=1"
)
"$APT_GET" "${VERIFY_OPTIONS[@]}" update
"$APT_GET" "${VERIFY_OPTIONS[@]}" --simulate --no-download \
    --no-install-recommends install "${PACKAGE_SPECS[@]}" >/dev/null

SOURCE_HARDWARE_COMMIT=""
SOURCE_HARDWARE_ROOT="${SIGIL_HARDWARE_SOURCE:-${ROOT}/../sigil-hardware}"
if [ -d "$SOURCE_HARDWARE_ROOT/.git" ] \
    && [ -f "$SOURCE_HARDWARE_ROOT/manifests/offline-package-contract.json" ] \
    && cmp -s "$CONTRACT" "$SOURCE_HARDWARE_ROOT/manifests/offline-package-contract.json" \
    && git -C "$SOURCE_HARDWARE_ROOT" ls-files --error-unmatch \
        manifests/offline-package-contract.json >/dev/null 2>&1 \
    && git -C "$SOURCE_HARDWARE_ROOT" diff --quiet -- \
        manifests/offline-package-contract.json; then
    SOURCE_HARDWARE_COMMIT=$(git -C "$SOURCE_HARDWARE_ROOT" rev-parse HEAD 2>/dev/null || true)
fi

python3 - "$CONTRACT" "$STAGING" "$SOURCE_HARDWARE_COMMIT" "$SIGNING_FINGERPRINT" <<'PYEOF'
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

contract_path = pathlib.Path(sys.argv[1]).resolve()
repository = pathlib.Path(sys.argv[2]).resolve()
source_commit = sys.argv[3] or None
signing_fingerprint = sys.argv[4]
contract_bytes = contract_path.read_bytes()
contract = json.loads(contract_bytes)
direct = [item for item in contract["packages"] if item["required"]]
direct_names = [item["name"] for item in direct]
included = [item for item in contract["packages"] if item["required"] or item["profile"] == "factory-debug"]
included_names = [item["name"] for item in included]
allowed_architectures = set(contract["allowed_package_architectures"])

packages = []
names = set()
tuples = set()
for path in sorted((repository / "packages").glob("*.deb")):
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"unsafe or empty Debian package: {path.name}")
    fields = []
    for field in ("Package", "Version", "Architecture"):
        value = subprocess.run(
            ["dpkg-deb", "-f", str(path), field],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
        if not value or "\n" in value:
            raise SystemExit(f"could not inspect {field}: {path.name}")
        fields.append(value)
    name, version, architecture = fields
    package_tuple = (name, version, architecture)
    if package_tuple in tuples:
        raise SystemExit(f"duplicate package tuple: {name}={version}/{architecture}")
    tuples.add(package_tuple)
    if architecture not in allowed_architectures:
        raise SystemExit(f"wrong package architecture {architecture}: {path.name}")
    data = path.read_bytes()
    relative = path.relative_to(repository).as_posix()
    packages.append({
        "name": name,
        "version": version,
        "architecture": architecture,
        "filename": relative,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    })
    names.add(name)

missing = sorted(set(included_names) - names)
if missing:
    raise SystemExit("resolved repository is missing required bundle-profile packages: " + ", ".join(missing))
for package in included:
    if package["version"] is not None and not any(
        item["name"] == package["name"] and item["version"] == package["version"]
        for item in packages
    ):
        raise SystemExit(f"resolved repository is missing pinned package: {package['name']}={package['version']}")

snapshot = repository / "sources-snapshot"
keyring_metadata = json.loads((snapshot / "keyring-metadata.json").read_text(encoding="utf-8"))
sources_metadata = json.loads((snapshot / "sources-metadata.json").read_text(encoding="utf-8"))
repository_keyring = snapshot / "keyrings/sigil-offline-repository.gpg"
keyring_metadata["keyrings"].append({
    "package": None,
    "package_version": None,
    "source_image": None,
    "source_path": "generated manufacturing signing cache",
    "artifact_path": "keyrings/sigil-offline-repository.gpg",
    "sha256": hashlib.sha256(repository_keyring.read_bytes()).hexdigest(),
    "fingerprints": [signing_fingerprint],
    "scope": "SIGIL file:// offline repository",
})
(snapshot / "keyring-metadata.json").write_text(
    json.dumps(keyring_metadata, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

manifest = {
    "schema_version": "2.0",
    "repository_type": "sigil-offline-apt",
    "package_contract_schema_version": contract["schema_version"],
    "bundle_version": contract["bundle_version"],
    "package_contract_sha256": hashlib.sha256(contract_bytes).hexdigest(),
    "source_sigil_hardware_commit": source_commit,
    "base_image_name": contract["base_image_name"],
    "base_image_sha256": contract["base_image_sha256"],
    "distribution": contract["distribution"],
    "distribution_version": contract["distribution_version"],
    "distribution_codename": contract["distribution_codename"],
    "architecture": contract["architecture"],
    "generation_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "direct_packages": direct_names,
    "direct_package_count": len(direct_names),
    "resolved_package_count": len(packages),
    "total_bytes": sum(item["size"] for item in packages),
    "unresolved_packages": [],
    "sources": sources_metadata["sources"],
    "keyrings": keyring_metadata["keyrings"],
    "python_dependencies": {
        "fully_satisfied_by_debian_packages": {"flask": "python3-flask", "argon2": "python3-argon2", "bluetooth": "python3-bluez"},
        "wheels": [],
    },
    "packages": packages,
}
(repository / "package-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYEOF

(
    cd "$STAGING"
    find packages sources-snapshot -type f -print \
        | LC_ALL=C sort \
        | while IFS= read -r relative; do sha256sum "$relative"; done
    sha256sum Packages Packages.gz Release Release.gpg InRelease package-manifest.json
) > "$STAGING/checksums.sha256"

if [ -e "$OUTPUT" ]; then
    BACKUP="${OUTPUT}.previous.$$"
    mv -- "$OUTPUT" "$BACKUP"
fi
mv -- "$STAGING" "$OUTPUT"
STAGING=""
if [ -n "$BACKUP" ]; then
    rm -rf -- "$BACKUP"
    BACKUP=""
fi
trap - EXIT HUP INT TERM
rm -rf -- "$APT_ROOT"
APT_ROOT=""

python3 - "$OUTPUT/package-manifest.json" <<'PYEOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
print(f"bundle: {path.parent}")
print(f"bundle_version: {manifest['bundle_version']}")
print(f"direct_packages: {manifest['direct_package_count']}")
print(f"resolved_packages: {manifest['resolved_package_count']}")
print(f"architecture: {manifest['architecture']}")
print(f"distribution: {manifest['distribution']} {manifest['distribution_version']} ({manifest['distribution_codename']})")
print(f"base_image: {manifest['base_image_name']}")
print(f"total_bytes: {manifest['total_bytes']}")
PYEOF
