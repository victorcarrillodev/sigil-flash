use crate::errors::AppResult;
use crate::services::download_service::DownloadService;
use crate::services::verification_service::VerificationService;
use tauri::{State, AppHandle};
use std::path::PathBuf;

#[tauri::command]
pub async fn start_download(
    url: String,
    destination: String,
    app: AppHandle,
    download_service: State<'_, DownloadService>
) -> AppResult<String> {
    tracing::info!("Comando start_download invocado. URL: {}, Destino: {}", url, destination);
    let dest_path = PathBuf::from(destination);
    let path = download_service.start_download(&url, dest_path, app).await?;
    Ok(path.to_string_lossy().to_string())
}

#[tauri::command]
pub async fn cancel_download(
    download_service: State<'_, DownloadService>
) -> AppResult<()> {
    tracing::info!("Comando cancel_download invocado.");
    download_service.cancel_download().await
}

#[tauri::command]
pub async fn verify_image(
    file_path: String,
    expected_hash: Option<String>,
    app: AppHandle,
    verification_service: State<'_, VerificationService>
) -> AppResult<String> {
    tracing::info!("Comando verify_image invocado para: {}", file_path);
    let path = PathBuf::from(file_path);
    verification_service.verify_sha256(&path, expected_hash.as_deref(), app).await
}
