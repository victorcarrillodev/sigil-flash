use crate::errors::{Result, SigilError};
use flasher_rs::{Engine, model::EngineStatus};
use std::path::Path;

pub fn run_engine_validate(
    base_image: &Path,
    base_image_sha256: Option<String>,
    payload: &Path,
    offline_packages: Option<&Path>,
    target_device: Option<&Path>,
    provision: Option<&Path>,
    secrets: Option<&Path>,
) -> Result<bool> {
    let mut engine = Engine::new(base_image.to_path_buf(), payload.to_path_buf());

    if let Some(sha) = base_image_sha256 {
        engine = engine.with_base_image_sha256(sha);
    }
    if let Some(repo) = offline_packages {
        engine = engine.with_offline_packages(repo.to_path_buf());
    }
    if let Some(dev) = target_device {
        engine = engine.with_target_device(dev.to_path_buf());
    }
    if let Some(prov) = provision {
        engine = engine.with_provision(prov.to_path_buf());
    }
    if let Some(sec) = secrets {
        engine = engine.with_secrets(sec.to_path_buf());
    }

    let validation = engine.validate();
    if !validation.valid {
        let errors: Vec<String> = validation
            .items
            .iter()
            .filter(|i| matches!(i.severity, flasher_rs::model::Severity::Error))
            .map(|i| i.message.clone())
            .collect();
        return Err(SigilError::Validation(format!(
            "Validación de flasher-rs falló: {}",
            errors.join("; ")
        )));
    }

    Ok(true)
}

pub fn get_engine_status_summary() -> EngineStatus {
    Engine::status()
}
