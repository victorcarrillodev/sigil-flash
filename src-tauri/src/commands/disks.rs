use crate::models::Device;
use crate::errors::AppResult;
use crate::services::disk_service::DiskService;
use tauri::State;

#[tauri::command]
pub async fn list_devices(
    disk_service: State<'_, DiskService>
) -> AppResult<Vec<Device>> {
    tracing::info!("Comando de listado de dispositivos invocado.");
    disk_service.list_devices().await
}
