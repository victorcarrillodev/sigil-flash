// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod errors;
mod logging;
mod models;
mod services;

use services::config_service::ConfigService;
use services::disk_service::DiskService;
use services::download_service::DownloadService;
use services::engine_service::FlasherEngineService;
use services::flash_service::FlashService;
use services::verification_service::VerificationService;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 1. Initialize logging system. The returned _log_guard must remain in scope
    // so asynchronous logging continues executing on the background thread.
    let _log_guard = match logging::init_logging() {
        Ok(guard) => guard,
        Err(e) => {
            eprintln!(
                "Fallo crítico de arranque. No se pudieron iniciar los logs: {}",
                e
            );
            std::process::exit(1);
        }
    };

    tracing::info!("Bootstrap de Sigil Flash exitoso. Iniciando dependencias...");

    // 2. Instantiate cross-platform services
    let disk_service = DiskService::new();
    let download_service = DownloadService::new();
    let flash_service = FlashService::new();
    let config_service = ConfigService::new();
    let verification_service = VerificationService::new();

    // 2b. Instantiate flasher-rs engine adapter
    let engine_service = match FlasherEngineService::new() {
        Ok(svc) => {
            tracing::info!("FlasherEngineService ready: {}", svc.engine_bin().display());
            svc
        }
        Err(e) => {
            tracing::error!("FlasherEngineService init failed: {e}");
            // Non-fatal: the UI will surface the error when engine commands are invoked.
            // We still need a value; create one that will fail on first use.
            // unwrap_or_else with a dummy path handled via AppError::Validation later.
            FlasherEngineService::new_unchecked()
        }
    };

    // 3. Start Tauri runtime and register commands/services
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .manage(disk_service)
        .manage(download_service)
        .manage(flash_service)
        .manage(config_service)
        .manage(verification_service)
        .manage(engine_service)
        .invoke_handler(tauri::generate_handler![
            commands::disks::list_devices,
            commands::flash::get_image_info,
            commands::flash::start_flash,
            commands::flash::cancel_flash,
            commands::flash::get_hardware_size,
            commands::downloads::start_download,
            commands::downloads::cancel_download,
            commands::downloads::verify_image,
            commands::config::save_device_config,
            // flasher-rs engine adapter commands
            commands::engine::engine_status,
            commands::engine::engine_plan,
            commands::engine::engine_validate,
            commands::engine::engine_apply,
            commands::engine::engine_build_payload,
            commands::engine::engine_binary_path,
            commands::engine::engine_write_provision,
            commands::engine::engine_default_secrets_path,
            commands::engine::engine_generate_panel_pin,
            commands::engine::engine_write_secrets,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.contains(&"--flash-raw".to_string()) {
        let rt = tokio::runtime::Runtime::new().unwrap();
        if let Err(e) = rt.block_on(async {
            let src = get_arg_value(&args, "--src")?;
            let dest = get_arg_value(&args, "--dest")?;
            let progress_file = get_arg_value(&args, "--progress-file")?;
            services::flash_service::run_raw_flash_cli(&src, &dest, &progress_file).await
        }) {
            eprintln!("Fallo durante el flasheo directo: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

    run();
}

fn get_arg_value(args: &[String], flag: &str) -> Result<String, crate::errors::AppError> {
    let pos = args.iter().position(|a| a == flag).ok_or_else(|| {
        crate::errors::AppError::Validation(format!("Parámetro requerido faltante: {}", flag))
    })?;
    args.get(pos + 1).cloned().ok_or_else(|| {
        crate::errors::AppError::Validation(format!(
            "Valor requerido faltante para parámetro: {}",
            flag
        ))
    })
}
