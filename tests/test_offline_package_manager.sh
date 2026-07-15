#!/bin/bash
# Focused manufacturing validation for the real offline package bundle.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="${ROOT}/scripts/build-offline-repository.sh"
EXTRACTOR="${ROOT}/scripts/extract-official-apt-metadata.sh"
CONTRACT="${ROOT}/sigil-hardware/manifests/offline-package-contract.json"
BUNDLE="${ROOT}/artifacts/offline-packages/trixie-arm64"
BASE_IMAGE="${ROOT}/../artifacts/base-images/2026-06-18-raspios-trixie-arm64-lite.img.xz"
TEST_ROOT=$(mktemp -d /tmp/sigil-offline-manager.XXXXXX)
PASS=0
FAIL=0

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

check() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$name"
    fi
}

check "builder and image metadata extractor are valid shell" \
    bash -n "$BUILDER" "$EXTRACTOR"

check "canonical contract has schema, bundle version, profiles, and 23 required packages" \
    python3 - "$CONTRACT" <<'PYEOF'
import json, pathlib, re, sys
contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
required = [item for item in contract["packages"] if item["required"]]
optional = [item for item in contract["packages"] if not item["required"]]
valid = (
    contract["schema_version"] == "2.0"
    and re.fullmatch(r"\d{4}\.\d{2}\.\d{2}\.[1-9]\d*", contract["bundle_version"])
    and contract["distribution"] == "debian"
    and contract["distribution_version"] == "13"
    and contract["architecture"] == "arm64"
    and contract["install_recommends"] is False
    and len(required) == 23
    and {item["profile"] for item in contract["packages"]} <= {"runtime", "factory-debug", "optional"}
    and optional == [{"name": "openssh-server", "required": False, "version": None, "profile": "factory-debug"}]
)
raise SystemExit(0 if valid else 1)
PYEOF

check "real bundle has the complete signed repository layout" \
    sh -c "test -d '$BUNDLE/packages' && test -d '$BUNDLE/sources-snapshot' && test -s '$BUNDLE/Packages' && test -s '$BUNDLE/Packages.gz' && test -s '$BUNDLE/Release' && test -s '$BUNDLE/Release.gpg' && test -s '$BUNDLE/InRelease' && test -s '$BUNDLE/checksums.sha256' && test -s '$BUNDLE/package-manifest.json'"

check "all generated repository checksums validate" \
    sh -c "cd '$BUNDLE' && sha256sum --check --strict checksums.sha256 >/dev/null"

check "Packages.gz exactly represents Packages" \
    sh -c "gzip -dc '$BUNDLE/Packages.gz' | cmp -s - '$BUNDLE/Packages'"

check "manifest is compatible with the contract and official base image" \
    python3 - "$CONTRACT" "$BUNDLE/package-manifest.json" "$BASE_IMAGE" <<'PYEOF'
import hashlib, json, pathlib, sys
contract_path, manifest_path, image_path = map(pathlib.Path, sys.argv[1:])
contract_bytes = contract_path.read_bytes()
contract = json.loads(contract_bytes)
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
valid = (
    manifest["schema_version"] == "2.0"
    and manifest["package_contract_schema_version"] == contract["schema_version"]
    and manifest["bundle_version"] == contract["bundle_version"]
    and manifest["package_contract_sha256"] == hashlib.sha256(contract_bytes).hexdigest()
    and manifest["base_image_name"] == image_path.name == contract["base_image_name"]
    and manifest["base_image_sha256"] == hashlib.sha256(image_path.read_bytes()).hexdigest() == contract["base_image_sha256"]
    and manifest["distribution"] == contract["distribution"]
    and manifest["distribution_version"] == contract["distribution_version"]
    and manifest["architecture"] == contract["architecture"]
    and manifest["direct_package_count"] == 23
    and manifest["resolved_package_count"] == len(manifest["packages"])
    and manifest["resolved_package_count"] > manifest["direct_package_count"]
    and manifest["unresolved_packages"] == []
)
raise SystemExit(0 if valid else 1)
PYEOF

check "repository contains only readable arm64/all packages and unique tuples" \
    python3 - "$BUNDLE" <<'PYEOF'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "package-manifest.json").read_text(encoding="utf-8"))
tuples = set()
for item in manifest["packages"]:
    path = root / item["filename"]
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(1)
    values = tuple(subprocess.run(
        ["dpkg-deb", "-f", str(path), field], check=True, text=True, capture_output=True
    ).stdout.strip() for field in ("Package", "Version", "Architecture"))
    if values != (item["name"], item["version"], item["architecture"]):
        raise SystemExit(1)
    if values[2] not in {"arm64", "all"} or values in tuples:
        raise SystemExit(1)
    tuples.add(values)
PYEOF

check "manifest and packages directory have no stale or undeclared Debian packages" \
    python3 - "$BUNDLE" <<'PYEOF'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "package-manifest.json").read_text(encoding="utf-8"))
declared = {item["filename"] for item in manifest["packages"]}
actual = {path.relative_to(root).as_posix() for path in (root / "packages").iterdir() if path.is_file()}
raise SystemExit(0 if declared == actual else 1)
PYEOF

check "Flask, Argon2, and Bluetooth Python modules are supplied by Debian packages only" \
    python3 - "$BUNDLE/package-manifest.json" <<'PYEOF'
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
python = manifest["python_dependencies"]
expected = {"flask": "python3-flask", "argon2": "python3-argon2", "bluetooth": "python3-bluez"}
names = {item["name"] for item in manifest["packages"]}
valid = python["fully_satisfied_by_debian_packages"] == expected and python["wheels"] == [] and set(expected.values()) <= names
raise SystemExit(0 if valid else 1)
PYEOF

check "source and keyring metadata records authenticated official origins" \
    python3 - "$BUNDLE/package-manifest.json" <<'PYEOF'
import json, pathlib, re, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
sources = {item["file"]: item for item in manifest["sources"]}
keyrings = {item["artifact_path"]: item for item in manifest["keyrings"]}
valid = (
    sources["debian.sources"]["signed_by"].endswith("debian-archive-keyring.pgp")
    and "http://deb.debian.org/debian/" in sources["debian.sources"]["uris"]
    and sources["raspi.sources"]["uris"] == ["http://archive.raspberrypi.com/debian/"]
    and sources["raspi.sources"]["effective_uris"] == ["https://ftp.uni-hannover.de/raspberrypi/"]
    and set(keyrings) == {
        "keyrings/debian-archive-keyring.pgp",
        "keyrings/raspberrypi-archive-keyring.pgp",
        "keyrings/sigil-offline-repository.gpg",
    }
    and all(re.fullmatch(r"[0-9A-F]{40}", fingerprint) for item in keyrings.values() for fingerprint in item["fingerprints"])
)
raise SystemExit(0 if valid else 1)
PYEOF

check "repository signatures validate with the generated local public key" \
    sh -c "gpgv --keyring '$BUNDLE/sources-snapshot/keyrings/sigil-offline-repository.gpg' '$BUNDLE/Release.gpg' '$BUNDLE/Release' >/dev/null 2>&1 && gpgv --keyring '$BUNDLE/sources-snapshot/keyrings/sigil-offline-repository.gpg' '$BUNDLE/InRelease' >/dev/null 2>&1"

check "official image yields Debian and Raspberry Pi source/keyring metadata" \
    sh -c "'$EXTRACTOR' '$CONTRACT' '$BASE_IMAGE' '$TEST_ROOT/extracted' >/dev/null && test -s '$TEST_ROOT/extracted/debian.sources' && test -s '$TEST_ROOT/extracted/raspi.sources' && test -s '$TEST_ROOT/extracted/keyrings/debian-archive-keyring.pgp' && test -s '$TEST_ROOT/extracted/keyrings/raspberrypi-archive-keyring.pgp'"

check "operational scripts never enable unauthenticated APT" \
    sh -c "! grep -Eiq 'trusted[[:space:]]*=[[:space:]]*yes|allow-unauthenticated|allow-insecure-repositories|AllowInsecureRepositories' '$BUILDER' '$ROOT/sigil-hardware/scripts/install-offline-packages.sh'"

check "builder uses isolated APT state and atomically replaces stale bundles" \
    sh -c "grep -q 'Dir::State=' '$BUILDER' && grep -q 'mv -- \"\$OUTPUT\" \"\$BACKUP\"' '$BUILDER' && grep -q 'mv -- \"\$STAGING\" \"\$OUTPUT\"' '$BUILDER'"

check "all generated artifacts are ignored by Git" \
    sh -c "git -C '$ROOT' check-ignore -q '$BUNDLE/package-manifest.json' && git -C '$ROOT' check-ignore -q '$BUNDLE/packages/adduser_3.152_all.deb'"

printf '\nOffline package manager: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
