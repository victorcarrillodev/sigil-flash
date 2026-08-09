use crate::errors::Result;
use crate::services::engine::{get_engine_status_summary, run_engine_validate};
use std::path::Path;

#[tauri::command]
pub fn get_engine_status() -> Result<serde_json::Value> {
    let status = get_engine_status_summary();
    Ok(serde_json::json!({
        "name": status.name,
        "version": status.version,
        "description": status.description,
        "phase": status.phase,
        "capabilities": status.capabilities,
    }))
}

#[tauri::command]
pub fn validate_engine(
    base_image: String,
    base_image_sha256: Option<String>,
    payload: String,
    offline_packages: Option<String>,
) -> Result<bool> {
    let base = Path::new(&base_image);
    let pay = Path::new(&payload);
    let off = offline_packages.as_ref().map(|s| Path::new(s.as_str()));

    run_engine_validate(base, base_image_sha256, pay, off, None, None, None)
}
