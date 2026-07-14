# Sigil OS — Offline Flasher (Linux Only)

## Overview

The Sigil OS offline flasher creates a bootable MicroSD for Sigil devices
by injecting `sigil-hardware` payload into a Raspberry Pi OS base image.

This replaces `pi-gen/stage-sigil` as the installation method. pi-gen remains
as legacy/reference until the flasher is validated as functionally equivalent.

## Architecture

```
Linux PC operator
  |
  +-- sigil-flasher
  |     |
  |     +-- selects Raspberry Pi OS base .img / .img.xz
  |     +-- decompresses/validates image
  |     +-- writes image to MicroSD (sudo)
  |     +-- sync & reprobe partitions
  |     +-- mounts boot + rootfs (sudo)
  |     +-- injects sigil-hardware payload
  |     +-- installs dependencies from local .deb cache (chroot)
  |     +-- applies system config
  |     +-- enables/disables services (systemctl --root)
  |     +-- writes sigil_provision.json to boot
  |     +-- prepares minimal firstboot
  |     +-- sync + unmount
  |
  +-- Raspberry Pi boots already prepared
        |
        +-- firstboot finalizes:
              - machine-id
              - hostname
              - device.json
              - panel.env
              - cleanup
              - lightweight validation

No apt online during flashing.
No apt online in firstboot.
Firstboot does NOT install packages, clone repos, or download.
```

## Requirements

- **OS:** Linux only (x86_64 or aarch64)
- **Python:** 3.8+
- **Privileges:** sudo (for writing SD, mounting, chroot)
- **Base image:** Raspberry Pi OS Lite (Bookworm) — 32-bit or 64-bit
- **Dependencies:** `lsblk`, `blkid`, `mount`, `umount`, `partprobe`, `udevadm`,
  `losetup` (for image loopback)

## Manifests (source of truth)

All installation specs live in `sigil-hardware/manifests/`:

| File | Purpose |
|---|---|
| `apt-packages.txt` | Required apt packages |
| `install-layout.json` | File copy mapping (source -> destination) |
| `services.json` | Systemd enable/disable manifest |
| `system-config.json` | Boot config, PulseAudio, user, state files |

These manifests are the canonical reference. pi-gen and install.sh are legacy.

## Phase 1 — Dry Run

The current implementation is Phase 1: dry-run only.

```
python3 flasher/sigil-flasher.py --base-image /path/to/raspios.img
python3 flasher/sigil-flasher.py --base-image /path/to/raspios.img.xz --device /dev/mmcblk0
```

Dry-run validates paths, loads manifests, and prints what it **would** do.
No writes, no mounts, no sudo, no chroot.

## Service management

Services are enabled/disabled offline via `systemctl --root=<rootfs>`.
Fallback: manual symlinks in `multi-user.target.wants/`.

| Action | Services |
|---|---|
| Enable | NetworkManager, bluetooth-panel, bt-connect, radio-stream, sigil-leds, wifi-fallback |
| Disable | hostapd, dnsmasq |
| Unmask | hostapd, dnsmasq (wifi-fallback controls them at runtime) |

## Provisioning

The flasher writes `boot/sigil_provision.json` (operator-provided device identity):

```json
{
  "serial_number": "SIGIL-Z2W-2026-0001",
  "model": "Sigil-Streamer-v1",
  "batch": "LOTE-2026-A"
}
```

Firstboot moves it to `/etc/sigil/device.json` and generates:
- Unique machine-id
- Hostname from serial (or CPU serial fallback)
- `/etc/sigil/panel.env` with random SECRET_KEY
- Cleans up provisioning file from boot

## pi-gen status

pi-gen is **legacy/reference** until the flasher produces a functionally
equivalent SD. Do NOT delete pi-gen. Do NOT modify pi-gen.

Validation checklist for replacing pi-gen:
1. SD created by flasher passes offline validation
2. Raspberry Pi boots cleanly with firstboot
3. Core functions verified: panel, AP fallback, WiFi, Bluetooth, radio, LEDs
4. Security baseline confirmed
5. Result reproducible on 2+ clean SDs
