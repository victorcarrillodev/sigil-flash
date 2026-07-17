#!/bin/bash
# Contract and behavior tests for hardware-owned offline package installation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="${ROOT}/manifests/offline-package-contract.json"
INSTALLER="${ROOT}/scripts/install-offline-packages.sh"
FIRSTBOOT="${ROOT}/scripts/firstboot.sh"
TEST_ROOT=$(mktemp -d /tmp/sigil-offline-hardware.XXXXXX)
PASS=0
FAIL=0

for candidate in \
    "${SIGIL_OFFLINE_TEST_BUNDLE:-}" \
    "${ROOT}/../artifacts/offline-packages/trixie-arm64" \
    "${ROOT}/../sigil-flash/artifacts/offline-packages/trixie-arm64"; do
    if [ -n "$candidate" ] && [ -s "$candidate/package-manifest.json" ]; then
        BUNDLE="$candidate"
        break
    fi
done
BUNDLE="${BUNDLE:-}"

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

check "canonical contract is versioned and internally consistent" \
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
    and contract["distribution_codename"] == "trixie"
    and contract["architecture"] == "arm64"
    and set(contract["allowed_package_architectures"]) == {"arm64", "all"}
    and contract["install_recommends"] is False
    and len(required) == 23
    and all(item["profile"] == "runtime" for item in required)
    and optional == [{"name": "openssh-server", "required": False, "version": None, "profile": "factory-debug"}]
)
raise SystemExit(0 if valid else 1)
PYEOF

check "sigil-hardware contains no downloaded packages or generated repositories" \
    test -z "$(find "$ROOT" -type f \( -name '*.deb' -o -name '*.udeb' -o -name '*.whl' -o -name 'Packages.gz' \) -print -quit)"

check "install.sh delegates package installation to the canonical offline installer" \
    sh -c "grep -q 'install-offline-packages.sh' '$ROOT/install.sh' && ! grep -Eq 'apt-get[[:space:]]+(update|install)|pip(3|[[:space:]])+[[:space:]]*install' '$ROOT/install.sh'"

check "firstboot main path contains no package download or device registration" \
    sh -c "! sed -n '/^firstboot_main()/,/^}/p' '$FIRSTBOOT' | grep -Eq 'apt(-get)?[[:space:]]+(update|install)|pip(3|[[:space:]])+[[:space:]]*install|curl|wget|register_device'"

check "image preparation defers live systemd operations to firstboot" \
    sh -c "grep -q 'Preparación de imagen: user lingering se aplicará en firstboot' '$ROOT/install.sh' && grep -q 'Preparación de imagen: daemon-reload se aplicará en firstboot' '$ROOT/install.sh' && grep -q '^ensure_user_lingering()' '$FIRSTBOOT'"

check "real manufacturing bundle is available for installer integration" \
    test -n "$BUNDLE"

MOCK_BIN="${TEST_ROOT}/bin"
APT_LOG="${TEST_ROOT}/apt.log"
OS_RELEASE="${TEST_ROOT}/os-release"
mkdir -p "$MOCK_BIN"
printf 'VERSION_CODENAME=trixie\n' > "$OS_RELEASE"

for command in apt-get apt-cache dpkg dpkg-query; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/$command"
    chmod +x "$MOCK_BIN/$command"
done
cat > "$MOCK_BIN/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = "--print-architecture" ] && printf 'arm64\n'
EOF
cat > "$MOCK_BIN/apt-cache" <<'EOF'
#!/bin/sh
printf '  Candidate: 1.0\n'
EOF
cat > "$MOCK_BIN/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SIGIL_APT_TEST_LOG:?}"
for argument in "$@"; do
    case "$argument" in
        Dir::Etc::sourcelist=*) cat "${argument#*=}" >> "${SIGIL_APT_TEST_LOG:?}" ;;
    esac
done
EOF
cat > "$MOCK_BIN/dpkg-query" <<'EOF'
#!/bin/sh
printf 'installed\n'
EOF
chmod +x "$MOCK_BIN"/*

if [ -n "$BUNDLE" ]; then
    check "offline installer validates and installs the complete signed local bundle" \
        env PATH="${MOCK_BIN}:/usr/bin:/bin" \
            SIGIL_OFFLINE_INSTALL_TEST_MODE=1 \
            SIGIL_OS_RELEASE_FILE="$OS_RELEASE" \
            SIGIL_APT_TEST_LOG="$APT_LOG" \
            bash "$INSTALLER" "$BUNDLE"

    check "offline installer configures signed-by file:// only" \
        sh -c "grep -q 'signed-by=.*file:' '$APT_LOG' && ! grep -Eq 'https?://|trusted[[:space:]]*=[[:space:]]*yes|allow-unauthenticated' '$APT_LOG'"

    : > "$APT_LOG"
    check "factory-debug profile installs openssh-server from the local bundle" \
        env PATH="${MOCK_BIN}:/usr/bin:/bin" \
            SIGIL_OFFLINE_INSTALL_TEST_MODE=1 \
            SIGIL_PACKAGE_PROFILES=factory-debug \
            SIGIL_OS_RELEASE_FILE="$OS_RELEASE" \
            SIGIL_APT_TEST_LOG="$APT_LOG" \
            bash "$INSTALLER" "$BUNDLE"

    check "factory-debug profile reaches APT without network or credentials" \
        sh -c "grep -Eq 'install .*openssh-server' '$APT_LOG' && ! grep -Eq 'https?://|trusted[[:space:]]*=[[:space:]]*yes|allow-unauthenticated' '$APT_LOG'"

    MISSING_REPOSITORY="${TEST_ROOT}/missing"
    mkdir -p "$MISSING_REPOSITORY/packages"
    cp "$BUNDLE/package-manifest.json" "$MISSING_REPOSITORY/package-manifest.json"
    first_package=$(python3 - "$MISSING_REPOSITORY/package-manifest.json" <<'PYEOF'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["packages"][0]["filename"])
PYEOF
)
    rm -f -- "$MISSING_REPOSITORY/$first_package"
    check "offline installer rejects a missing package before invoking APT" \
        sh -c "! env PATH='${MOCK_BIN}:/usr/bin:/bin' SIGIL_OFFLINE_INSTALL_TEST_MODE=1 SIGIL_OS_RELEASE_FILE='${OS_RELEASE}' SIGIL_APT_TEST_LOG='${APT_LOG}' bash '$INSTALLER' '$MISSING_REPOSITORY' >/dev/null 2>&1"

    WRONG_VERSION="${TEST_ROOT}/wrong-version"
    mkdir -p "$WRONG_VERSION"
    cp "$BUNDLE/package-manifest.json" "$WRONG_VERSION/package-manifest.json"
    python3 - "$WRONG_VERSION/package-manifest.json" <<'PYEOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["bundle_version"] = "2099.01.01.1"
path.write_text(json.dumps(manifest), encoding="utf-8")
PYEOF
    check "offline installer rejects a bundle version incompatible with the contract" \
        sh -c "! env PATH='${MOCK_BIN}:/usr/bin:/bin' SIGIL_OFFLINE_INSTALL_TEST_MODE=1 SIGIL_OS_RELEASE_FILE='${OS_RELEASE}' SIGIL_APT_TEST_LOG='${APT_LOG}' bash '$INSTALLER' '$WRONG_VERSION' >/dev/null 2>&1"
fi

printf '\nOffline hardware packages: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
