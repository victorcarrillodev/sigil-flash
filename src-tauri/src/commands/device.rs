use crate::errors::Result;
use crate::models::Device;
use crate::services::disk::list_removable_devices;

#[tauri::command]
pub fn list_devices() -> Result<Vec<Device>> {
    list_removable_devices()
}

#[tauri::command]
pub fn refresh_devices() -> Result<Vec<Device>> {
    list_removable_devices()
}
