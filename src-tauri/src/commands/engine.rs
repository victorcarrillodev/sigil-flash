use crate::errors::AppResult;
use crate::services::engine_service::{
    EngineParams, EngineResult, FlasherEngineService, ProvisionDocument, SecretWriteResult,
};
use tauri::State;

// ── Tauri commands ─────────────────────────────────────────────────────────────

/// Return engine metadata (`flasher-rs status`).
#[tauri::command]
pub async fn engine_status(svc: State<'_, FlasherEngineService>) -> AppResult<EngineResult> {
    tracing::info!("engine_status invoked");
    svc.status().await
}

#[tauri::command]
pub async fn engine_default_secrets_path(
    svc: State<'_, FlasherEngineService>,
) -> AppResult<String> {
    svc.default_secrets_path()
}

#[tauri::command]
pub async fn engine_generate_panel_pin(svc: State<'_, FlasherEngineService>) -> AppResult<String> {
    svc.generate_panel_pin()
}

#[tauri::command]
pub async fn engine_write_secrets(
    path: String,
    panel_pin: String,
    overwrite_confirmed: bool,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<SecretWriteResult> {
    tracing::info!("writing protected manufacturing secret input");
    svc.write_secrets(&path, &panel_pin, overwrite_confirmed)
}

/// Run `flasher-rs plan` (dry-run — no writes).
#[tauri::command]
pub async fn engine_plan(
    params: EngineParams,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<EngineResult> {
    tracing::info!("engine_plan invoked");
    svc.plan(&params).await
}

/// Run `flasher-rs validate` (dry-run — no writes).
#[tauri::command]
pub async fn engine_validate(
    params: EngineParams,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<EngineResult> {
    tracing::info!("engine_validate invoked");
    svc.validate(&params).await
}

/// Run `flasher-rs apply`, honoring the requested dry-run mode.
#[tauri::command]
pub async fn engine_apply(
    params: EngineParams,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<EngineResult> {
    tracing::info!(dry_run = params.dry_run, "engine_apply invoked");
    svc.apply(&params).await
}

/// Invoke `build-flasher-payload.sh [output_dir]` to generate a payload.
///
/// `output_dir` is optional; when absent the script uses its own default.
#[tauri::command]
pub async fn engine_build_payload(
    output_dir: Option<String>,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<EngineResult> {
    tracing::info!("engine_build_payload invoked, output_dir: {:?}", output_dir);
    svc.build_payload(output_dir.as_deref()).await
}

/// Return the resolved path to the `flasher-rs` binary.
#[tauri::command]
pub async fn engine_binary_path(svc: State<'_, FlasherEngineService>) -> AppResult<String> {
    Ok(svc.engine_bin().to_string_lossy().to_string())
}

#[tauri::command]
pub async fn engine_write_provision(
    path: String,
    provision: ProvisionDocument,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<String> {
    tracing::info!("writing non-secret provision to operator-selected path");
    svc.write_provision(&path, &provision)
}
