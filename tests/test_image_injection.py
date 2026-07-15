#!/usr/bin/env python3
"""Static manufacturing-boundary tests for real image preparation."""

from pathlib import Path


root = Path(__file__).resolve().parents[1]
flash = (root / "src-tauri/src/services/flash_service.rs").read_text(encoding="utf-8")
engine_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in (root / "sigil-hardware/flasher-rs/src").glob("*.rs")
)
firstboot = (root / "sigil-hardware/scripts/firstboot.sh").read_text(encoding="utf-8")

checks = {
    "real writer validates bundle before injection": (
        "validate_repository(offline_packages, &package_contract)" in flash
        and flash.index("validate_repository(offline_packages, &package_contract)")
        < flash.index("copy_directory_contents(offline_packages, &repository_target)")
    ),
    "repository destination is fixed": 'join("opt/sigil/offline-repo")' in flash,
    "boot and root partitions are mounted": (
        "mount_partition_with_retry" in flash and "mount_checked(&boot_partition" in flash
    ),
    "chroot receives offline repository": (
        '"--offline-repo"' in flash and '"/opt/sigil/offline-repo"' in flash
    ),
    "image preparation mode is explicit": '.env("SIGIL_IMAGE_PREPARATION", "1")' in flash,
    "ARM64 emulation is checked": "qemu-aarch64-static es obligatorio" in flash,
    "package service startup is blocked in chroot": "policy-rc.d" in flash,
    "mount cleanup runs in reverse order": "while let Some(target) = mounted.pop()" in flash,
    "installation failure fails the flash": "return Err(e);" in flash,
    "dry-run engine has no chroot": 'Command::new("chroot")' not in engine_sources,
    "dry-run engine has no APT execution": 'Command::new("apt-get")' not in engine_sources,
    "firstboot has no package installation": (
        "apt-get install" not in firstboot
        and "apt install" not in firstboot
        and "pip install" not in firstboot
        and "pip3 install" not in firstboot
    ),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"  {'ok  ' if passed else 'FAIL'} {name}")
print(f"\nImage injection: {len(checks) - len(failed)} passed, {len(failed)} failed")
raise SystemExit(1 if failed else 0)
