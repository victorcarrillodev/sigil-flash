use crate::models::DeviceConfig;
use crate::errors::AppResult;
use crate::services::config_service::ConfigService;
use tauri::State;

#[tauri::command]
pub async fn save_device_config(
    mount_path: String,
    config: DeviceConfig,
    config_service: State<'_, ConfigService>
) -> AppResult<()> {
    tracing::info!("Recibida configuración del dispositivo para montar en: {}", mount_path);
    config_service.write_config(&mount_path, &config).await
}
