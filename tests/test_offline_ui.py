#!/usr/bin/env python3
"""Static UI contract tests for offline dependency manufacturing controls."""

from pathlib import Path


root = Path(__file__).resolve().parents[1]
panel = (root / "src/components/EnginePanel.tsx").read_text(encoding="utf-8")
service = (root / "src/services/engineService.ts").read_text(encoding="utf-8")
styles = (root / "src/index.css").read_text(encoding="utf-8")

checks = {
    "dedicated offline section": "Dependencias offline" in panel,
    "detect action": "Detectar bundle" in panel,
    "build action": "Construir bundle" in panel,
    "rebuild action": "Reconstruir bundle" in panel,
    "validate action": "Validar bundle" in panel,
    "bundle version metric": "<dt>Bundle</dt>" in panel and "bundle_version" in panel,
    "contract version metric": "<dt>Contrato</dt>" in panel and "package_contract_schema_version" in panel,
    "direct package metric": "<dt>Directos</dt>" in panel and "direct_package_count" in panel,
    "resolved package metric": "<dt>Resueltos</dt>" in panel and "resolved_package_count" in panel,
    "architecture metric": "Arquitectura" in panel,
    "distribution metric": "Distribución" in panel,
    "size metric": "Tamaño" in panel,
    "base image compatibility": "base_image_compatible" in panel,
    "keyring metadata status": "keyring_status" in panel,
    "source metadata status": "sources_status" in panel,
    "unresolved package status": "unresolved_packages" in panel,
    "manifest metric": "Manifiesto" in panel,
    "accessible async status": 'role={offlineStatus.valid ? "status" : "alert"}' in panel,
    "busy controls disabled": "onClick={detectOfflineBundle} disabled={busy}" in panel,
    "status command binding": "offline_packages_status" in service,
    "validate command binding": "offline_packages_validate" in service,
    "build command binding": "offline_packages_build" in service,
    "minimum action target": "min-height: 44px" in styles,
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"  {'ok  ' if passed else 'FAIL'} {name}")
print(f"\nOffline UI: {len(checks) - len(failed)} passed, {len(failed)} failed")
raise SystemExit(1 if failed else 0)
