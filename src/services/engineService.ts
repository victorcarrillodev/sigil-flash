/**
 * engineService — single Tauri invoke gateway for the flasher-rs engine.
 *
 * All six engine Tauri commands are called exclusively through this module.
 * Components must NOT call invoke() for engine operations directly.
 *
 * Safety invariants mirrored from the Rust adapter:
 *   • dry_run is always true for apply() — the backend enforces this too.
 *   • No credentials, API keys, or passwords are ever passed as arguments.
 *   • Paths with spaces are preserved verbatim (no shell interpolation).
 */
import { invoke } from "@tauri-apps/api/core";

// ── Types ─────────────────────────────────────────────────────────────────────

/** A captured line from engine stdout or stderr. */
export interface EngineLine {
  stream: "stdout" | "stderr";
  text: string;
}

/** Complete result of a single engine invocation. */
export interface EngineResult {
  exit_code: number;
  lines: EngineLine[];
  /** True when the invocation was an apply --dry-run (not a real flash). */
  was_dry_run: boolean;
  /** True iff exit_code === 0. */
  success: boolean;
}

/**
 * Parameters forwarded to the flasher-rs CLI adapter.
 * Paths with spaces are safe — they are passed as individual argv tokens,
 * never interpolated into a shell string.
 */
export interface EngineParams {
  base_image: string;
  base_image_sha256: string;
  payload: string;
  provision: string | null;
  secrets: string | null;
  target_device: string | null;
  /** Must be true for apply; the Rust backend enforces this unconditionally. */
  dry_run: boolean;
}

export interface ProvisionCapabilities {
  i2s_dac: boolean;
}

export interface ProvisionDocument {
  _schema_version: "1.0";
  serial_number: string;
  model: string;
  model_version: string;
  batch: string;
  capabilities: ProvisionCapabilities;
}

export interface SecretWriteResult {
  path: string;
  success: boolean;
  schema_version: "1.0";
  panel_pin_configured: boolean;
  pin_length: number;
}

// ── Command wrappers ──────────────────────────────────────────────────────────

/** Query engine metadata (flasher-rs status). */
export async function engineStatus(): Promise<EngineResult> {
  return invoke<EngineResult>("engine_status");
}

/** Return the resolved absolute path to the flasher-rs binary. */
export async function engineBinaryPath(): Promise<string> {
  return invoke<string>("engine_binary_path");
}

export async function engineWriteProvision(
  path: string,
  provision: ProvisionDocument
): Promise<string> {
  return invoke<string>("engine_write_provision", { path, provision });
}

export async function engineDefaultSecretsPath(): Promise<string> {
  return invoke<string>("engine_default_secrets_path");
}

export async function engineGeneratePanelPin(): Promise<string> {
  return invoke<string>("engine_generate_panel_pin");
}

export async function engineWriteSecrets(
  path: string,
  panelPin: string,
  overwriteConfirmed: boolean
): Promise<SecretWriteResult> {
  return invoke<SecretWriteResult>("engine_write_secrets", {
    path,
    panelPin,
    overwriteConfirmed,
  });
}

/**
 * Build the SIGIL payload via build-flasher-payload.sh.
 * Omit outputDir to use the script's own default directory.
 */
export async function engineBuildPayload(
  outputDir?: string
): Promise<EngineResult> {
  return invoke<EngineResult>("engine_build_payload", {
    outputDir: outputDir ?? null,
  });
}

/** Run flasher-rs plan (reads only; no files written). */
export async function enginePlan(params: EngineParams): Promise<EngineResult> {
  return invoke<EngineResult>("engine_plan", { params });
}

/** Run flasher-rs validate (reads only; no files written). */
export async function engineValidate(
  params: EngineParams
): Promise<EngineResult> {
  return invoke<EngineResult>("engine_validate", { params });
}

/**
 * Run flasher-rs apply --dry-run.
 *
 * The Rust adapter adds --dry-run unconditionally regardless of params.dry_run.
 * REAL SD WRITING IS NOT IMPLEMENTED. This command only validates inputs and
 * renders the plan. The return value's was_dry_run will always be true.
 */
export async function engineApply(
  params: EngineParams
): Promise<EngineResult> {
  // Frontend-side guard: always request dry_run even if caller forgot.
  const safeParams: EngineParams = { ...params, dry_run: true };
  return invoke<EngineResult>("engine_apply", { params: safeParams });
}
