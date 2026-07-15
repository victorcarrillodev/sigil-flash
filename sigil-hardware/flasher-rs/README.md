# SIGIL flasher-rs contract

`flasher-rs` is the Linux-only, non-interactive validation engine between an
immutable Raspberry Pi OS base image, a generated SIGIL installation payload,
external provisioning data, and an operator-selected output target. It remains
a dry-run engine: it does not write images, mount filesystems, or invoke
privileged tools.

## Release input

The approved base image is:

- file: `2026-06-18-raspios-trixie-arm64-lite.img.xz`
- SHA-256: `acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3`
- OS: Raspberry Pi OS Lite, Debian 13 Trixie, arm64
- target: Raspberry Pi Zero 2 W

Both `.img.xz` and `.img` are accepted as immutable input files. The checksum
passed with `--base-image-sha256` always describes the exact file passed with
`--base-image`; a compressed checksum cannot be reused for a decompressed file.
Dry-run validation hashes `.img.xz` directly and does not decompress it.

## Independent inputs

- `--base-image`: official immutable image or controlled test fixture.
- `--base-image-sha256`: required expected SHA-256; mismatches are fatal.
- `--payload`: generated directory containing `payload-manifest.json`; never a
  Git checkout.
- `--offline-packages`: manufacturing-owned local APT repository whose
  manifest, indexes, package metadata, counts and hashes match the package
  contract embedded in the payload.
- `--provision`: external JSON containing factory identity; never a secret.
- `--target-device`: operator-selected block device reference or regular-file
  fixture. Dry-run never writes it.

Build a payload from the sibling `sigil-hardware` project with:

```bash
bash scripts/build-flasher-payload.sh \
  ../artifacts/payloads/sigil-hardware-payload
```

The selection source is `manifests/flasher-payload-files.txt`. The generated
manifest records the source commit, Trixie/arm64 target, exact filename set,
modes, and per-file SHA-256 values. Extra, missing, modified, symlinked, unsafe,
development, test, report, cache, credential, or temporary files are rejected.

## Provision contract

`--provision` is UTF-8 JSON without BOM and at most 4096 bytes. Required fields:

- `_schema_version`: contract version, currently `1.0`.
- `serial_number`: stable factory serial; 1–64 alphanumeric, `-`, `_`, or `.`.
- `model`: product family, 1–64 safe characters (for example `Sigil-Streamer`).
- `model_version`: hardware revision, 1–32 safe characters (for example `v1`).
- `batch`: traceability batch, 1–64 characters.
- `capabilities.i2s_dac`: required strict boolean. `true` declares that this
  manufactured device physically includes a PCM5102A-class I2S DAC.

The only backward-compatible model mapping is `Sigil-Streamer-v1 → i2s_dac=true`.
No ALSA card, PulseAudio sink, IDLE/SUSPENDED state, or successful silent write
can create this capability.

Unknown fields and keys representing API keys, passwords, tokens,
authorization, or secrets are rejected. The token is never part of provision
JSON. Provisioning is passed by file, and paths containing spaces remain one
argument.

## Safe validation

```bash
cargo run -- apply \
  --base-image ../artifacts/base-images/2026-06-18-raspios-trixie-arm64-lite.img.xz \
  --base-image-sha256 acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3 \
  --payload ../artifacts/payloads/sigil-hardware-payload \
  --offline-packages ../artifacts/offline-packages/trixie-arm64 \
  --provision examples/sigil_provision.sample.json \
  --target-device /tmp/sigil-target-fixture.img \
  --dry-run
```

This engine intentionally remains non-mutating. The privileged writer in
`sigil-flash` performs real image writing, repository injection and chroot
installation only after these validations pass.

## Physical audio limitation

ALSA and PulseAudio can verify only software routing. A PCM5102A exposes no
standard signal proving that the board, amplifier, speaker, or cable is
physically present. Real physical detection requires separate hardware such as
a GPIO presence line, jack detect, or amplifier fault/presence signal.
