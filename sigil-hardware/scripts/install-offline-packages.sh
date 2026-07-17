#!/bin/bash
# Install the canonical SIGIL package contract from a signed local APT repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="${SIGIL_PACKAGE_CONTRACT:-${ROOT}/manifests/offline-package-contract.json}"
REPOSITORY="${1:-}"
REQUESTED_PROFILES="${SIGIL_PACKAGE_PROFILES:-}"
APT_STATE=""
SOURCE_LIST=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [ -z "$SOURCE_LIST" ] || rm -f -- "$SOURCE_LIST"
    [ -z "$APT_STATE" ] || rm -rf -- "$APT_STATE"
}
trap cleanup EXIT HUP INT TERM

[ "$EUID" -eq 0 ] || [ "${SIGIL_OFFLINE_INSTALL_TEST_MODE:-0}" = "1" ] \
    || die "install-offline-packages.sh must run as root"
[ -n "$REPOSITORY" ] || die "usage: install-offline-packages.sh <local-repository>"
[ -d "$REPOSITORY" ] || die "local repository does not exist: ${REPOSITORY}"
[ -f "$CONTRACT" ] || die "canonical package contract is missing: ${CONTRACT}"
command -v dpkg-deb >/dev/null || die "dpkg-deb is required"
command -v gpgv >/dev/null || die "gpgv is required"

mapfile -t CONTRACT_VALUES < <(python3 - "$CONTRACT" "$REPOSITORY" "$REQUESTED_PROFILES" <<'PYEOF'
import gzip
import hashlib
import json
import pathlib
import re
import subprocess
import sys

contract_path = pathlib.Path(sys.argv[1]).resolve()
repository = pathlib.Path(sys.argv[2]).resolve()
requested_profiles = {profile for profile in sys.argv[3].split(",") if profile}
unknown_profiles = requested_profiles - {"factory-debug", "optional"}
if unknown_profiles:
    raise SystemExit("unsupported package profile selection: " + ", ".join(sorted(unknown_profiles)))
try:
    contract_bytes = contract_path.read_bytes()
    contract = json.loads(contract_bytes)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid canonical package contract: {error}")

contract_keys = {
    "schema_version", "bundle_version", "distribution", "distribution_version",
    "distribution_codename", "architecture", "allowed_package_architectures",
    "base_image_name", "base_image_sha256", "install_recommends",
    "version_policy", "packages",
}
if set(contract) != contract_keys or contract["schema_version"] != "2.0":
    raise SystemExit("unsupported canonical package contract")
if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*", contract["bundle_version"]):
    raise SystemExit("invalid canonical bundle version")
if (
    contract["distribution"] != "debian"
    or contract["distribution_version"] != "13"
    or contract["distribution_codename"] != "trixie"
    or contract["architecture"] != "arm64"
    or set(contract["allowed_package_architectures"]) != {"arm64", "all"}
):
    raise SystemExit("unsupported distribution or architecture contract")
if contract["install_recommends"] is not False or contract["version_policy"] != "distribution-candidate":
    raise SystemExit("unsupported installation policy")

required_names = []
names = []
versions = {}
all_names = set()
for package in contract["packages"]:
    if set(package) != {"name", "required", "version", "profile"}:
        raise SystemExit("invalid package contract entry")
    name = package["name"]
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", name):
        raise SystemExit(f"invalid package name: {name!r}")
    if name in all_names or package["profile"] not in {"runtime", "factory-debug", "optional"}:
        raise SystemExit(f"duplicate package or invalid profile: {name}")
    all_names.add(name)
    if package["version"] is not None and not isinstance(package["version"], str):
        raise SystemExit(f"invalid version contract: {name}")
    if package["required"]:
        required_names.append(name)
    if package["required"] or package["profile"] in requested_profiles:
        names.append(name)
        versions[name] = package["version"]
if len(required_names) != 23:
    raise SystemExit(f"expected 23 required packages, found {len(required_names)}")

manifest_path = repository / "package-manifest.json"
try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid offline package manifest: {error}")
manifest_keys = {
    "schema_version", "repository_type", "package_contract_schema_version",
    "bundle_version", "package_contract_sha256", "source_sigil_hardware_commit",
    "base_image_name", "base_image_sha256", "distribution",
    "distribution_version", "distribution_codename", "architecture",
    "generation_timestamp", "direct_packages", "direct_package_count",
    "resolved_package_count", "total_bytes", "unresolved_packages", "sources",
    "keyrings", "python_dependencies", "packages",
}
if set(manifest) != manifest_keys or manifest["schema_version"] != "2.0":
    raise SystemExit("unsupported offline package manifest")
for field in (
    "bundle_version", "base_image_name", "base_image_sha256", "distribution",
    "distribution_version", "distribution_codename", "architecture",
):
    if manifest[field] != contract[field]:
        raise SystemExit(f"bundle {field} is incompatible with package contract")
if manifest["package_contract_schema_version"] != contract["schema_version"]:
    raise SystemExit("bundle package-contract schema version is incompatible")
if manifest["package_contract_sha256"] != hashlib.sha256(contract_bytes).hexdigest():
    raise SystemExit("bundle was generated from a different package contract")
if manifest["direct_packages"] != required_names or manifest["direct_package_count"] != len(required_names):
    raise SystemExit("bundle direct package set does not match contract")
if manifest["unresolved_packages"] != []:
    raise SystemExit("bundle contains unresolved packages")

required_repository_files = (
    "Packages", "Packages.gz", "Release", "Release.gpg", "InRelease",
    "checksums.sha256", "sources-snapshot/keyrings/sigil-offline-repository.gpg",
)
for relative in required_repository_files:
    path = repository / relative
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise SystemExit(f"offline repository file is missing or unsafe: {relative}")
try:
    packages_bytes = (repository / "Packages").read_bytes()
    if gzip.decompress((repository / "Packages.gz").read_bytes()) != packages_bytes:
        raise SystemExit("Packages.gz does not match Packages")
except (OSError, gzip.BadGzipFile) as error:
    raise SystemExit(f"invalid Packages.gz: {error}")

package_entries = manifest["packages"]
if not isinstance(package_entries, list) or not package_entries:
    raise SystemExit("offline package manifest contains no packages")
expected_package_keys = {"name", "version", "architecture", "filename", "sha256", "size"}
manifest_filenames = set()
package_names = set()
total_size = 0
tuples = set()
for package in package_entries:
    if not isinstance(package, dict) or set(package) != expected_package_keys:
        raise SystemExit("invalid package manifest entry")
    name, version, architecture = package["name"], package["version"], package["architecture"]
    filename, digest, size = package["filename"], package["sha256"], package["size"]
    if (name, version, architecture) in tuples:
        raise SystemExit(f"duplicate package tuple: {name}={version}/{architecture}")
    tuples.add((name, version, architecture))
    if architecture not in contract["allowed_package_architectures"]:
        raise SystemExit(f"wrong package architecture {architecture}: {filename}")
    if not isinstance(filename, str) or not re.fullmatch(r"packages/[^/]+\.deb", filename):
        raise SystemExit(f"unsafe package filename: {filename!r}")
    if filename in manifest_filenames or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit(f"duplicate filename or invalid checksum: {filename}")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise SystemExit(f"invalid package size: {filename}")
    path = repository / filename
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"package file is missing or unsafe: {filename}")
    data = path.read_bytes()
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"package metadata does not match file: {filename}")
    control = []
    for field in ("Package", "Version", "Architecture"):
        control.append(subprocess.run(
            ["dpkg-deb", "-f", str(path), field], check=True, text=True, capture_output=True,
        ).stdout.strip())
    if control != [name, version, architecture]:
        raise SystemExit(f"Debian control metadata mismatch: {filename}")
    manifest_filenames.add(filename)
    package_names.add(name)
    total_size += size

actual_entries = list((repository / "packages").iterdir())
actual_debs = {path.relative_to(repository).as_posix() for path in actual_entries if path.is_file() and path.suffix == ".deb"}
if any(path.is_symlink() or not path.is_file() or path.suffix != ".deb" for path in actual_entries):
    raise SystemExit("packages directory contains an unexpected entry")
if actual_debs != manifest_filenames:
    raise SystemExit("package manifest does not exactly match packages directory")
if manifest["resolved_package_count"] != len(package_entries) or manifest["total_bytes"] != total_size:
    raise SystemExit("resolved package count or total bytes does not match manifest")
missing = sorted(set(names) - package_names)
if missing:
    raise SystemExit("offline repository is missing selected package-profile packages: " + ", ".join(missing))
for name, required_version in versions.items():
    if required_version is not None and not any(
        package["name"] == name and package["version"] == required_version for package in package_entries
    ):
        raise SystemExit(f"offline repository is missing required version: {name}={required_version}")

index_filenames = set()
for stanza in packages_bytes.decode("utf-8").split("\n\n"):
    if not stanza.strip():
        continue
    fields = {}
    for line in stanza.splitlines():
        if not line.startswith((" ", "\t")) and ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    for field in ("Package", "Version", "Architecture", "Filename", "Size", "SHA256"):
        if not fields.get(field):
            raise SystemExit(f"Packages entry is missing {field}")
    index_filenames.add(fields["Filename"])
if index_filenames != manifest_filenames:
    raise SystemExit("Packages index does not exactly match package manifest")

checksum_lines = (repository / "checksums.sha256").read_text(encoding="utf-8").splitlines()
declared = {}
for line in checksum_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
    if not match:
        raise SystemExit("invalid checksums.sha256 format")
    digest, relative = match.groups()
    candidate = pathlib.PurePosixPath(relative)
    if candidate.is_absolute() or ".." in candidate.parts or relative in declared:
        raise SystemExit("unsafe or duplicate checksum path")
    declared[relative] = digest
snapshot_files = {
    path.relative_to(repository).as_posix()
    for path in (repository / "sources-snapshot").rglob("*") if path.is_file()
}
expected_checksums = manifest_filenames | snapshot_files | {
    "Packages", "Packages.gz", "Release", "Release.gpg", "InRelease", "package-manifest.json"
}
if set(declared) != expected_checksums:
    raise SystemExit("checksums.sha256 does not cover exactly the repository artifacts")
for relative, expected in declared.items():
    path = repository / relative
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"checksummed repository file is missing or unsafe: {relative}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"checksum mismatch: {relative}")

signing_records = [
    item for item in manifest["keyrings"]
    if item.get("artifact_path") == "keyrings/sigil-offline-repository.gpg"
]
if len(signing_records) != 1 or not signing_records[0].get("fingerprints"):
    raise SystemExit("bundle signing key metadata is missing")
python_dependencies = manifest.get("python_dependencies", {})
if python_dependencies.get("wheels") != []:
    raise SystemExit("unexpected Python wheel dependency")
required_python = python_dependencies.get("fully_satisfied_by_debian_packages", {})
if required_python.get("flask") != "python3-flask" or required_python.get("argon2") != "python3-argon2":
    raise SystemExit("Python runtime dependency metadata is incomplete")

print(contract["distribution_codename"])
print(contract["architecture"])
print("\t".join(names))
print("\t".join(f"{name}={versions[name]}" if versions[name] is not None else name for name in names))
print(contract["bundle_version"])
PYEOF
)

[ "${#CONTRACT_VALUES[@]}" -eq 5 ] || die "could not load canonical package contract"
EXPECTED_CODENAME="${CONTRACT_VALUES[0]}"
EXPECTED_ARCH="${CONTRACT_VALUES[1]}"
IFS=$'\t' read -r -a REQUIRED_PACKAGES <<< "${CONTRACT_VALUES[2]}"
IFS=$'\t' read -r -a REQUIRED_SPECS <<< "${CONTRACT_VALUES[3]}"
BUNDLE_VERSION="${CONTRACT_VALUES[4]}"

REPOSITORY_KEY="$(realpath "$REPOSITORY/sources-snapshot/keyrings/sigil-offline-repository.gpg")"
gpgv --keyring "$REPOSITORY_KEY" "$REPOSITORY/Release.gpg" "$REPOSITORY/Release" >/dev/null \
    || die "offline repository Release signature is invalid"
gpgv --keyring "$REPOSITORY_KEY" "$REPOSITORY/InRelease" >/dev/null \
    || die "offline repository InRelease signature is invalid"

ACTUAL_ARCH="$(dpkg --print-architecture)"
[ "$ACTUAL_ARCH" = "$EXPECTED_ARCH" ] \
    || die "target architecture is ${ACTUAL_ARCH}; expected ${EXPECTED_ARCH}"
OS_RELEASE_FILE="${SIGIL_OS_RELEASE_FILE:-/etc/os-release}"
if [ -r "$OS_RELEASE_FILE" ]; then
    ACTUAL_CODENAME=$(python3 - "$OS_RELEASE_FILE" <<'PYEOF'
import pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.startswith("VERSION_CODENAME="):
        print(line.split("=", 1)[1].strip().strip("\"'"))
        break
PYEOF
)
    [ "$ACTUAL_CODENAME" = "$EXPECTED_CODENAME" ] \
        || die "target distribution is ${ACTUAL_CODENAME:-unknown}; expected ${EXPECTED_CODENAME}"
fi

APT_STATE="$(mktemp -d /tmp/sigil-offline-apt.XXXXXX)"
SOURCE_LIST="$(mktemp /tmp/sigil-offline-source.XXXXXX.list)"
printf 'deb [signed-by=%s] file:%s ./\n' "$REPOSITORY_KEY" "$(realpath "$REPOSITORY")" > "$SOURCE_LIST"
mkdir -p "$APT_STATE/lists/partial" "$APT_STATE/cache/archives/partial"
APT_OPTIONS=(
    -o "Dir::Etc::sourcelist=${SOURCE_LIST}"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::lists=${APT_STATE}/lists"
    -o "Dir::Cache::archives=${APT_STATE}/cache/archives"
    -o "Acquire::Languages=none"
    -o "Acquire::Retries=0"
    -o "APT::Install-Recommends=false"
)

apt-get "${APT_OPTIONS[@]}" update
for index in "${!REQUIRED_PACKAGES[@]}"; do
    package="${REQUIRED_PACKAGES[$index]}"
    specification="${REQUIRED_SPECS[$index]}"
    candidate=$(apt-cache "${APT_OPTIONS[@]}" policy "$package" | awk '/Candidate:/ { print $2; exit }')
    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        die "required package is unavailable offline: ${package}"
    fi
    if [[ "$specification" == *=* ]] && [ "$candidate" != "${specification#*=}" ]; then
        die "required package candidate is ${candidate}; expected ${specification}"
    fi
done

DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTIONS[@]}" \
    --assume-yes --no-install-recommends install "${REQUIRED_SPECS[@]}"
for package in "${REQUIRED_PACKAGES[@]}"; do
    dpkg-query -W -f='${db:Status-Status}\n' "$package" 2>/dev/null | grep -qx installed \
        || die "required package was not installed: ${package}"
done

printf 'Offline bundle %s installed successfully (%d direct packages).\n' \
    "$BUNDLE_VERSION" "${#REQUIRED_PACKAGES[@]}"
