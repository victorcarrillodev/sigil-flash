use crate::errors::{Result, SigilError};
use crate::services::bundle::{
    default_artifacts_root, project_root, resolve_bundle_payload, validate_variant_name, BundlePair,
    CANONICAL_CONTRACT,
};
use crate::services::offline_package::validate_offline_repository;
use std::path::PathBuf;
use std::process::Command;

fn contract_paths(variant: Option<&str>) -> Result<(PathBuf, PathBuf)> {
    let contract_name = match variant {
        None => CANONICAL_CONTRACT.to_string(),
        Some(v) => {
            validate_variant_name(v)?;
            format!("{}.{}", CANONICAL_CONTRACT, v)
        }
    };

    let repo = default_artifacts_root()
        .join("bundles")
        .join(format!("{}-repo", contract_name));
    let contract = project_root()
        .join("sigil-hardware/manifests")
        .join(format!("{}.json", contract_name));

    Ok((repo, contract))
}

/// Valida el repositorio APT de una variante contra el instalador real de
/// sigil-hardware, en su modo de prueba.
#[tauri::command]
pub fn get_bundle_status(variant: Option<String>) -> Result<String> {
    let (repo, contract) = contract_paths(variant.as_deref())?;
    validate_offline_repository(&repo, Some(&contract))
}

/// Resuelve el par bundle/payload que corresponde a una imagen concreta.
#[tauri::command]
pub fn resolve_bundle_for_image(image_name: String, variant: Option<String>) -> Result<BundlePair> {
    resolve_bundle_payload(&default_artifacts_root(), &image_name, variant.as_deref())
}

#[tauri::command]
pub fn rebuild_payloads_cmd() -> Result<String> {
    let script = project_root().join("scripts/rebuild-payloads.sh");
    if !script.is_file() {
        return Err(SigilError::Internal(format!(
            "Script no encontrado: '{}'. Ejecute la aplicación desde el árbol del proyecto.",
            script.display()
        )));
    }

    let output = Command::new("bash").arg(&script).output()?;
    if !output.status.success() {
        return Err(SigilError::Internal(format!(
            "Error reconstruyendo payloads: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
