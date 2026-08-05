# Offline package manufacturing

SIGIL Flash owns the complete lifecycle of the offline APT repository used to
manufacture Raspberry Pi OS images. SIGIL Hardware supplies the package
contracts under `sigil-hardware/manifests/offline-package-contract*.json`:
the canonical `offline-package-contract.json` (Debian, arm64, official
64-bit image) and any `offline-package-contract.<variant>.json` sibling
(e.g. `.armhf.json` -- Raspbian, armhf, official 32-bit image). Raspbian is
Raspberry Pi Foundation's own ARMv6-compatible rebuild of the full archive;
it exists because vanilla Debian armhf targets ARMv7+ and would not run on
the original Pi Zero/Zero W/1. Add a new architecture by dropping in another
`offline-package-contract.<variant>.json` -- the build and payload scripts
pick it up automatically, nothing else needs to change.

## Build

The builder uses isolated APT state and an empty dpkg status database so APT
resolves the full dependency closure instead of relying on packages
installed on the manufacturing host.

```bash
./scripts/build-offline-repository.sh \
  --contract sigil-hardware/manifests/offline-package-contract.json \
  --base-image ../artifacts/base-images/2026-06-18-raspios-trixie-arm64-lite.img.xz \
  --output artifacts/offline-packages/trixie-arm64
./scripts/build-offline-repository.sh --output artifacts/offline-packages/trixie-arm64 --rebuild

# 32-bit / armhf (Zero W, Zero 2 W in 32-bit mode, Pi 1-4 in 32-bit mode):
./scripts/build-offline-repository.sh \
  --contract sigil-hardware/manifests/offline-package-contract.armhf.json \
  --base-image ../artifacts/base-images/2026-06-18-raspios-trixie-armhf-lite.img.xz \
  --output artifacts/offline-packages/trixie-armhf
```

This needs real `apt-get`, `dpkg-scanpackages`, `apt-ftparchive` and
`dpkg-deb` -- Debian packaging tools with no native equivalent on non-Debian
distros. On a host missing any of them, the script detects that automatically
and re-executes itself inside a throwaway `debian:trixie` Docker container
(same arguments, output still lands owned by your user); it prints which
path it took. `setup.sh` installs Docker on non-Debian systems for exactly
this. Set `SIGIL_OFFLINE_BUILDER_IN_CONTAINER=1` yourself only if you're
already inside an equivalent Debian environment and want to skip the
re-exec check.

The builder verifies the exact base-image filename and SHA-256 from the
contract, then extracts its Deb822 source definitions and Debian/Raspbian /
Raspberry Pi archive keyrings read-only. The primary Raspberry Pi archive may
use a documented mirror transport, but its `InRelease` must authenticate with
the keyring from the official image. Host keyrings are not trusted implicitly.

## Payloads go stale -- always rebuild after touching sigil-hardware/

`build-flasher-payload.sh` copies files into `artifacts/payloads/*` at build
time; it does not link them. Editing anything under `sigil-hardware/` (e.g.
`scripts/install-offline-packages.sh`, which runs *inside the chroot at flash
time*) has no effect until the payload is rebuilt. Run this after every
change, before flashing:

```bash
./scripts/rebuild-payloads.sh
```

It rebuilds `sigil-hardware-payload` (canonical) plus one
`sigil-hardware-payload-<variant>` per `offline-package-contract.<variant>.json`
found. Use `SIGIL_PAYLOAD_ALLOW_DIRTY=true` while iterating locally with
uncommitted `sigil-hardware/` changes; leave it unset for a real
manufacturing build so the payload's `source_commit` is trustworthy.

Generated output is ignored by Git:

```text
artifacts/offline-packages/trixie-arm64/
├── packages/
│   └── *.deb
├── Packages
├── Packages.gz
├── Release
├── Release.gpg
├── InRelease
├── checksums.sha256
├── package-manifest.json
└── sources-snapshot/
    ├── debian.sources
    ├── raspi.sources
    ├── sources-metadata.json
    ├── keyring-metadata.json
    └── keyrings/
```

The manifest records contract schema/hash, bundle version, base-image
filename/hash, Debian release, architecture, generation time, source/keyring
provenance, every package/version, direct/resolved counts, total size and
Python dependency mapping. `checksums.sha256` covers exactly the packages,
indexes, signatures, manifest and source snapshot.

## Validation and UI lifecycle

Motor SIGIL accepts `--offline-packages <directory>`. Plan/validate checks the
contract, bundle/base-image compatibility, signatures, source/keyring metadata,
hashes, both indexes, real `.deb` control metadata, architecture, distribution,
counts, size and complete package closure. A dry-run ends after validation and
reports:

```text
Offline package repository validated.
```

The desktop UI exposes Detect, Build, Rebuild and Validate actions and displays
package count, transitive dependency count, architecture, distribution, size
and manifest state separately from Base Image, SIGIL Payload, Provision and
Secrets.

## Real image preparation

After the raw image has been written, the elevated writer:

1. Reprobes and mounts boot plus root partitions.
2. Copies the hardware payload and validated repository to
   `/opt/sigil/offline-repo`.
3. Bind-mounts `/dev`, `/proc` and `/sys` and installs `policy-rc.d` temporarily.
4. Uses `qemu-aarch64-static` when the manufacturing host is not ARM64.
5. Runs `install.sh --offline-repo /opt/sigil/offline-repo` inside the image.
6. Restores temporary files, synchronizes and unmounts in reverse order.

No dependency installation is deferred to first boot.

## Test commands

```bash
./tests/test_offline_package_manager.sh
./tests/test_offline_ui.py
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --all-targets --all-features --locked --offline
```
