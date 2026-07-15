use crate::errors::AppResult;
use crate::services::offline_package_service::{OfflinePackageService, OfflinePackageStatus};
use tauri::State;

#[tauri::command]
pub fn offline_packages_status(
    path: Option<String>,
    base_image: Option<String>,
    base_image_sha256: Option<String>,
    service: State<'_, OfflinePackageService>,
) -> OfflinePackageStatus {
    service.status(
        path.as_deref(),
        base_image.as_deref(),
        base_image_sha256.as_deref(),
    )
}

#[tauri::command]
pub fn offline_packages_validate(
    path: Option<String>,
    base_image: Option<String>,
    base_image_sha256: Option<String>,
    service: State<'_, OfflinePackageService>,
) -> AppResult<OfflinePackageStatus> {
    service.validate(
        path.as_deref(),
        base_image.as_deref(),
        base_image_sha256.as_deref(),
    )
}

#[tauri::command]
pub async fn offline_packages_build(
    rebuild: bool,
    service: State<'_, OfflinePackageService>,
) -> AppResult<OfflinePackageStatus> {
    service.build(rebuild).await
}
