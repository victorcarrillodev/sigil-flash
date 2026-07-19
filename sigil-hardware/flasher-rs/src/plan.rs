use crate::model::{self, Plan, PlanSection};
use crate::offline;
use crate::validate::{load_provision, load_secrets};

/// Build a full customization plan from engine state.
pub fn build_plan(
    base_image: &std::path::Path,
    base_image_sha256: Option<&str>,
    payload: &std::path::Path,
    offline_packages: &Option<std::path::PathBuf>,
    target_device: &Option<std::path::PathBuf>,
    provision: &Option<std::path::PathBuf>,
    secrets: &Option<std::path::PathBuf>,
) -> Plan {
    let mut sections: Vec<PlanSection> = Vec::new();

    // ── 1. Overview ────────────────────────────────────────────────────
    sections.push(PlanSection {
        title: "OVERVIEW".into(),
        lines: vec![
            format!("Base image: {}", base_image.display()),
            format!(
                "Base image SHA-256: {}",
                base_image_sha256.unwrap_or("not provided")
            ),
            format!("Base image format: {}", base_image_format(base_image)),
            "Base OS contract: Raspberry Pi OS Lite 64-bit, Debian 13 Trixie, arm64".into(),
            "Target hardware: Raspberry Pi Zero 2 W".into(),
            format!("Target device: {}", target_device_str(target_device)),
            "Boot partition: would detect/mount".into(),
            "Rootfs partition: would detect/mount".into(),
            format!("Generated payload path: {}", payload.display()),
            "Payload contract: payload-manifest.json with per-file SHA-256 and mode".into(),
        ],
    });

    // ── 2. Offline APT repository ────────────────────────────────────
    let contract_path = payload.join("manifests/offline-package-contract.json");
    let mut offline_lines = match offline::load_contract(payload) {
        Ok(contract) => vec![
            format!(
                "Canonical contract: {} required, {} optional packages",
                contract
                    .packages
                    .iter()
                    .filter(|package| package.required)
                    .count(),
                contract
                    .packages
                    .iter()
                    .filter(|package| !package.required)
                    .count()
            ),
            format!("Bundle version: {}", contract.bundle_version),
            format!(
                "Target: {}-{}",
                contract.distribution_codename, contract.architecture
            ),
        ],
        Err(error) => vec![format!("Canonical package contract invalid: {error}")],
    };
    match offline_packages {
        Some(repository) => match offline::validate_repository(repository, &contract_path) {
            Ok(summary) => offline_lines.extend([
                "Offline package repository validated.".into(),
                format!("Repository: {}", summary.path),
                format!(
                    "Packages: {} direct, {} resolved",
                    summary.direct_package_count, summary.resolved_package_count
                ),
                format!("Bundle version: {}", summary.bundle_version),
                format!("Base image: {}", summary.base_image_name),
                format!(
                    "Distribution/architecture: {}-{}",
                    summary.distribution, summary.architecture
                ),
            ]),
            Err(error) => offline_lines.push(format!("Offline repository invalid: {error}")),
        },
        None => offline_lines.push("Offline repository: not provided".into()),
    }
    sections.push(PlanSection {
        title: "OFFLINE DEPENDENCIES".into(),
        lines: offline_lines,
    });

    // ── 3. User and Groups ─────────────────────────────────────────────
    sections.push(PlanSection {
        title: "USER AND GROUPS".into(),
        lines: vec![
            format!(
                "would create user {} (UID {}, shell {}, home {}, group {})",
                model::USER_NAME,
                model::USER_UID,
                model::USER_SHELL,
                model::USER_HOME,
                model::USER_GROUP,
            ),
            "would not set a factory user password; panel access stays in the separate protected secret contract"
                .into(),
            format!(
                "would add {} to groups: {}",
                model::USER_NAME,
                model::USER_GROUPS.join(", "),
            ),
            format!("would chown -R sigil:sigil {}", model::USER_HOME),
        ],
    });

    // ── 4. Permissions ────────────────────────────────────────────────
    sections.push(PlanSection {
        title: "PERMISSIONS".into(),
        lines: vec![
            "would chmod +x /usr/local/bin/*.sh".into(),
            "would chmod 440 /etc/sudoers.d/sigil-network".into(),
            "would chmod 644 for state/log files".into(),
        ],
    });

    // ── 5. State Directories ──────────────────────────────────────────
    sections.push(PlanSection {
        title: "STATE DIRECTORIES".into(),
        lines: model::STATE_DIRECTORIES
            .iter()
            .map(|d| d.to_string())
            .collect(),
    });

    // ── 6. State Files ────────────────────────────────────────────────
    sections.push(PlanSection {
        title: "STATE FILES".into(),
        lines: model::STATE_FILES
            .iter()
            .map(|(path, owner, mode)| format!("{} (owner {}, mode {})", path, owner, mode))
            .collect(),
    });

    // ── 7. Log Files ──────────────────────────────────────────────────
    sections.push(PlanSection {
        title: "LOG FILES".into(),
        lines: model::LOG_FILES
            .iter()
            .map(|(path, owner, mode)| format!("{} (owner {}, mode {})", path, owner, mode))
            .collect(),
    });

    sections.push(PlanSection {
        title: "PERSISTENT DIAGNOSTICS".into(),
        lines: vec![
            "would enable Storage=persistent after the vendor volatile override".into(),
            "would cap persistent journal use at 64 MiB and keep 128 MiB free".into(),
            "would cap journal files at 8 MiB with a maximum retention of 14 days".into(),
            "would rotate legacy SIGIL logs daily, at 1 MiB, retaining four compressed files"
                .into(),
            "service stdout and stderr would be captured by journald without credentials".into(),
        ],
    });

    // ── 8. PulseAudio Config ──────────────────────────────────────────
    sections.push(PlanSection {
        title: "PULSEAUDIO CONFIG".into(),
        lines: vec![
            "would append 'load-module module-switch-on-connect' to /etc/pulse/default.pa".into(),
        ],
    });

    // ── 9. Hostapd Config ─────────────────────────────────────────────
    sections.push(PlanSection {
        title: "HOSTAPD CONFIG".into(),
        lines: vec![
            "would set DAEMON_CONF=\"/etc/hostapd/hostapd.conf\" in /etc/default/hostapd".into(),
        ],
    });

    // ── 10. Systemd Unmask ────────────────────────────────────────────
    sections.push(PlanSection {
        title: "SYSTEMD UNMASK".into(),
        lines: model::SERVICES_UNMASK
            .iter()
            .map(|s| format!("would unmask {s}"))
            .collect(),
    });

    // ── 11. Machine-ID Cleanup ────────────────────────────────────────
    sections.push(PlanSection {
        title: "MACHINE-ID CLEANUP".into(),
        lines: vec![
            "would clear /etc/machine-id".into(),
            "would clear /var/lib/dbus/machine-id if present".into(),
        ],
    });

    // ── 12. Panel Env ─────────────────────────────────────────────────
    sections.push(PlanSection {
        title: "PANEL ENV".into(),
        lines: vec![
            "would create /etc/sigil/panel.env placeholder (root:root, mode 600)".into(),
            "firstboot generates real SIGIL_SECRET_KEY".into(),
        ],
    });

    // ── 13. Provisioning Behavior ─────────────────────────────────────
    let mut provisioning_lines = vec![
        provision_line(provision),
        "would atomically create /etc/sigil/device.conf (root:sigil, mode 0640)".into(),
        "would persist capabilities.i2s_dac as SIGIL_I2S_DAC_PRESENT=0|1 in /etc/sigil/audio.conf"
            .into(),
        "runtime device_id is CPU serial, then non-empty machine-id, then sigil-unknown".into(),
    ];
    if let Some(path) = provision {
        match load_provision(path) {
            Ok(identity) => provisioning_lines.extend([
                format!("serial_number: {}", identity.serial_number),
                format!("model: {}", identity.model),
                format!("model_version: {}", identity.model_version),
                format!("batch: {}", identity.batch),
                format!("capabilities.i2s_dac: {}", identity.capabilities.i2s_dac),
            ]),
            Err(message) => provisioning_lines.push(format!("invalid provision: {message}")),
        }
    }
    sections.push(PlanSection {
        title: "PROVISIONING BEHAVIOR".into(),
        lines: provisioning_lines,
    });

    let secret_lines = match secrets {
        Some(path) => match load_secrets(path) {
            Ok(document) => vec![
                "secret file supplied: yes".into(),
                "schema valid: yes".into(),
                "panel PIN configured: yes".into(),
                format!("panel PIN length: {} digits", document.panel_pin.len()),
                "future image injection: pending (dry-run engine does not write images)".into(),
            ],
            Err(_) => vec![
                "secret file supplied: yes".into(),
                "schema valid: no".into(),
                "panel PIN configured: no".into(),
            ],
        },
        None => vec![
            "secret file supplied: no".into(),
            "schema valid: no".into(),
            "panel PIN configured: no".into(),
        ],
    };
    sections.push(PlanSection {
        title: "PANEL ACCESS SECRET".into(),
        lines: secret_lines,
    });

    // ── 14. Firstboot Responsibilities ────────────────────────────────
    sections.push(PlanSection {
        title: "FIRSTBOOT RESPONSIBILITIES".into(),
        lines: model::FIRSTBOOT_RESPONSIBILITIES
            .iter()
            .map(|r| format!("- {r}"))
            .collect(),
    });

    // ── 15. Deferred to Later Phase ───────────────────────────────────
    sections.push(PlanSection {
        title: "DEFERRED TO LATER PHASE".into(),
        lines: model::DEFERRED_ITEMS
            .iter()
            .map(|(item, reason)| format!("  {item} — {reason}"))
            .collect(),
    });

    // ── 16. Services ──────────────────────────────────────────────────
    sections.push(PlanSection {
        title: "SERVICES".into(),
        lines: vec![
            format!("would enable: {}", model::SERVICES_ENABLE.join(", ")),
            format!("would disable: {}", model::SERVICES_DISABLE.join(", ")),
        ],
    });

    // ── 17. Config Files to Copy ──────────────────────────────────────
    sections.push(PlanSection {
        title: "CONFIG FILES TO COPY".into(),
        lines: model::CONFIG_COPIES
            .iter()
            .map(|c| format!("  {c}"))
            .collect(),
    });

    // ── 18. Boot Config Changes ───────────────────────────────────────
    sections.push(PlanSection {
        title: "BOOT CONFIG CHANGES".into(),
        lines: model::BOOT_CONFIG_CHANGES
            .iter()
            .map(|c| format!("  {c}"))
            .collect(),
    });

    Plan {
        title: "Phase 3 — verified image/payload contract (dry-run)".into(),
        sections,
    }
}

fn base_image_format(path: &std::path::Path) -> &'static str {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    if name.ends_with(".img.xz") {
        "compressed .img.xz (validated in place; no decompression during dry-run)"
    } else if name.ends_with(".img") {
        "uncompressed .img"
    } else {
        "unsupported"
    }
}

fn target_device_str(device: &Option<std::path::PathBuf>) -> String {
    match device {
        Some(path) => format!("operator-selected target: {}", path.display()),
        None => "not provided".to_string(),
    }
}

fn provision_line(provision: &Option<std::path::PathBuf>) -> String {
    match provision {
        Some(path) if path.exists() => {
            format!("would use operator-provided file: {} (exists)", path.display())
        }
        Some(path) => format!(
            "operator provided path for dry-run only: {} (missing; would require review before non-dry-run)",
            path.display()
        ),
        None => {
            "no provision file provided; default/no provisioning would be used".to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn plan_reports_the_bounded_persistent_diagnostics_contract() {
        let plan = build_plan(
            std::path::Path::new("/tmp/base.img"),
            None,
            std::path::Path::new("/tmp/payload"),
            &None,
            &None,
            &None,
            &None,
        );
        let diagnostics = plan
            .sections
            .iter()
            .find(|section| section.title == "PERSISTENT DIAGNOSTICS")
            .expect("persistent diagnostics section");

        assert_eq!(
            diagnostics.lines,
            vec![
                "would enable Storage=persistent after the vendor volatile override",
                "would cap persistent journal use at 64 MiB and keep 128 MiB free",
                "would cap journal files at 8 MiB with a maximum retention of 14 days",
                "would rotate legacy SIGIL logs daily, at 1 MiB, retaining four compressed files",
                "service stdout and stderr would be captured by journald without credentials",
            ]
        );
    }

    #[test]
    fn plan_displays_all_non_secret_identity_fields() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let provision_path = std::env::temp_dir().join(format!(
            "sigil-plan-provision-{unique}-{}.json",
            std::process::id()
        ));
        fs::write(
            &provision_path,
            br#"{"_schema_version":"1.0","serial_number":"SIGIL-TEST-42","model":"Sigil-Streamer","model_version":"v1","batch":"2026-TEST","capabilities":{"i2s_dac":true}}"#,
        )
        .expect("provision fixture");
        let plan = build_plan(
            std::path::Path::new("/tmp/base.img"),
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            std::path::Path::new("/tmp/payload"),
            &None,
            &None,
            &Some(provision_path.clone()),
            &None,
        );
        let output = plan
            .sections
            .iter()
            .flat_map(|section| section.lines.iter())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");
        assert!(output.contains("serial_number: SIGIL-TEST-42"));
        assert!(output.contains("model: Sigil-Streamer"));
        assert!(output.contains("model_version: v1"));
        assert!(output.contains("batch: 2026-TEST"));
        assert!(output.contains("capabilities.i2s_dac: true"));
        assert!(!output.to_ascii_lowercase().contains("token"));
        let _ = fs::remove_file(provision_path);
    }

    #[cfg(unix)]
    #[test]
    fn plan_reports_secret_contract_without_revealing_pin_or_path() {
        use std::os::unix::fs::PermissionsExt;
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "sigil-secret-plan-{unique}-{}.json",
            std::process::id()
        ));
        fs::write(
            &path,
            br#"{"_schema_version":"1.0","panel_pin":"80427159"}"#,
        )
        .expect("secret fixture");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("mode");
        let plan = build_plan(
            std::path::Path::new("/tmp/base.img"),
            None,
            std::path::Path::new("/tmp/payload"),
            &None,
            &None,
            &None,
            &Some(path.clone()),
        );
        let output = plan
            .sections
            .iter()
            .flat_map(|section| section.lines.iter())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");
        assert!(output.contains("panel PIN configured: yes"));
        assert!(!output.contains("80427159"));
        assert!(!output.contains(path.to_string_lossy().as_ref()));
        let _ = fs::remove_file(path);
    }
}
