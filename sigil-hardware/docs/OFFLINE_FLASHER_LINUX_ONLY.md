# SIGIL Hardware offline package contract

`sigil-hardware` defines what Raspberry Pi OS needs; it does not manufacture
or store a package bundle.

## Canonical source

`manifests/offline-package-contract.json` is the only package source of truth.
It pins the schema, Debian distribution, architecture, version policy, required
packages and optional profiles. `install.sh` and the flasher consume this file;
neither carries a second package list.

The repository must never contain `.deb` files, an APT `Packages` index, a
generated repository, downloaded package caches, or build artifacts.

## Offline installer

Run inside an already-mounted target image:

```bash
sudo ./install.sh --offline-repo /opt/sigil/offline-repo
```

`scripts/install-offline-packages.sh` independently validates the contract,
repository manifest, distribution, architecture, indexes, package metadata and
SHA-256 checksums. It creates a temporary `file://` APT source with isolated
APT lists and cache, verifies every required candidate, installs without
recommends, verifies dpkg state and removes the temporary source. It never
configures an HTTP(S) source and is safe to run again.

Package downloading, dependency resolution, repository generation and SD-image
injection belong to `sigil-flash`.

## First boot boundary

Manufacturing installs packages and system payload before the SD is removed
from the workstation. First boot is limited to identity, hostname, protected
secrets/PIN, service enablement and hardware-specific configuration. It must
not run `apt install`, `pip install`, clone a repository or download runtime
dependencies.

## Validation

```bash
./tests/test_final_offline_packages.sh
cargo test --manifest-path flasher-rs/Cargo.toml --locked --offline
```

The Rust flasher validates the same contract and reports `Offline package
repository validated.` during dry-run; it performs no installation in dry-run.
