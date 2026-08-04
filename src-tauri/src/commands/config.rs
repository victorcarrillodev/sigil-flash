use crate::errors::{AppError, AppResult};
use crate::models::DeviceConfig;
use crate::services::config_service::ConfigService;
use serde::Serialize;
use std::path::PathBuf;
use tauri::State;

#[derive(Serialize)]
pub struct ServerConfigResponse {
    pub server_url: String,
    pub has_keyring_password: bool,
}

#[tauri::command]
pub async fn get_server_config() -> AppResult<ServerConfigResponse> {
    let server_url = match std::env::var("SIGIL_SERVER_URL") {
        Ok(val) => val,
        Err(_) => {
            let mut url = String::new();
            if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
                let config_path = home.join(".config/sigil-flash/config.toml");
                if let Ok(contents) = std::fs::read_to_string(config_path) {
                    for line in contents.lines() {
                        if let Some(value) = line.trim().strip_prefix("server_url") {
                            if let Some((_, value)) = value.split_once('=') {
                                url = value
                                    .trim()
                                    .trim_matches('"')
                                    .trim_matches('\'')
                                    .to_string();
                                break;
                            }
                        }
                    }
                }
            }
            url
        }
    };

    let keyring_output = tokio::process::Command::new("secret-tool")
        .args(["lookup", "service", "sigil-flash", "username", "fabrica"])
        .output()
        .await;

    let has_keyring_password = match keyring_output {
        Ok(out) => out.status.success() && !out.stdout.is_empty(),
        Err(_) => false,
    };

    Ok(ServerConfigResponse {
        server_url,
        has_keyring_password,
    })
}

#[tauri::command]
pub async fn save_server_config(
    server_url: String,
    factory_password: Option<String>,
) -> AppResult<()> {
    let trimmed_url = server_url.trim();
    if trimmed_url.is_empty() {
        return Err(AppError::Validation(
            "La URL del servidor no puede estar vacía.".into(),
        ));
    }

    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| {
            AppError::Validation("No se pudo obtener el directorio HOME del usuario.".into())
        })?;

    let config_dir = home.join(".config/sigil-flash");
    std::fs::create_dir_all(&config_dir).map_err(|e| {
        AppError::Config(format!("No se pudo crear el directorio de configuración: {e}"))
    })?;

    let config_file = config_dir.join("config.toml");
    let content = format!("server_url = \"{}\"\n", trimmed_url);
    std::fs::write(&config_file, content).map_err(|e| {
        AppError::Config(format!(
            "No se pudo guardar ~/.config/sigil-flash/config.toml: {e}"
        ))
    })?;

    if let Some(password) = factory_password {
        let password = password.trim();
        if !password.is_empty() {
            let mut child = tokio::process::Command::new("secret-tool")
                .args([
                    "store",
                    "--label=SIGIL Factory Provisioning",
                    "service",
                    "sigil-flash",
                    "username",
                    "fabrica",
                ])
                .stdin(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .map_err(|e| {
                    AppError::Validation(format!(
                        "No se pudo ejecutar secret-tool: {e}. Instala libsecret-tools / libsecret."
                    ))
                })?;

            if let Some(mut stdin) = child.stdin.take() {
                use tokio::io::AsyncWriteExt;
                stdin.write_all(password.as_bytes()).await.map_err(|e| {
                    AppError::Config(format!("Error escribiendo contraseña en secret-tool: {e}"))
                })?;
            }

            let output = child.wait_with_output().await.map_err(|e| {
                AppError::Config(format!("Error guardando contraseña con secret-tool: {e}"))
            })?;

            if !output.status.success() {
                let err_msg = String::from_utf8_lossy(&output.stderr);
                return Err(AppError::Config(format!(
                    "secret-tool falló al guardar credencial: {}",
                    err_msg.trim()
                )));
            }
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn save_device_config(
    mount_path: String,
    config: DeviceConfig,
    config_service: State<'_, ConfigService>,
) -> AppResult<()> {
    tracing::info!(
        "Recibida configuración del dispositivo para montar en: {}",
        mount_path
    );
    config_service.write_config(&mount_path, &config).await
}

