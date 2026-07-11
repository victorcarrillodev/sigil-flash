// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod flash;

use flash::FlashState;
use std::sync::{Arc, Mutex};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let flash_state = Arc::new(Mutex::new(FlashState { pid: None }));

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .manage(flash_state)
        .invoke_handler(tauri::generate_handler![
            flash::list_devices,
            flash::get_image_info,
            flash::start_flash,
            flash::cancel_flash,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn main() {
    run();
}
