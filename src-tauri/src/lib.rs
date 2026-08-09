pub mod commands;
pub mod errors;
pub mod logging;
pub mod models;
pub mod services;

use tauri::Builder;

pub fn run() {
    Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::device::list_devices,
            commands::device::refresh_devices,
            commands::image::select_image,
            commands::image::verify_sha256,
            commands::config::validate_config,
            commands::flash::start_flash,
            commands::flash::cancel_flash,
            commands::flash::get_flash_progress,
            commands::flash::resolve_bundle,
            commands::bundle::get_bundle_status,
            commands::bundle::resolve_bundle_for_image,
            commands::bundle::rebuild_payloads_cmd,
            commands::credential::list_factory_accounts,
            commands::credential::login_factory,
            commands::credential::request_enrollment,
            commands::engine::get_engine_status,
            commands::engine::validate_engine
        ])
        .run(tauri::generate_context!())
        .expect("error mientras se ejecutaba la aplicación tauri");
}
