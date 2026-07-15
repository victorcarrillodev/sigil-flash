use crate::errors::{AppError, AppResult};
use flasher_rs::offline::{validate_repository, OfflineRepositorySummary};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OfflinePackageStatus {
    pub path: String,
    pub detected: bool,
    pub valid: bool,
    pub bundle_version: String,
    pub package_contract_schema_version: String,
    pub direct_package_count: usize,
    pub resolved_package_count: usize,
    pub architecture: String,
    pub distribution: String,
    pub base_image_name: String,
    pub base_image_sha256: String,
    pub base_image_compatible: bool,
    pub total_bytes: u64,
    pub keyring_status: String,
    pub sources_status: String,
    pub unresolved_packages: Vec<String>,
    pub manifest_status: String,
    pub message: String,
}

pub struct OfflinePackageService {
    contract: PathBuf,
    builder: PathBuf,
    default_bundle: PathBuf,
}

impl OfflinePackageService {
    pub fn new() -> AppResult<Self> {
        Self::from_root(&locate_flash_root()?)
    }

    fn from_root(root: &Path) -> AppResult<Self> {
        let contract = root
            .join("sigil-hardware")
            .join("manifests")
            .join("offline-package-contract.json");
        let builder = root.join("scripts").join("build-offline-repository.sh");
        if !contract.is_file() {
            return Err(AppError::Validation(format!(
                "offline package contract not found: {}",
                contract.display()
            )));
        }
        if !builder.is_file() {
            return Err(AppError::Validation(format!(
                "offline package builder not found: {}",
                builder.display()
            )));
        }
        Ok(Self {
            contract,
            builder,
            default_bundle: root
                .join("artifacts")
                .join("offline-packages")
                .join("trixie-arm64"),
        })
    }

    pub fn status(
        &self,
        path: Option<&str>,
        base_image: Option<&str>,
        base_image_sha256: Option<&str>,
    ) -> OfflinePackageStatus {
        let repository = path.map_or_else(|| self.default_bundle.clone(), PathBuf::from);
        if !repository.is_dir() {
            return OfflinePackageStatus {
                path: repository.to_string_lossy().to_string(),
                detected: false,
                valid: false,
                bundle_version: "unknown".into(),
                package_contract_schema_version: "unknown".into(),
                direct_package_count: 0,
                resolved_package_count: 0,
                architecture: "unknown".into(),
                distribution: "unknown".into(),
                base_image_name: "unknown".into(),
                base_image_sha256: "unknown".into(),
                base_image_compatible: false,
                total_bytes: 0,
                keyring_status: "missing".into(),
                sources_status: "missing".into(),
                unresolved_packages: Vec::new(),
                manifest_status: "missing".into(),
                message: "No se detectó el bundle offline. Usa Construir bundle.".into(),
            };
        }
        match validate_repository(&repository, &self.contract) {
            Ok(summary) => status_from_summary(summary, base_image, base_image_sha256),
            Err(error) => OfflinePackageStatus {
                path: repository.to_string_lossy().to_string(),
                detected: true,
                valid: false,
                bundle_version: "unknown".into(),
                package_contract_schema_version: "unknown".into(),
                direct_package_count: 0,
                resolved_package_count: 0,
                architecture: "unknown".into(),
                distribution: "unknown".into(),
                base_image_name: "unknown".into(),
                base_image_sha256: "unknown".into(),
                base_image_compatible: false,
                total_bytes: directory_size(&repository).unwrap_or(0),
                keyring_status: "invalid".into(),
                sources_status: "invalid".into(),
                unresolved_packages: Vec::new(),
                manifest_status: "invalid".into(),
                message: error,
            },
        }
    }

    pub fn validate(
        &self,
        path: Option<&str>,
        base_image: Option<&str>,
        base_image_sha256: Option<&str>,
    ) -> AppResult<OfflinePackageStatus> {
        let status = self.status(path, base_image, base_image_sha256);
        if status.valid {
            Ok(status)
        } else {
            Err(AppError::Validation(status.message))
        }
    }

    pub async fn build(&self, rebuild: bool) -> AppResult<OfflinePackageStatus> {
        let mut command = Command::new("bash");
        command
            .arg(&self.builder)
            .arg("--contract")
            .arg(&self.contract)
            .arg("--output")
            .arg(&self.default_bundle)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if rebuild {
            command.arg("--rebuild");
        }
        let output = command.output().await.map_err(|error| {
            AppError::Internal(format!("start offline package builder: {error}"))
        })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            return Err(AppError::Validation(format!(
                "No se pudo construir el bundle offline: {stderr}"
            )));
        }
        self.validate(None, None, None)
    }
}

fn status_from_summary(
    summary: OfflineRepositorySummary,
    base_image: Option<&str>,
    base_image_sha256: Option<&str>,
) -> OfflinePackageStatus {
    let selected_name = base_image.and_then(|path| Path::new(path).file_name()?.to_str());
    let name_compatible = match selected_name {
        Some(name) => name == summary.base_image_name,
        None => true,
    };
    let hash_compatible = match base_image_sha256 {
        Some(digest) => digest.eq_ignore_ascii_case(&summary.base_image_sha256),
        None => true,
    };
    let base_image_compatible = name_compatible && hash_compatible;
    let message = if base_image_compatible {
        "Repositorio offline validado y compatible con la imagen base.".into()
    } else {
        format!(
            "El bundle {} requiere {} con SHA-256 {}.",
            summary.bundle_version, summary.base_image_name, summary.base_image_sha256
        )
    };
    OfflinePackageStatus {
        path: summary.path,
        detected: true,
        valid: base_image_compatible,
        bundle_version: summary.bundle_version,
        package_contract_schema_version: summary.package_contract_schema_version,
        direct_package_count: summary.direct_package_count,
        resolved_package_count: summary.resolved_package_count,
        architecture: summary.architecture,
        distribution: summary.distribution,
        base_image_name: summary.base_image_name,
        base_image_sha256: summary.base_image_sha256,
        base_image_compatible,
        total_bytes: summary.total_bytes,
        keyring_status: summary.keyring_status,
        sources_status: summary.sources_status,
        unresolved_packages: summary.unresolved_packages,
        manifest_status: summary.manifest_status,
        message,
    }
}

fn locate_flash_root() -> AppResult<PathBuf> {
    if let Ok(value) = std::env::var("SIGIL_FLASH_ROOT") {
        let root = PathBuf::from(value);
        if root.is_dir() {
            return Ok(root);
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| AppError::Validation("cannot resolve sigil-flash root".into()))
}

fn directory_size(path: &Path) -> std::io::Result<u64> {
    let mut total = 0_u64;
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            total = total.saturating_add(directory_size(&entry.path())?);
        } else if metadata.is_file() {
            total = total.saturating_add(metadata.len());
        }
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_should_report_missing_bundle_without_mutating_disk() {
        let root =
            std::env::temp_dir().join(format!("sigil-offline-service-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sigil-hardware/manifests")).expect("manifest directory");
        std::fs::create_dir_all(root.join("scripts")).expect("scripts directory");
        std::fs::write(
            root.join("sigil-hardware/manifests/offline-package-contract.json"),
            "{}",
        )
        .expect("contract");
        std::fs::write(
            root.join("scripts/build-offline-repository.sh"),
            "#!/bin/sh\n",
        )
        .expect("builder");
        let service = OfflinePackageService::from_root(&root).expect("service");

        let status = service.status(None, None, None);

        assert!(!status.detected);
        let _ = std::fs::remove_dir_all(root);
    }
}
