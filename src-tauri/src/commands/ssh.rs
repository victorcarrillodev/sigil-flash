use crate::errors::Result;
use crate::services::ssh::{self, SshSessionState};
use tauri::{AppHandle, State};

#[tauri::command]
pub fn ssh_connect(
    app: AppHandle,
    state: State<SshSessionState>,
    host: String,
    port: u16,
    username: String,
    cols: u16,
    rows: u16,
) -> Result<()> {
    ssh::connect(&state, &app, host, port, username, cols, rows)
}

#[tauri::command]
pub fn ssh_write(state: State<SshSessionState>, data: String) -> Result<()> {
    ssh::write(&state, &data)
}

#[tauri::command]
pub fn ssh_resize(state: State<SshSessionState>, cols: u16, rows: u16) -> Result<()> {
    ssh::resize(&state, cols, rows)
}

#[tauri::command]
pub fn ssh_disconnect(state: State<SshSessionState>) -> Result<()> {
    ssh::disconnect(&state)
}

#[tauri::command]
pub fn ssh_forget_host_key(host: String, port: u16) -> Result<()> {
    ssh::forget_host_key(&host, port)
}
