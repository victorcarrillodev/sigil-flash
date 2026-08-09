use crate::errors::{Result, SigilError};
use std::fs;
use std::path::Path;
use std::process::Command;
use tracing::info;

/// El validador de sigil-hardware exige que `dpkg --print-architecture`
/// coincida con el contrato: está pensado para correr DENTRO de la imagen. En
/// un PC de otra arquitectura se omite y se dice por qué, en vez de fallar con
/// un mensaje que el operario no puede accionar.
fn host_dpkg_architecture() -> Option<String> {
    let output = Command::new("dpkg").arg("--print-architecture").output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn contract_architecture(contract_file: &Path) -> Result<String> {
    let contract: serde_json::Value = serde_json::from_str(&fs::read_to_string(contract_file)?)?;
    contract
        .get("architecture")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| {
            SigilError::Validation(format!(
                "El contrato '{}' no declara arquitectura",
                contract_file.display()
            ))
        })
}

/// Valida un repositorio APT offline local contra el instalador de
/// sigil-hardware en su modo de prueba.
pub fn validate_offline_repository(repo_dir: &Path, contract_file: Option<&Path>) -> Result<String> {
    if !repo_dir.is_dir() {
        return Err(SigilError::Validation(format!(
            "El repositorio APT offline no existe: '{}'. \
             Constrúyalo con ./scripts/build-all-bundles.sh",
            repo_dir.display()
        )));
    }

    let script_path = crate::services::bundle::project_root()
        .join("sigil-hardware/scripts/install-offline-packages.sh");
    if !script_path.is_file() {
        return Err(SigilError::Validation(format!(
            "Script validador ausente: '{}'. La aplicación necesita el árbol sigil-hardware/.",
            script_path.display()
        )));
    }

    if let Some(contract) = contract_file {
        let expected = contract_architecture(contract)?;
        let host = host_dpkg_architecture();
        if host.as_deref() != Some(expected.as_str()) {
            let message = format!(
                "Validación completa omitida: el contrato es '{}' y este PC es '{}'. \
                 El validador de sigil-hardware se ejecuta dentro de la imagen durante el flasheo.",
                expected,
                host.as_deref().unwrap_or("desconocida")
            );
            info!("{}", message);
            return Ok(message);
        }
    }

    let mut cmd = Command::new("bash");
    cmd.arg(&script_path).arg(repo_dir);
    cmd.env("SIGIL_OFFLINE_INSTALL_TEST_MODE", "1");
    if let Some(contract) = contract_file {
        cmd.env("SIGIL_PACKAGE_CONTRACT", contract);
    }

    let output = cmd.output()?;
    if !output.status.success() {
        return Err(SigilError::Validation(format!(
            "Validación del repositorio APT offline falló: {}\n{}",
            String::from_utf8_lossy(&output.stderr),
            String::from_utf8_lossy(&output.stdout)
        )));
    }

    let message = format!(
        "El repositorio '{}' superó todas las validaciones de sigil-hardware",
        repo_dir.display()
    );
    info!("{}", message);
    Ok(message)
}
