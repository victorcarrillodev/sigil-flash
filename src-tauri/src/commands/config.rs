use crate::errors::Result;
use crate::models::DeviceConfig;
use crate::services::config::validate_device_config;

/// Segunda de las tres validaciones (frontend, backend de la GUI y proceso
/// elevado). La configuración nunca se persiste desde aquí: el único archivo
/// que llega a disco lo crea `PrivateConfigGuard` con modo 0600 justo antes de
/// elevar privilegios, y se destruye con él.
#[tauri::command]
pub fn validate_config(config: DeviceConfig) -> Result<bool> {
    validate_device_config(&config)?;
    Ok(true)
}
