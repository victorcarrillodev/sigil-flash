use crate::models::ImageInfo;
use crate::errors::AppResult;
use crate::services::flash_service::{FlashService, get_xz_uncompressed_size};
use tauri::{State, AppHandle};

#[tauri::command]
pub async fn get_image_info(path: String) -> AppResult<ImageInfo> {
    tracing::info!("Obteniendo información de la imagen en ruta: {}", path);
    let metadata = std::fs::metadata(&path)?;
    let name = std::path::Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let mut size = metadata.len();
    if path.to_lowercase().ends_with(".xz") {
        if let Ok(uncompressed) = get_xz_uncompressed_size(&path) {
            size = uncompressed;
        }
    }

    Ok(ImageInfo {
        path,
        name,
        size,
        sha256: None,
    })
}

#[tauri::command]
pub async fn start_flash(
    image_path: String,
    device_path: String,
    app: AppHandle,
    flash_service: State<'_, FlashService>,
) -> AppResult<()> {
    tracing::info!("Iniciando escritura de: {} en: {}", image_path, device_path);
    flash_service.start_flash(&image_path, &device_path, app).await
}

#[tauri::command]
pub async fn cancel_flash(
    flash_service: State<'_, FlashService>
) -> AppResult<()> {
    tracing::info!("Comando de cancelación de flasheo invocado.");
    flash_service.cancel_flash().await
}
