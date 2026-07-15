pub mod model;
pub mod offline;
pub mod plan;
pub mod validate;

use model::{EngineStatus, Plan, ValidationResult};
use std::path::PathBuf;

/// The Sigil Flasher Engine — reusable customization engine for Sigil OS.
///
/// This engine is designed to be invoked by an external application
/// (e.g., a GUI flasher). It does not write images or detect devices;
/// the caller is responsible for preparing the environment.
#[derive(Debug, Clone)]
pub struct Engine {
    base_image: PathBuf,
    base_image_sha256: Option<String>,
    payload: PathBuf,
    offline_packages: Option<PathBuf>,
    target_device: Option<PathBuf>,
    provision: Option<PathBuf>,
    secrets: Option<PathBuf>,
}

impl Engine {
    /// Create a new engine with the required base image and payload paths.
    pub fn new(base_image: PathBuf, payload: PathBuf) -> Self {
        Self {
            base_image,
            base_image_sha256: None,
            payload,
            offline_packages: None,
            target_device: None,
            provision: None,
            secrets: None,
        }
    }

    /// Set the expected SHA-256 for the immutable base image.
    pub fn with_base_image_sha256(mut self, checksum: String) -> Self {
        self.base_image_sha256 = Some(checksum);
        self
    }

    /// Set the target device (block device path, e.g. /dev/sdX).
    pub fn with_target_device(mut self, device: PathBuf) -> Self {
        self.target_device = Some(device);
        self
    }

    /// Set the manufacturing-owned offline APT repository.
    pub fn with_offline_packages(mut self, repository: PathBuf) -> Self {
        self.offline_packages = Some(repository);
        self
    }

    /// Set the provisioning file path (sigil_provision.json).
    pub fn with_provision(mut self, provision: PathBuf) -> Self {
        self.provision = Some(provision);
        self
    }

    /// Set the protected manufacturing secret input (sigil_secrets.json).
    pub fn with_secrets(mut self, secrets: PathBuf) -> Self {
        self.secrets = Some(secrets);
        self
    }

    // ── Accessors for the CLI/formatter ────────────────────────────────
    pub fn base_image(&self) -> &std::path::Path {
        &self.base_image
    }
    pub fn payload(&self) -> &std::path::Path {
        &self.payload
    }
    pub fn base_image_sha256(&self) -> Option<&str> {
        self.base_image_sha256.as_deref()
    }
    pub fn target_device(&self) -> &Option<PathBuf> {
        &self.target_device
    }
    pub fn offline_packages(&self) -> &Option<PathBuf> {
        &self.offline_packages
    }
    pub fn provision(&self) -> &Option<PathBuf> {
        &self.provision
    }
    pub fn secrets(&self) -> &Option<PathBuf> {
        &self.secrets
    }

    // ── Engine Commands ────────────────────────────────────────────────

    /// Generate a full customization plan describing all operations.
    pub fn plan(&self) -> Plan {
        plan::build_plan(
            &self.base_image,
            self.base_image_sha256.as_deref(),
            &self.payload,
            &self.offline_packages,
            &self.target_device,
            &self.provision,
            &self.secrets,
        )
    }

    /// Validate engine inputs and structure without generating a full plan.
    pub fn validate(&self) -> ValidationResult {
        validate::validate_inputs(
            &self.base_image,
            self.base_image_sha256.as_deref(),
            &self.payload,
            &self.offline_packages,
            &self.target_device,
            &self.provision,
            &self.secrets,
        )
    }

    /// Execute the customization plan.
    ///
    /// In Phase 2 this runs in dry-run mode only — it validates inputs and
    /// returns the plan that would be applied. No destructive operations.
    pub fn apply(&self) -> Result<Plan, String> {
        let result = self.validate();
        if !result.valid {
            let errors: Vec<String> = result
                .items
                .iter()
                .filter(|i| matches!(i.severity, model::Severity::Error))
                .map(|i| i.message.clone())
                .collect();
            return Err(format!("Validation failed: {}", errors.join("; ")));
        }
        Ok(plan::build_plan(
            &self.base_image,
            self.base_image_sha256.as_deref(),
            &self.payload,
            &self.offline_packages,
            &self.target_device,
            &self.provision,
            &self.secrets,
        ))
    }

    /// Return engine metadata and capabilities.
    pub fn status() -> EngineStatus {
        EngineStatus {
            name: String::from("sigil-flasher-engine"),
            version: "0.3.0",
            description: "Sigil OS offline image-contract engine for verified Raspberry Pi OS and generated payloads.",
            phase: "Phase 3 — validated contract (dry-run only, no destructive operations)",
            capabilities: vec![
                "plan — generate a full customization plan",
                "validate — verify base-image checksum, payload manifest, provision, and target",
                "apply — validate and render the plan (dry-run only)",
                "offline APT repository integrity, architecture, distribution, and dependency validation",
                ".img and .img.xz immutable base-image inputs",
                "status — show engine capabilities",
            ],
            services_enable: model::SERVICES_ENABLE,
            services_disable: model::SERVICES_DISABLE,
        }
    }
}
