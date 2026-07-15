# Offline package manufacturing

SIGIL Flash owns the complete lifecycle of the offline APT repository used to
manufacture Raspberry Pi OS images. SIGIL Hardware supplies only the canonical
contract at `sigil-hardware/manifests/offline-package-contract.json`.

## Build

The builder uses isolated APT state and an empty dpkg status database so APT
resolves the full ARM64 dependency closure instead of relying on packages
installed on the manufacturing host.

```bash
./scripts/build-offline-repository.sh \
  --base-image ../artifacts/base-images/2026-06-18-raspios-trixie-arm64-lite.img.xz
./scripts/build-offline-repository.sh --rebuild
```

The builder verifies the exact base-image filename and SHA-256 from the
canonical contract, then extracts its Deb822 source definitions and Debian /
Raspberry Pi archive keyrings read-only. The primary Raspberry Pi archive may
use a documented mirror transport, but its `InRelease` must authenticate with
the keyring from the official image. Host keyrings are not trusted implicitly.

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
