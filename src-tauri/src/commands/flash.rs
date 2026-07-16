use crate::errors::AppResult;
use crate::models::{DeviceConfig, ImageInfo};
use crate::services::flash_service::{get_xz_uncompressed_size, FlashService};
use tauri::{AppHandle, State};

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
    config: DeviceConfig,
    app: AppHandle,
    flash_service: State<'_, FlashService>,
) -> AppResult<()> {
    tracing::info!("Iniciando escritura de: {} en: {}", image_path, device_path);
    flash_service
        .start_flash(&image_path, &device_path, &config, app)
        .await
}

#[tauri::command]
pub async fn cancel_flash(flash_service: State<'_, FlashService>) -> AppResult<()> {
    tracing::info!("Comando de cancelación de flasheo invocado.");
    flash_service.cancel_flash().await
}

#[tauri::command]
pub async fn get_hardware_size() -> AppResult<u64> {
    let path = "/home/dev-pro/Escritorio/sigil-flash/sigil-hardware";
    let mut total_size = 0;

    fn dir_size(dir: &std::path::Path) -> std::io::Result<u64> {
        let mut size = 0;
        if dir.is_dir() {
            for entry in std::fs::read_dir(dir)? {
                let entry = entry?;
                let path = entry.path();
                if path.is_dir() {
                    size += dir_size(&path)?;
                } else {
                    size += entry.metadata()?.len();
                }
            }
        }
        Ok(size)
    }

    if let Ok(size) = dir_size(std::path::Path::new(path)) {
        total_size = size;
    }

    Ok(total_size)
}
