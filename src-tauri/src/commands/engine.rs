use crate::errors::AppResult;
use crate::services::engine_service::{
    EngineParams, EngineResult, FlasherEngineService, ProvisionDocument,
};
use tauri::State;

// ── Tauri commands ─────────────────────────────────────────────────────────────

/// Return engine metadata (`flasher-rs status`).
#[tauri::command]
pub async fn engine_status(svc: State<'_, FlasherEngineService>) -> AppResult<EngineResult> {
    tracing::info!("engine_status invoked");
    svc.status().await
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

/// Run `flasher-rs apply --dry-run` (always dry-run; unconditionally enforced).
///
/// Returns an error if the caller tries to omit --dry-run in the params, which
/// is an additional documentation-level guard — the service already overrides it.
#[tauri::command]
pub async fn engine_apply(
    params: EngineParams,
    svc: State<'_, FlasherEngineService>,
) -> AppResult<EngineResult> {
    tracing::info!("engine_apply invoked (dry-run enforced)");
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
