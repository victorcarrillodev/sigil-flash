use crate::errors::{Result, SigilError};
use crate::models::ImageInfo;
use crate::services::verification::calculate_sha256;
use std::fs;
use std::path::Path;

#[tauri::command]
pub fn select_image(path: String) -> Result<ImageInfo> {
    let p = Path::new(&path);
    if !p.is_file() {
        return Err(SigilError::Validation(format!("El archivo no existe: '{}'", path)));
    }

    let meta = fs::metadata(p)?;
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("unknown").to_string();

    Ok(ImageInfo {
        path,
        name,
        size: meta.len(),
        sha256: None,
    })
}

#[tauri::command]
pub fn verify_sha256(path: String, expected_sha256: String) -> Result<bool> {
    let p = Path::new(&path);
    if !p.is_file() {
        return Err(SigilError::Validation(format!("El archivo no existe: '{}'", path)));
    }

    let calculated = calculate_sha256(p)?;
    if calculated.to_lowercase() == expected_sha256.to_lowercase() {
        Ok(true)
    } else {
        Err(SigilError::Validation(format!(
            "Checksum no coincide. Esperado: {}, Calculado: {}",
            expected_sha256, calculated
        )))
    }
}
