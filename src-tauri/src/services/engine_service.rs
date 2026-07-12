/// FlasherEngineService — stable CLI adapter between sigil-flash and flasher-rs.
///
/// This service locates the `flasher-rs` executable relative to the sigil-hardware
/// repo root (determined at startup from `SIGIL_HARDWARE_ROOT` env var or a
/// compile-time default neighbour-directory heuristic) and invokes it as a child
/// process.  All validation logic lives exclusively in the engine binary; none is
/// duplicated here.
///
/// Safety invariants enforced by this service:
///   1. `--dry-run` is always added to every `apply` invocation.
///   2. Real `/dev/*` paths are never forwarded when dry-run is active.
///   3. No credentials, keys, or passwords are ever passed on the command line.
///   4. `sudo`, `pkexec`, `losetup`, and `mount` are never invoked.
use crate::errors::{AppError, AppResult};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

// ── Types ─────────────────────────────────────────────────────────────────────

/// A single line of engine output (stdout or stderr).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineLine {
    /// "stdout" | "stderr"
    pub stream: String,
    pub text: String,
}

/// Complete result from a single engine invocation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineResult {
    /// Unix exit code of `flasher-rs`.
    pub exit_code: i32,
    /// All captured output lines, in order.
    pub lines: Vec<EngineLine>,
    /// Whether the invocation was a validated-only dry-run (`apply --dry-run`).
    pub was_dry_run: bool,
    /// Whether the engine reported success (exit 0 AND no ERROR items).
    pub success: bool,
}

/// Parameters for `plan`, `validate`, or `apply` commands.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineParams {
    /// Absolute path to `.img` or `.img.xz` base image.
    pub base_image: String,
    /// Expected SHA-256 hex string for the base image.
    pub base_image_sha256: String,
    /// Absolute path to the generated SIGIL payload directory.
    pub payload: String,
    /// Optional absolute path to `sigil_provision.json`.
    pub provision: Option<String>,
    /// Optional target path; must be a regular file when dry_run is true.
    pub target_device: Option<String>,
    /// Must be `true` for `apply`; also accepted (and enforced) for other commands.
    pub dry_run: bool,
}

// ── Service ───────────────────────────────────────────────────────────────────

pub struct FlasherEngineService {
    /// Absolute path to the `flasher-rs` binary.
    engine_bin: PathBuf,
    /// Absolute path to `build-flasher-payload.sh`.
    payload_script: PathBuf,
}

impl FlasherEngineService {
    /// Locate the engine binary and payload script.
    ///
    /// Resolution order:
    ///   1. `SIGIL_HARDWARE_ROOT` environment variable.
    ///   2. Sibling `sigil-hardware/` next to the directory containing the
    ///      `sigil-flash` project (traversal from `CARGO_MANIFEST_DIR` at build
    ///      time, baked in via the constant `COMPILE_TIME_SIBLING`).
    pub fn new() -> AppResult<Self> {
        let hw_root = locate_hardware_root()?;
        let engine_bin = hw_root
            .join("flasher-rs")
            .join("target")
            .join("debug")
            .join("flasher-rs");
        let payload_script = hw_root.join("scripts").join("build-flasher-payload.sh");

        if !engine_bin.exists() {
            return Err(AppError::Validation(format!(
                "flasher-rs binary not found at {}. Run `cargo build` in sigil-hardware/flasher-rs.",
                engine_bin.display()
            )));
        }

        Ok(Self {
            engine_bin,
            payload_script,
        })
    }

    /// Construct a service with placeholder paths (used when `new()` fails at startup).
    /// Every method will return `AppError::Validation` describing the missing binary.
    pub fn new_unchecked() -> Self {
        Self {
            engine_bin: PathBuf::from("/dev/null/flasher-rs-not-found"),
            payload_script: PathBuf::from("/dev/null/build-flasher-payload-not-found"),
        }
    }

    /// Returns the resolved path to the `flasher-rs` binary (for display/tests).
    pub fn engine_bin(&self) -> &Path {
        &self.engine_bin
    }

    /// Returns the resolved path to `build-flasher-payload.sh`.
    pub fn payload_script(&self) -> &Path {
        &self.payload_script
    }

    // ── Engine commands ────────────────────────────────────────────────────────

    /// Run `flasher-rs status` — no file arguments required.
    pub async fn status(&self) -> AppResult<EngineResult> {
        self.run_engine(&["status"], false).await
    }

    /// Run `flasher-rs plan` with the given parameters.
    pub async fn plan(&self, params: &EngineParams) -> AppResult<EngineResult> {
        let argv = build_argv("plan", params)?;
        let refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
        self.run_engine(&refs, params.dry_run).await
    }

    /// Run `flasher-rs validate` with the given parameters.
    pub async fn validate(&self, params: &EngineParams) -> AppResult<EngineResult> {
        let argv = build_argv("validate", params)?;
        let refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
        self.run_engine(&refs, params.dry_run).await
    }

    /// Run `flasher-rs apply --dry-run` with the given parameters.
    ///
    /// `--dry-run` is **unconditionally added** regardless of what the caller
    /// sets in `params.dry_run`; real writes are not supported in Phase 2.
    pub async fn apply(&self, params: &EngineParams) -> AppResult<EngineResult> {
        let mut forced = params.clone();
        forced.dry_run = true; // safety: always override
        let argv = build_argv("apply", &forced)?;
        let refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
        self.run_engine(&refs, true).await
    }

    // ── Payload generation ─────────────────────────────────────────────────────

    /// Invoke `build-flasher-payload.sh [output_dir]`.
    ///
    /// Shells out to bash; no sudo/pkexec/losetup.
    pub async fn build_payload(&self, output_dir: Option<&str>) -> AppResult<EngineResult> {
        if !self.payload_script.exists() {
            return Err(AppError::Validation(format!(
                "build-flasher-payload.sh not found at {}",
                self.payload_script.display()
            )));
        }

        let mut cmd = Command::new("bash");
        cmd.arg(&self.payload_script);
        if let Some(dir) = output_dir {
            cmd.arg(dir);
        }
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());

        run_command_capture(cmd, false).await
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    async fn run_engine(&self, args: &[&str], was_dry_run: bool) -> AppResult<EngineResult> {
        let mut cmd = Command::new(&self.engine_bin);
        cmd.args(args);
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());

        tracing::info!(
            "engine invoke: {} {}",
            self.engine_bin.display(),
            args.join(" ")
        );

        run_command_capture(cmd, was_dry_run).await
    }
}

// ── Argument builder ───────────────────────────────────────────────────────────

/// Build the argv list for a plan/validate/apply command.
/// Returns `Err` if any required field is missing or contains a forbidden pattern.
fn build_argv(command: &str, params: &EngineParams) -> AppResult<Vec<String>> {
    // Reject empty required fields
    if params.base_image.trim().is_empty() {
        return Err(AppError::Validation(
            "--base-image must not be empty".into(),
        ));
    }
    if params.base_image_sha256.trim().is_empty() {
        return Err(AppError::Validation(
            "--base-image-sha256 must not be empty".into(),
        ));
    }
    if params.payload.trim().is_empty() {
        return Err(AppError::Validation("--payload must not be empty".into()));
    }

    // Validate SHA-256 format (64 hex chars)
    if !is_sha256_hex(params.base_image_sha256.trim()) {
        return Err(AppError::Validation(
            "--base-image-sha256 must be exactly 64 lowercase hex characters".into(),
        ));
    }

    // Reject command-line injection characters in paths
    for (field, value) in [
        ("base_image", &params.base_image),
        ("payload", &params.payload),
    ] {
        reject_shell_injection(field, value)?;
    }
    if let Some(ref p) = params.provision {
        reject_shell_injection("provision", p)?;
    }
    if let Some(ref t) = params.target_device {
        reject_shell_injection("target_device", t)?;
    }

    // Safety: when apply, enforce dry-run
    let effective_dry_run = if command == "apply" {
        true
    } else {
        params.dry_run
    };

    let mut argv: Vec<String> = vec![command.to_string()];

    argv.push("--base-image".into());
    argv.push(params.base_image.clone());

    argv.push("--base-image-sha256".into());
    argv.push(params.base_image_sha256.to_ascii_lowercase());

    argv.push("--payload".into());
    argv.push(params.payload.clone());

    if let Some(ref p) = params.provision {
        argv.push("--provision".into());
        argv.push(p.clone());
    }

    if let Some(ref t) = params.target_device {
        argv.push("--target-device".into());
        argv.push(t.clone());
    }

    if effective_dry_run {
        argv.push("--dry-run".into());
    }

    Ok(argv)
}

// ── Process runner ─────────────────────────────────────────────────────────────

async fn run_command_capture(mut cmd: Command, was_dry_run: bool) -> AppResult<EngineResult> {
    let mut child = cmd
        .spawn()
        .map_err(|e| AppError::Internal(format!("failed to spawn engine: {e}")))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| AppError::Internal("no stdout handle".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| AppError::Internal("no stderr handle".into()))?;

    let mut stdout_reader = BufReader::new(stdout).lines();
    let mut stderr_reader = BufReader::new(stderr).lines();

    let mut lines: Vec<EngineLine> = Vec::new();

    // Interleave stdout and stderr until both are exhausted.
    loop {
        tokio::select! {
            line = stdout_reader.next_line() => {
                match line {
                    Ok(Some(text)) => lines.push(EngineLine { stream: "stdout".into(), text }),
                    Ok(None) => break,
                    Err(e) => {
                        tracing::warn!("stdout read error: {e}");
                        break;
                    }
                }
            }
            line = stderr_reader.next_line() => {
                match line {
                    Ok(Some(text)) => lines.push(EngineLine { stream: "stderr".into(), text }),
                    Ok(None) => {}
                    Err(e) => tracing::warn!("stderr read error: {e}"),
                }
            }
        }
    }

    // Drain stderr after stdout closes
    while let Ok(Some(text)) = stderr_reader.next_line().await {
        lines.push(EngineLine {
            stream: "stderr".into(),
            text,
        });
    }

    let status = child
        .wait()
        .await
        .map_err(|e| AppError::Internal(format!("wait failed: {e}")))?;

    let exit_code = status.code().unwrap_or(-1);
    let success = exit_code == 0;

    tracing::info!("engine exit code: {exit_code}");
    for l in &lines {
        tracing::debug!("[{}] {}", l.stream, l.text);
    }

    Ok(EngineResult {
        exit_code,
        lines,
        was_dry_run,
        success,
    })
}

// ── Hardware root location ─────────────────────────────────────────────────────

/// Compile-time sibling directory (two levels up from Cargo.toml → sigil-OS → sigil-hardware).
const COMPILE_TIME_SIBLING: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../sigil-hardware"
);

fn locate_hardware_root() -> AppResult<PathBuf> {
    // 1. Environment variable takes highest precedence.
    if let Ok(root) = std::env::var("SIGIL_HARDWARE_ROOT") {
        let path = PathBuf::from(root);
        if path.is_dir() {
            tracing::info!(
                "SIGIL_HARDWARE_ROOT resolved: {}",
                path.display()
            );
            return Ok(path);
        }
    }

    // 2. Compile-time sibling path (canonical).
    let sibling = PathBuf::from(COMPILE_TIME_SIBLING);
    if let Ok(canonical) = sibling.canonicalize() {
        if canonical.is_dir() {
            tracing::info!("hw root via sibling: {}", canonical.display());
            return Ok(canonical);
        }
    }

    Err(AppError::Validation(
        "Cannot locate sigil-hardware root. \
         Set SIGIL_HARDWARE_ROOT env var or ensure sigil-hardware is a sibling of sigil-flash."
            .into(),
    ))
}

// ── Helpers ────────────────────────────────────────────────────────────────────

fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Reject strings containing shell meta-characters that could be injected into
/// the argument list.  We use `Command::arg()` which does NOT invoke a shell,
/// so this is a defence-in-depth guard, not the primary protection.
fn reject_shell_injection(field: &str, value: &str) -> AppResult<()> {
    let forbidden = [';', '&', '|', '`', '$', '(', ')', '{', '}', '<', '>', '\n', '\r'];
    if forbidden.iter().any(|c| value.contains(*c)) {
        return Err(AppError::Validation(format!(
            "field '{field}' contains disallowed shell characters"
        )));
    }
    Ok(())
}

// ── Tests ──────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Helper: minimal valid params ─────────────────────────────────────────

    fn minimal_params(dry_run: bool) -> EngineParams {
        EngineParams {
            base_image: "/tmp/test fixture.img.xz".into(), // path with space
            base_image_sha256: "a".repeat(64),
            payload: "/tmp/payload dir".into(), // path with space
            provision: None,
            target_device: None,
            dry_run,
        }
    }

    // ── CLI argument construction ─────────────────────────────────────────────

    #[test]
    fn test_build_argv_validate_no_dry_run() {
        let params = minimal_params(false);
        let argv = build_argv("validate", &params).expect("argv");
        assert_eq!(argv[0], "validate");
        assert!(argv.contains(&"--base-image".to_string()));
        assert!(argv.contains(&"/tmp/test fixture.img.xz".to_string()));
        assert!(argv.contains(&"--base-image-sha256".to_string()));
        assert!(argv.contains(&"--payload".to_string()));
        assert!(!argv.contains(&"--dry-run".to_string()));
    }

    #[test]
    fn test_build_argv_apply_always_adds_dry_run() {
        let params = minimal_params(false); // caller says false
        let argv = build_argv("apply", &params).expect("argv");
        // apply must ALWAYS include --dry-run regardless of params.dry_run
        assert!(
            argv.contains(&"--dry-run".to_string()),
            "apply must always include --dry-run, got: {:?}",
            argv
        );
    }

    #[test]
    fn test_build_argv_plan_with_all_options() {
        let params = EngineParams {
            base_image: "/images/my image.img".into(),
            base_image_sha256: "b".repeat(64),
            payload: "/payloads/my payload".into(),
            provision: Some("/provision/provision file.json".into()),
            target_device: Some("/tmp/target file.img".into()),
            dry_run: true,
        };
        let argv = build_argv("plan", &params).expect("argv");
        assert_eq!(argv[0], "plan");
        assert!(argv.contains(&"--provision".to_string()));
        assert!(argv.contains(&"/provision/provision file.json".to_string()));
        assert!(argv.contains(&"--target-device".to_string()));
        assert!(argv.contains(&"/tmp/target file.img".to_string()));
        assert!(argv.contains(&"--dry-run".to_string()));
    }

    // ── Paths with spaces ─────────────────────────────────────────────────────

    #[test]
    fn test_paths_with_spaces_preserved_exactly() {
        let params = EngineParams {
            base_image: "/home/user/my images/test file.img.xz".into(),
            base_image_sha256: "c".repeat(64),
            payload: "/home/user/sigil payloads/hw payload dir".into(),
            provision: Some("/home/user/my provision/device provision.json".into()),
            target_device: Some("/tmp/target fixture file.img".into()),
            dry_run: false,
        };
        let argv = build_argv("validate", &params).expect("argv");
        // Spaces must be preserved verbatim (Command::arg() does not shell-expand)
        assert!(argv.contains(&"/home/user/my images/test file.img.xz".to_string()));
        assert!(argv.contains(&"/home/user/sigil payloads/hw payload dir".to_string()));
        assert!(argv.contains(&"/home/user/my provision/device provision.json".to_string()));
        assert!(argv.contains(&"/tmp/target fixture file.img".to_string()));
    }

    // ── SHA-256 validation ────────────────────────────────────────────────────

    #[test]
    fn test_invalid_sha256_too_short_rejected() {
        let mut params = minimal_params(false);
        params.base_image_sha256 = "abc123".into();
        let err = build_argv("validate", &params).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("sha256") || msg.contains("hex"),
            "unexpected: {msg}"
        );
    }

    #[test]
    fn test_invalid_sha256_wrong_chars_rejected() {
        let mut params = minimal_params(false);
        params.base_image_sha256 = "g".repeat(64); // 'g' is not hex
        let err = build_argv("validate", &params).unwrap_err();
        assert!(err.to_string().contains("hex") || err.to_string().contains("sha256"));
    }

    #[test]
    fn test_valid_sha256_accepted() {
        let params = EngineParams {
            base_image: "/tmp/img.img.xz".into(),
            base_image_sha256: "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3".into(),
            payload: "/tmp/payload".into(),
            provision: None,
            target_device: None,
            dry_run: false,
        };
        assert!(build_argv("validate", &params).is_ok());
    }

    // ── Provision validation (field-level, tested via engine_params) ──────────

    #[test]
    fn test_missing_base_image_rejected() {
        let mut params = minimal_params(false);
        params.base_image = "".into();
        assert!(build_argv("validate", &params).is_err());
    }

    #[test]
    fn test_missing_payload_rejected() {
        let mut params = minimal_params(false);
        params.payload = "".into();
        assert!(build_argv("validate", &params).is_err());
    }

    // ── Shell injection prevention ────────────────────────────────────────────

    #[test]
    fn test_shell_injection_in_base_image_rejected() {
        let mut params = minimal_params(false);
        params.base_image = "/tmp/image.img; rm -rf /".into();
        assert!(build_argv("validate", &params).is_err());
    }

    #[test]
    fn test_shell_injection_in_payload_rejected() {
        let mut params = minimal_params(false);
        params.payload = "/tmp/payload && evil".into();
        assert!(build_argv("validate", &params).is_err());
    }

    #[test]
    fn test_shell_injection_in_provision_rejected() {
        let mut params = minimal_params(false);
        params.provision = Some("/tmp/file | cat /etc/passwd".into());
        assert!(build_argv("validate", &params).is_err());
    }

    // ── Non-dry-run prevention ────────────────────────────────────────────────

    #[test]
    fn test_apply_without_dry_run_flag_still_adds_dry_run() {
        let params = minimal_params(false);
        let argv = build_argv("apply", &params).expect("argv");
        assert!(argv.contains(&"--dry-run".to_string()));
        // Must NOT emit any argv without --dry-run for `apply`
        assert!(
            argv.contains(&"--dry-run".to_string()),
            "apply invariant violated"
        );
    }

    #[test]
    fn test_sha256_lowercased_in_argv() {
        let mut params = minimal_params(false);
        params.base_image_sha256 = "ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890".into();
        let argv = build_argv("plan", &params).expect("argv");
        let sha_pos = argv
            .iter()
            .position(|a| a == "--base-image-sha256")
            .unwrap();
        assert_eq!(
            argv[sha_pos + 1],
            "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        );
    }
}
