use crate::errors::Result;
use crate::services::credential::{
    get_factory_password_from_keyring, list_keyring_factory_accounts, login_factory_account,
    request_enrollment_key,
};

/// Las cuentas de fábrica con contraseña guardada en este PC. Solo nombres: la
/// contraseña no sale del backend ni siquiera para la interfaz.
#[tauri::command]
pub fn list_factory_accounts() -> Vec<String> {
    list_keyring_factory_accounts()
}

#[tauri::command]
pub async fn login_factory(server_url: String, username: String) -> Result<String> {
    let password = get_factory_password_from_keyring(&username)?;
    let token = login_factory_account(&server_url, &username, &password).await?;
    Ok(token)
}

#[tauri::command]
pub async fn request_enrollment(
    server_url: String,
    session_token: String,
    device_id: Option<String>,
    serial_number: Option<String>,
) -> Result<String> {
    let key = request_enrollment_key(
        &server_url,
        &session_token,
        device_id.as_deref(),
        serial_number.as_deref(),
    )
    .await?;
    Ok(key)
}
