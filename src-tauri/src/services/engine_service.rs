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
use std::fs::{self, OpenOptions};
use std::io::Write;
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
    /// Optional path to the protected manufacturing secret input.
    pub secrets: Option<String>,
    /// Optional target path; must be a regular file when dry_run is true.
    pub target_device: Option<String>,
    /// Must be `true` for `apply`; also accepted (and enforced) for other commands.
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PanelSecretsDocument {
    #[serde(rename = "_schema_version")]
    pub schema_version: String,
    pub panel_pin: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SecretWriteResult {
    pub path: String,
    pub success: bool,
    pub schema_version: String,
    pub panel_pin_configured: bool,
    pub pin_length: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ProvisionDocument {
    #[serde(rename = "_schema_version")]
    pub schema_version: String,
    pub serial_number: String,
    pub model: String,
    pub model_version: String,
    pub batch: String,
    pub capabilities: ProvisionCapabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ProvisionCapabilities {
    pub i2s_dac: bool,
}

// ── Service ───────────────────────────────────────────────────────────────────

pub struct FlasherEngineService {
    /// Absolute path to the `flasher-rs` binary.
    engine_bin: PathBuf,
    /// Absolute path to `build-flasher-payload.sh`.
    payload_script: PathBuf,
    /// Default manufacturing secret location, outside Git repositories.
    secrets_dir: PathBuf,
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
        let secrets_dir = hw_root
            .parent()
            .ok_or_else(|| AppError::Validation("hardware root has no parent".into()))?
            .join("artifacts")
            .join("secrets");

        if !engine_bin.exists() {
            return Err(AppError::Validation(format!(
                "flasher-rs binary not found at {}. Run `cargo build` in sigil-hardware/flasher-rs.",
                engine_bin.display()
            )));
        }

        Ok(Self {
            engine_bin,
            payload_script,
            secrets_dir,
        })
    }

    /// Construct a service with placeholder paths (used when `new()` fails at startup).
    /// Every method will return `AppError::Validation` describing the missing binary.
    pub fn new_unchecked() -> Self {
        Self {
            engine_bin: PathBuf::from("/dev/null/flasher-rs-not-found"),
            payload_script: PathBuf::from("/dev/null/build-flasher-payload-not-found"),
            secrets_dir: std::env::temp_dir().join("sigil-artifacts").join("secrets"),
        }
    }

    /// Returns the resolved path to the `flasher-rs` binary (for display/tests).
    pub fn engine_bin(&self) -> &Path {
        &self.engine_bin
    }

    pub fn default_secrets_path(&self) -> AppResult<String> {
        if !self.secrets_dir.exists() {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(&self.secrets_dir).map_err(|error| {
                AppError::Internal(format!("create manufacturing secrets directory: {error}"))
            })?;
        }
        validate_secret_parent(&self.secrets_dir)?;
        Ok(self
            .secrets_dir
            .join("sigil_secrets.json")
            .to_string_lossy()
            .to_string())
    }

    pub fn generate_panel_pin(&self) -> AppResult<String> {
        loop {
            let mut pin = String::with_capacity(8);
            while pin.len() < 8 {
                let byte = secure_random_bytes::<1>()?[0];
                if byte < 250 {
                    pin.push(char::from(b'0' + (byte % 10)));
                }
            }
            if validate_panel_pin(&pin).is_ok() {
                return Ok(pin);
            }
        }
    }

    pub fn write_secrets(
        &self,
        path: &str,
        panel_pin: &str,
        overwrite_confirmed: bool,
    ) -> AppResult<SecretWriteResult> {
        validate_panel_pin(panel_pin)?;
        let destination = PathBuf::from(path);
        if path.is_empty() {
            return Err(AppError::Validation("secret path must not be empty".into()));
        }
        let parent = destination
            .parent()
            .ok_or_else(|| AppError::Validation("secret path must have a parent".into()))?;
        validate_secret_parent(parent)?;
        reject_git_controlled_path(parent)?;

        if let Ok(metadata) = fs::symlink_metadata(&destination) {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(AppError::Validation(
                    "secret destination must be a regular non-symlink file".into(),
                ));
            }
            if !overwrite_confirmed {
                return Err(AppError::Validation(
                    "secret destination exists; explicit overwrite confirmation required".into(),
                ));
            }
        }

        let document = PanelSecretsDocument {
            schema_version: "1.0".into(),
            panel_pin: panel_pin.to_owned(),
        };
        let bytes = serde_json::to_vec_pretty(&document)
            .map_err(|error| AppError::Internal(format!("serialize secret input: {error}")))?;
        let file_name = destination
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| AppError::Validation("secret filename must be UTF-8".into()))?;
        let nonce = u64::from_ne_bytes(secure_random_bytes::<8>()?);
        let temporary = parent.join(format!(".{file_name}.{}.{nonce}.tmp", std::process::id()));

        let result = (|| -> AppResult<()> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary).map_err(|error| {
                AppError::Internal(format!("create secret temporary file: {error}"))
            })?;
            file.write_all(&bytes)
                .and_then(|_| file.write_all(b"\n"))
                .and_then(|_| file.sync_all())
                .map_err(|error| AppError::Internal(format!("write secret input: {error}")))?;
            fs::rename(&temporary, &destination)
                .map_err(|error| AppError::Internal(format!("replace secret input: {error}")))?;
            #[cfg(unix)]
            {
                let directory = OpenOptions::new()
                    .read(true)
                    .open(parent)
                    .map_err(|error| {
                        AppError::Internal(format!("open secret directory: {error}"))
                    })?;
                directory.sync_all().map_err(|error| {
                    AppError::Internal(format!("sync secret directory: {error}"))
                })?;
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;

        Ok(SecretWriteResult {
            path: destination.to_string_lossy().to_string(),
            success: true,
            schema_version: "1.0".into(),
            panel_pin_configured: true,
            pin_length: panel_pin.len(),
        })
    }

    /// Validate and atomically save the non-secret manufacturing provision.
    pub fn write_provision(&self, path: &str, provision: &ProvisionDocument) -> AppResult<String> {
        validate_provision(provision)?;
        let destination = PathBuf::from(path);
        let parent = destination.parent().ok_or_else(|| {
            AppError::Validation("provision path must have a parent directory".into())
        })?;
        if path.trim().is_empty() || !parent.is_dir() {
            return Err(AppError::Validation(
                "provision destination directory does not exist".into(),
            ));
        }
        let file_name = destination
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| AppError::Validation("provision filename must be UTF-8".into()))?;
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|error| AppError::Internal(format!("system clock before epoch: {error}")))?
            .as_nanos();
        let temporary = parent.join(format!(".{file_name}.{}.{nonce}.tmp", std::process::id()));
        let bytes = serde_json::to_vec_pretty(provision)
            .map_err(|error| AppError::Internal(format!("serialize provision: {error}")))?;

        let result = (|| -> AppResult<()> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary).map_err(|error| {
                AppError::Internal(format!("create provision temporary file: {error}"))
            })?;
            file.write_all(&bytes)
                .and_then(|_| file.write_all(b"\n"))
                .and_then(|_| file.sync_all())
                .map_err(|error| AppError::Internal(format!("write provision: {error}")))?;
            fs::rename(&temporary, &destination)
                .map_err(|error| AppError::Internal(format!("replace provision: {error}")))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;
        Ok(destination.to_string_lossy().to_string())
    }

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

    /// Allows real writes if `params.dry_run` is false.
    pub async fn apply(&self, params: &EngineParams) -> AppResult<EngineResult> {
        let argv = build_argv("apply", params)?;
        let refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
        self.run_engine(&refs, params.dry_run).await
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
    if let Some(ref s) = params.secrets {
        reject_shell_injection("secrets", s)?;
    }
    if let Some(ref t) = params.target_device {
        reject_shell_injection("target_device", t)?;
    }

    let effective_dry_run = params.dry_run;

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

    if let Some(ref s) = params.secrets {
        argv.push("--secrets".into());
        argv.push(s.clone());
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
const COMPILE_TIME_SIBLING: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../sigil-hardware");

fn locate_hardware_root() -> AppResult<PathBuf> {
    // 1. Environment variable takes highest precedence.
    if let Ok(root) = std::env::var("SIGIL_HARDWARE_ROOT") {
        let path = PathBuf::from(root);
        if path.is_dir() {
            tracing::info!("SIGIL_HARDWARE_ROOT resolved: {}", path.display());
            return Ok(path);
        }
    }

    // 2. Try child directory (sigil-flash/sigil-hardware)
    let child_path = PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../sigil-hardware"));
    if let Ok(canonical) = child_path.canonicalize() {
        if canonical.is_dir() {
            tracing::info!("hw root via child: {}", canonical.display());
            return Ok(canonical);
        }
    }

    // 3. Compile-time sibling path (canonical).
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

fn secure_random_bytes<const N: usize>() -> AppResult<[u8; N]> {
    let mut bytes = [0_u8; N];
    getrandom::fill(&mut bytes).map_err(|error| {
        AppError::Internal(format!("operating-system RNG unavailable: {error}"))
    })?;
    Ok(bytes)
}

pub fn validate_panel_pin(pin: &str) -> AppResult<()> {
    if !(6..=12).contains(&pin.len()) || !pin.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(AppError::Validation(
            "panel PIN must contain exactly 6 to 12 decimal digits".into(),
        ));
    }
    let all_repeated = pin.bytes().all(|byte| byte == pin.as_bytes()[0]);
    let ascending = "12345678901234567890".contains(pin);
    let descending = "98765432109876543210".contains(pin);
    if all_repeated || ascending || descending {
        return Err(AppError::Validation("panel PIN is too trivial".into()));
    }
    Ok(())
}

fn validate_secret_parent(parent: &Path) -> AppResult<()> {
    let metadata = fs::symlink_metadata(parent)
        .map_err(|_| AppError::Validation("secret destination directory does not exist".into()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(AppError::Validation(
            "secret destination parent must be a regular directory".into(),
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o022 != 0 {
            return Err(AppError::Validation(
                "secret destination directory must not be group/world writable".into(),
            ));
        }
    }
    Ok(())
}

fn reject_git_controlled_path(path: &Path) -> AppResult<()> {
    let mut current = Some(path);
    while let Some(candidate) = current {
        let marker = candidate.join(".git");
        if marker.is_file() || marker.join("HEAD").is_file() {
            return Err(AppError::Validation(
                "secret files must not be stored inside a Git worktree".into(),
            ));
        }
        current = candidate.parent();
    }
    Ok(())
}

fn validate_provision(provision: &ProvisionDocument) -> AppResult<()> {
    if provision.schema_version != "1.0" {
        return Err(AppError::Validation("_schema_version must be 1.0".into()));
    }
    for (field, value, maximum) in [
        ("serial_number", provision.serial_number.as_str(), 64_usize),
        ("model", provision.model.as_str(), 64),
        ("model_version", provision.model_version.as_str(), 32),
        ("batch", provision.batch.as_str(), 64),
    ] {
        if value.is_empty()
            || value.len() > maximum
            || !value
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || " ._+:/-".contains(character))
        {
            return Err(AppError::Validation(format!(
                "{field} must be a non-empty safe string of at most {maximum} characters"
            )));
        }
    }
    if !provision
        .serial_number
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "-_.".contains(character))
    {
        return Err(AppError::Validation(
            "serial_number contains unsupported characters".into(),
        ));
    }
    Ok(())
}

/// Reject strings containing shell meta-characters that could be injected into
/// the argument list.  We use `Command::arg()` which does NOT invoke a shell,
/// so this is a defence-in-depth guard, not the primary protection.
fn reject_shell_injection(field: &str, value: &str) -> AppResult<()> {
    let forbidden = [
        ';', '&', '|', '`', '$', '(', ')', '{', '}', '<', '>', '\n', '\r',
    ];
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
            secrets: None,
            target_device: None,
            dry_run,
        }
    }

    fn valid_provision() -> ProvisionDocument {
        ProvisionDocument {
            schema_version: "1.0".into(),
            serial_number: "SIGIL-000001".into(),
            model: "Sigil-Streamer".into(),
            model_version: "v1".into(),
            batch: "2026-01".into(),
            capabilities: ProvisionCapabilities { i2s_dac: true },
        }
    }

    #[test]
    fn test_provision_json_contains_model_version_and_boolean_i2s() {
        let json = serde_json::to_value(valid_provision()).expect("serialize");
        assert_eq!(json["model_version"], "v1");
        assert_eq!(json["capabilities"]["i2s_dac"], true);
        assert!(json.get("token").is_none());
        assert!(json.get("panel_pin").is_none());
    }

    #[test]
    fn test_empty_serial_number_is_rejected() {
        let mut provision = valid_provision();
        provision.serial_number.clear();
        assert!(validate_provision(&provision).is_err());
    }

    #[test]
    fn test_string_true_i2s_is_rejected_by_typed_contract() {
        let json = r#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":"true"}}"#;
        assert!(serde_json::from_str::<ProvisionDocument>(json).is_err());
    }

    #[test]
    fn test_write_provision_preserves_path_with_spaces() {
        let directory =
            std::env::temp_dir().join(format!("sigil flash provision {}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("fixture directory");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
                .expect("fixture mode");
        }
        let path = directory.join("device provision.json");
        let service = FlasherEngineService::new_unchecked();
        let written = service
            .write_provision(path.to_str().expect("UTF-8 path"), &valid_provision())
            .expect("write provision");
        assert_eq!(written, path.to_string_lossy());
        let document: ProvisionDocument =
            serde_json::from_slice(&std::fs::read(&path).expect("read saved provision"))
                .expect("parse saved provision");
        assert_eq!(document.model_version, "v1");
        assert!(document.capabilities.i2s_dac);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn test_generated_panel_pins_are_valid_and_not_constant() {
        let service = FlasherEngineService::new_unchecked();
        let pins = (0..64)
            .map(|_| service.generate_panel_pin().expect("OS RNG"))
            .collect::<std::collections::BTreeSet<_>>();
        assert!(pins.len() > 1);
        assert!(pins.iter().all(|pin| validate_panel_pin(pin).is_ok()));
    }

    #[test]
    fn test_panel_pin_policy_rejects_malformed_and_trivial_values() {
        for pin in [
            "12345",
            "1234567890123",
            "12 4567",
            "000000",
            "111111",
            "123456",
        ] {
            assert!(validate_panel_pin(pin).is_err(), "accepted {pin}");
        }
        assert!(validate_panel_pin("80427159").is_ok());
    }

    #[test]
    fn test_secret_writer_is_atomic_private_and_requires_overwrite_confirmation() {
        let directory = std::env::temp_dir().join(format!(
            "sigil manufacturing secrets {}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("secret directory");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).expect("mode");
        }
        let path = directory.join("panel secrets.json");
        let service = FlasherEngineService::new_unchecked();
        let result = service
            .write_secrets(path.to_str().expect("UTF-8"), "80427159", false)
            .expect("write secrets");
        assert!(result.success && result.panel_pin_configured);
        assert_eq!(result.pin_length, 8);
        assert!(service
            .write_secrets(path.to_str().expect("UTF-8"), "80427159", false)
            .is_err());
        let metadata = fs::symlink_metadata(&path).expect("metadata");
        assert!(metadata.is_file() && !metadata.file_type().is_symlink());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        }
        let parsed: PanelSecretsDocument =
            serde_json::from_slice(&fs::read(&path).expect("read")).expect("strict document");
        assert_eq!(parsed.panel_pin, "80427159");
        assert!(directory.read_dir().expect("read dir").all(|entry| !entry
            .expect("entry")
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")));
        let _ = fs::remove_dir_all(directory);
    }

    #[tokio::test]
    #[ignore = "cross-repository dry-run; run explicitly for release validation"]
    async fn test_complete_tauri_adapter_to_flasher_dry_run() {
        let service = FlasherEngineService::new().expect("locate built flasher-rs");
        let directory = std::env::temp_dir().join(format!(
            "sigil flash complete dry run {}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("fixture directory");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
                .expect("fixture mode");
        }
        let base_image = directory.join("base image.img");
        let target = directory.join("target fixture.img");
        let provision_path = directory.join("device provision.json");
        let secrets_path = directory.join("panel secrets.json");
        let payload = directory.join("payload with spaces");
        std::fs::write(&base_image, []).expect("base image fixture");
        std::fs::write(&target, []).expect("target fixture");
        service
            .write_provision(
                provision_path.to_str().expect("UTF-8 provision path"),
                &valid_provision(),
            )
            .expect("Tauri provision writer");
        service
            .write_secrets(
                secrets_path.to_str().expect("UTF-8 secrets path"),
                "80427159",
                false,
            )
            .expect("Tauri secret writer");
        let payload_result = std::process::Command::new("bash")
            .arg(&service.payload_script)
            .arg(&payload)
            .env("SIGIL_PAYLOAD_ALLOW_DIRTY", "true")
            .output()
            .expect("payload builder");
        assert!(
            payload_result.status.success(),
            "payload builder failed: {}",
            String::from_utf8_lossy(&payload_result.stderr)
        );
        let params = EngineParams {
            base_image: base_image.to_string_lossy().to_string(),
            base_image_sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                .into(),
            payload: payload.to_string_lossy().to_string(),
            provision: Some(provision_path.to_string_lossy().to_string()),
            secrets: Some(secrets_path.to_string_lossy().to_string()),
            target_device: Some(target.to_string_lossy().to_string()),
            dry_run: true,
        };
        let result = service.apply(&params).await.expect("adapter dry-run");
        assert!(
            result.success,
            "dry-run failed: {}",
            result
                .lines
                .iter()
                .map(|line| line.text.as_str())
                .collect::<Vec<_>>()
                .join(" | ")
        );
        assert!(result.was_dry_run);
        let output = result
            .lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        for expected in [
            "serial_number: SIGIL-000001",
            "model: Sigil-Streamer",
            "model_version: v1",
            "batch: 2026-01",
            "capabilities.i2s_dac: true",
        ] {
            assert!(output.contains(expected), "missing {expected} in {output}");
        }
        assert!(!output.contains("fake-device-token"));
        assert!(!output.contains("80427159"));
        assert!(output.contains("panel PIN configured: yes"));
        let _ = std::fs::remove_dir_all(directory);
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
    fn test_build_argv_apply_without_dry_run_allows_real_write() {
        let params = minimal_params(false);
        let argv = build_argv("apply", &params).expect("argv");
        assert!(
            !argv.contains(&"--dry-run".to_string()),
            "real apply must omit --dry-run, got: {:?}",
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
            secrets: Some("/secrets/panel secrets.json".into()),
            target_device: Some("/tmp/target file.img".into()),
            dry_run: true,
        };
        let argv = build_argv("plan", &params).expect("argv");
        assert_eq!(argv[0], "plan");
        assert!(argv.contains(&"--provision".to_string()));
        assert!(argv.contains(&"/provision/provision file.json".to_string()));
        assert!(argv.contains(&"--secrets".to_string()));
        assert!(argv.contains(&"/secrets/panel secrets.json".to_string()));
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
            secrets: Some("/home/user/manufacturing secrets/panel secret.json".into()),
            target_device: Some("/tmp/target fixture file.img".into()),
            dry_run: false,
        };
        let argv = build_argv("validate", &params).expect("argv");
        // Spaces must be preserved verbatim (Command::arg() does not shell-expand)
        assert!(argv.contains(&"/home/user/my images/test file.img.xz".to_string()));
        assert!(argv.contains(&"/home/user/sigil payloads/hw payload dir".to_string()));
        assert!(argv.contains(&"/home/user/my provision/device provision.json".to_string()));
        assert!(argv.contains(&"/home/user/manufacturing secrets/panel secret.json".to_string()));
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
            base_image_sha256: "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"
                .into(),
            payload: "/tmp/payload".into(),
            provision: None,
            secrets: None,
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

    // ── Apply mode selection ──────────────────────────────────────────────────

    #[test]
    fn test_apply_with_dry_run_flag_preserves_dry_run() {
        let params = minimal_params(true);
        let argv = build_argv("apply", &params).expect("argv");
        assert!(argv.contains(&"--dry-run".to_string()));
    }

    #[test]
    fn test_sha256_lowercased_in_argv() {
        let mut params = minimal_params(false);
        params.base_image_sha256 =
            "ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890".into();
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
