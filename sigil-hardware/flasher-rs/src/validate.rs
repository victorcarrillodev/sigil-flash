use crate::model::{ManufacturingSecrets, Provision, Severity, ValidationItem, ValidationResult};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Read};
use std::path::{Component, Path};

pub const OFFICIAL_IMAGE_FILENAME: &str = "2026-06-18-raspios-trixie-arm64-lite.img.xz";
pub const OFFICIAL_IMAGE_SHA256: &str =
    "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3";

const PAYLOAD_MANIFEST: &str = "payload-manifest.json";
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_PROVISION_BYTES: u64 = 4096;
const MAX_SECRETS_BYTES: u64 = 1024;

#[derive(Debug, Deserialize)]
struct PayloadManifest {
    #[serde(rename = "_schema_version")]
    schema_version: String,
    payload_type: String,
    source_commit: String,
    target: PayloadTarget,
    files: Vec<PayloadFile>,
}

#[derive(Debug, Deserialize)]
struct PayloadTarget {
    os: String,
    release: String,
    architecture: String,
    hardware: String,
}

#[derive(Debug, Deserialize)]
struct PayloadFile {
    path: String,
    sha256: String,
    mode: String,
}

/// Validate all engine inputs without writing, mounting, or decompressing.
pub fn validate_inputs(
    base_image: &Path,
    expected_base_sha256: Option<&str>,
    payload: &Path,
    offline_packages: &Option<std::path::PathBuf>,
    target_device: &Option<std::path::PathBuf>,
    provision: &Option<std::path::PathBuf>,
    secrets: &Option<std::path::PathBuf>,
) -> ValidationResult {
    let mut items = Vec::new();

    validate_base_image(base_image, expected_base_sha256, &mut items);
    validate_payload(payload, &mut items);
    validate_offline_packages(
        base_image,
        expected_base_sha256,
        payload,
        offline_packages.as_deref(),
        &mut items,
    );
    validate_provision(provision.as_deref(), &mut items);
    validate_secrets(secrets.as_deref(), &mut items);
    validate_target(base_image, target_device.as_deref(), &mut items);

    let valid = items
        .iter()
        .all(|item| !matches!(item.severity, Severity::Error));
    ValidationResult { valid, items }
}

fn validate_offline_packages(
    base_image: &Path,
    expected_base_sha256: Option<&str>,
    payload: &Path,
    repository: Option<&Path>,
    items: &mut Vec<ValidationItem>,
) {
    let Some(repository) = repository else {
        error(items, "--offline-packages is required for manufacturing");
        return;
    };
    let contract = payload.join("manifests/offline-package-contract.json");
    match crate::offline::validate_repository(repository, &contract) {
        Ok(summary) => {
            let actual_name = base_image.file_name().and_then(|name| name.to_str());
            let expected_sha256 = expected_base_sha256.map(str::to_ascii_lowercase);
            if actual_name != Some(summary.base_image_name.as_str())
                || expected_sha256.as_deref() != Some(summary.base_image_sha256.as_str())
            {
                error(
                    items,
                    format!(
                        "offline package bundle {} is incompatible with base image {}",
                        summary.bundle_version,
                        base_image.display()
                    ),
                );
            } else {
                info(
                    items,
                    format!(
                        "Offline package repository validated. bundle={}, direct_packages={}, resolved_packages={}, distribution={}, architecture={}, total_bytes={}, base_image_compatible=yes",
                        summary.bundle_version,
                        summary.direct_package_count,
                        summary.resolved_package_count,
                        summary.distribution,
                        summary.architecture,
                        summary.total_bytes,
                    ),
                );
            }
        }
        Err(message) => error(
            items,
            format!("offline package repository invalid: {message}"),
        ),
    }
}

pub fn validate_panel_pin(pin: &str) -> Result<(), String> {
    if !(6..=12).contains(&pin.len()) || !pin.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("panel PIN must contain exactly 6 to 12 decimal digits".into());
    }
    let repeated = pin.bytes().all(|byte| byte == pin.as_bytes()[0]);
    let ascending = "12345678901234567890".contains(pin);
    let descending = "98765432109876543210".contains(pin);
    if repeated || ascending || descending {
        return Err("panel PIN is too trivial".into());
    }
    Ok(())
}

pub fn load_secrets(path: &Path) -> Result<ManufacturingSecrets, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error_value| format!("--secrets cannot be read: {error_value}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("--secrets must be a regular non-symlink file".into());
    }
    if metadata.len() > MAX_SECRETS_BYTES {
        return Err("--secrets exceeds 1024 bytes".into());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options
        .open(path)
        .map_err(|error_value| format!("--secrets cannot be opened safely: {error_value}"))?;
    let opened = file
        .metadata()
        .map_err(|error_value| format!("--secrets metadata unavailable: {error_value}"))?;
    if !opened.is_file() || opened.len() != metadata.len() {
        return Err("--secrets changed during validation".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if (opened.dev(), opened.ino()) != (metadata.dev(), metadata.ino()) {
            return Err("--secrets changed during validation".into());
        }
        if opened.permissions().mode() & 0o777 != 0o600 {
            return Err("--secrets must have mode 0600".into());
        }
    }
    let mut bytes = Vec::with_capacity((opened.len() as usize).min(MAX_SECRETS_BYTES as usize));
    file.take(MAX_SECRETS_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error_value| format!("--secrets cannot be read: {error_value}"))?;
    if bytes.len() as u64 > MAX_SECRETS_BYTES {
        return Err("--secrets exceeds 1024 bytes".into());
    }
    if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        return Err("--secrets must be UTF-8 without BOM".into());
    }
    let secrets: ManufacturingSecrets = serde_json::from_slice(&bytes)
        .map_err(|error_value| format!("--secrets violates the strict schema: {error_value}"))?;
    if secrets.schema_version != "1.0" {
        return Err("--secrets _schema_version must be 1.0".into());
    }
    validate_panel_pin(&secrets.panel_pin)?;
    Ok(secrets)
}

fn validate_secrets(path: Option<&Path>, items: &mut Vec<ValidationItem>) {
    let Some(path) = path else {
        error(
            items,
            "secret file supplied: no; new manufacturing requires --secrets",
        );
        return;
    };
    match load_secrets(path) {
        Ok(secrets) => info(
            items,
            format!(
                "secret file supplied: yes; schema valid: yes; panel PIN configured: yes ({} digits)",
                secrets.panel_pin.len()
            ),
        ),
        Err(message) => error(items, message),
    }
}

fn validate_base_image(path: &Path, expected: Option<&str>, items: &mut Vec<ValidationItem>) {
    let metadata = match fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => metadata,
        Ok(_) => {
            error(
                items,
                format!("--base-image is not a regular file: {}", path.display()),
            );
            return;
        }
        Err(error_value) => {
            error(
                items,
                format!(
                    "--base-image cannot be read at {}: {error_value}",
                    path.display()
                ),
            );
            return;
        }
    };

    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    if !(filename.ends_with(".img") || filename.ends_with(".img.xz")) {
        error(
            items,
            "--base-image must end in .img or .img.xz; no implicit format conversion is allowed",
        );
        return;
    }
    info(
        items,
        format!(
            "--base-image: readable {} input ({} bytes)",
            if filename.ends_with(".img.xz") {
                ".img.xz"
            } else {
                ".img"
            },
            metadata.len()
        ),
    );

    let Some(expected) = expected else {
        error(
            items,
            "--base-image-sha256 is required; unverified images are rejected",
        );
        return;
    };
    let expected = expected.to_ascii_lowercase();
    if !is_sha256(&expected) {
        error(
            items,
            "--base-image-sha256 must contain exactly 64 hexadecimal characters",
        );
        return;
    }

    match sha256_file(path) {
        Ok(actual) if actual == expected => {
            info(items, format!("base image SHA-256 verified: {actual}"));
        }
        Ok(actual) => {
            error(
                items,
                format!("base image SHA-256 mismatch: expected {expected}, got {actual}"),
            );
            return;
        }
        Err(error_value) => {
            error(items, format!("cannot hash base image: {error_value}"));
            return;
        }
    }

    if filename == OFFICIAL_IMAGE_FILENAME {
        if expected == OFFICIAL_IMAGE_SHA256 {
            info(
                items,
                "official image contract: Raspberry Pi OS Lite, Debian 13 Trixie, arm64, Raspberry Pi Zero 2 W",
            );
        } else {
            error(
                items,
                format!(
                    "official image filename requires published SHA-256 {OFFICIAL_IMAGE_SHA256}"
                ),
            );
        }
    } else {
        warning(
            items,
            "non-official fixture/image: checksum is verified, but OS release and architecture are not introspected",
        );
    }
}

fn validate_payload(payload: &Path, items: &mut Vec<ValidationItem>) {
    if !payload.is_dir() {
        error(
            items,
            format!("--payload is not a directory: {}", payload.display()),
        );
        return;
    }

    let manifest_path = payload.join(PAYLOAD_MANIFEST);
    let manifest_metadata = match fs::metadata(&manifest_path) {
        Ok(metadata) if metadata.is_file() && metadata.len() <= MAX_MANIFEST_BYTES => metadata,
        Ok(metadata) if metadata.len() > MAX_MANIFEST_BYTES => {
            error(items, "payload-manifest.json exceeds 1 MiB");
            return;
        }
        Ok(_) => {
            error(items, "payload-manifest.json is not a regular file");
            return;
        }
        Err(error_value) => {
            error(
                items,
                format!("payload-manifest.json cannot be read: {error_value}"),
            );
            return;
        }
    };
    let _ = manifest_metadata;

    let manifest: PayloadManifest = match File::open(&manifest_path)
        .map_err(|error_value| error_value.to_string())
        .and_then(|file| {
            serde_json::from_reader(file).map_err(|error_value| error_value.to_string())
        }) {
        Ok(manifest) => manifest,
        Err(error_value) => {
            error(
                items,
                format!("invalid payload-manifest.json: {error_value}"),
            );
            return;
        }
    };

    if manifest.schema_version != "1.0" {
        error(items, "payload manifest _schema_version must be 1.0");
    }
    if manifest.payload_type != "sigil-hardware-install" {
        error(items, "payload_type must be sigil-hardware-install");
    }
    if !is_git_commit(&manifest.source_commit) {
        error(
            items,
            "payload source_commit must be a 40-character Git commit ID",
        );
    }
    if manifest.target.os != "raspberry-pi-os-lite"
        || manifest.target.release != "trixie"
        || manifest.target.architecture != "arm64"
        || manifest.target.hardware != "raspberry-pi-zero-2-w"
    {
        error(
            items,
            "payload target must be raspberry-pi-os-lite/trixie/arm64/raspberry-pi-zero-2-w",
        );
    }
    if manifest.files.is_empty() {
        error(items, "payload manifest has no files");
        return;
    }

    let mut declared = BTreeSet::new();
    for entry in &manifest.files {
        if !safe_payload_path(&entry.path) {
            error(
                items,
                format!("unsafe or excluded payload path: {}", entry.path),
            );
            continue;
        }
        if !declared.insert(entry.path.clone()) {
            error(items, format!("duplicate payload path: {}", entry.path));
            continue;
        }
        if !is_sha256(&entry.sha256) {
            error(
                items,
                format!("invalid SHA-256 for payload file {}", entry.path),
            );
            continue;
        }
        let expected_mode = match parse_mode(&entry.mode) {
            Some(mode) => mode,
            None => {
                error(
                    items,
                    format!("invalid mode for payload file {}", entry.path),
                );
                continue;
            }
        };
        let file_path = payload.join(&entry.path);
        let metadata = match fs::symlink_metadata(&file_path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                error(
                    items,
                    format!("payload symlinks are not allowed: {}", entry.path),
                );
                continue;
            }
            Ok(metadata) if metadata.is_file() => metadata,
            Ok(_) => {
                error(
                    items,
                    format!("payload entry is not a regular file: {}", entry.path),
                );
                continue;
            }
            Err(error_value) => {
                error(
                    items,
                    format!("missing payload file {}: {error_value}", entry.path),
                );
                continue;
            }
        };

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let actual_mode = metadata.permissions().mode() & 0o777;
            if actual_mode != expected_mode {
                error(
                    items,
                    format!(
                        "payload mode mismatch for {}: expected {:04o}, got {:04o}",
                        entry.path, expected_mode, actual_mode
                    ),
                );
            }
        }

        match sha256_file(&file_path) {
            Ok(actual) if actual == entry.sha256.to_ascii_lowercase() => {}
            Ok(actual) => error(
                items,
                format!(
                    "payload SHA-256 mismatch for {}: expected {}, got {actual}",
                    entry.path, entry.sha256
                ),
            ),
            Err(error_value) => error(
                items,
                format!("cannot hash payload file {}: {error_value}", entry.path),
            ),
        }
    }

    let mut actual = BTreeSet::new();
    if let Err(error_value) = collect_payload_files(payload, payload, &mut actual) {
        error(items, format!("cannot enumerate payload: {error_value}"));
        return;
    }
    if actual != declared {
        let missing: Vec<_> = declared.difference(&actual).cloned().collect();
        let unexpected: Vec<_> = actual.difference(&declared).cloned().collect();
        if !missing.is_empty() {
            error(
                items,
                format!("payload files missing from disk: {}", missing.join(", ")),
            );
        }
        if !unexpected.is_empty() {
            error(
                items,
                format!(
                    "unexpected files not declared by payload manifest: {}",
                    unexpected.join(", ")
                ),
            );
        }
    }

    for required in ["install.sh", "panel", "scripts", "services", "conf"] {
        let path = payload.join(required);
        if !path.exists() {
            error(
                items,
                format!("required payload component is missing: {required}"),
            );
        }
    }

    if !items
        .iter()
        .any(|item| matches!(item.severity, Severity::Error))
    {
        info(
            items,
            format!(
                "payload manifest verified: {} files from commit {}",
                manifest.files.len(),
                manifest.source_commit
            ),
        );
    }
}

pub fn load_provision(path: &Path) -> Result<Provision, String> {
    let metadata = fs::metadata(path)
        .map_err(|error_value| format!("--provision cannot be read: {error_value}"))?;
    if !metadata.is_file() {
        return Err("--provision is not a regular file".into());
    }
    if metadata.len() > MAX_PROVISION_BYTES {
        return Err("--provision exceeds 4096 bytes".into());
    }
    let bytes = fs::read(path)
        .map_err(|error_value| format!("--provision cannot be read: {error_value}"))?;
    if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        return Err("--provision must be UTF-8 without BOM".into());
    }
    let document: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|error_value| format!("--provision is invalid JSON: {error_value}"))?;
    if contains_secret_key(&document) {
        return Err("--provision must not contain passwords, API keys, tokens, or secrets".into());
    }
    let provision: Provision = serde_json::from_value(document).map_err(|error_value| {
        format!("--provision violates the strict identity schema: {error_value}")
    })?;
    if provision.schema_version != "1.0" {
        return Err("--provision _schema_version must be 1.0".into());
    }
    for (field, value, maximum) in [
        ("serial_number", provision.serial_number.as_str(), 64_usize),
        ("model", provision.model.as_str(), 64),
        ("model_version", provision.model_version.as_str(), 32),
        ("batch", provision.batch.as_str(), 64),
    ] {
        if value.is_empty() || value.len() > maximum {
            return Err(format!(
                "--provision field {field} must contain 1 to {maximum} characters"
            ));
        }
        if !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || " ._+:/-".contains(character))
        {
            return Err(format!(
                "--provision field {field} contains unsupported characters"
            ));
        }
    }
    if provision.serial_number.contains(' ')
        || !provision
            .serial_number
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.".contains(character))
    {
        return Err("--provision serial_number contains unsupported characters".into());
    }
    Ok(provision)
}

fn validate_provision(path: Option<&Path>, items: &mut Vec<ValidationItem>) {
    let Some(path) = path else {
        error(items, "--provision is required for manufacturing identity");
        return;
    };
    match load_provision(path) {
        Ok(provision) => info(
            items,
            format!(
                "--provision contract verified: {} (serial_number={}, model={}, model_version={}, batch={}, capabilities.i2s_dac={})",
                path.display(),
                provision.serial_number,
                provision.model,
                provision.model_version,
                provision.batch,
                provision.capabilities.i2s_dac,
            ),
        ),
        Err(message) => error(items, message),
    }
}

fn validate_target(base_image: &Path, target: Option<&Path>, items: &mut Vec<ValidationItem>) {
    let Some(target) = target else {
        warning(
            items,
            "--target-device not provided; target identity is not validated",
        );
        return;
    };
    if target == base_image {
        error(items, "--target-device must not be the base-image input");
        return;
    }
    match fs::symlink_metadata(target) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            error(items, "--target-device symlinks are rejected");
        }
        Ok(metadata) if metadata.is_file() => {
            info(
                items,
                format!(
                    "--target-device is a regular-file fixture: {}",
                    target.display()
                ),
            );
        }
        #[cfg(unix)]
        Ok(metadata)
            if {
                use std::os::unix::fs::FileTypeExt;
                metadata.file_type().is_block_device()
            } =>
        {
            info(
                items,
                format!(
                    "--target-device is a block device reference: {} (dry-run: no write)",
                    target.display()
                ),
            );
        }
        Ok(_) => error(
            items,
            "--target-device must be a regular file fixture or block device",
        ),
        Err(error_value) => warning(
            items,
            format!(
                "--target-device does not exist in dry-run: {} ({error_value})",
                target.display()
            ),
        ),
    }
}

fn sha256_file(path: &Path) -> io::Result<String> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        digest.update(&buffer[..bytes_read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn collect_payload_files(
    root: &Path,
    directory: &Path,
    files: &mut BTreeSet<String>,
) -> io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(io::Error::other)?
            .to_str()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "non-UTF-8 payload path"))?
            .to_string();
        if metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("payload symlink is not allowed: {relative}"),
            ));
        }
        if metadata.is_dir() {
            collect_payload_files(root, &entry.path(), files)?;
        } else if metadata.is_file() && relative != PAYLOAD_MANIFEST {
            files.insert(relative);
        }
    }
    Ok(())
}

fn safe_payload_path(value: &str) -> bool {
    if value.is_empty() || value.contains('\\') || value.ends_with('~') {
        return false;
    }
    let path = Path::new(value);
    if path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return false;
    }
    !path.components().any(|component| {
        let Component::Normal(name) = component else {
            return true;
        };
        matches!(
            name.to_str(),
            Some(
                ".git"
                    | ".pytest_cache"
                    | "__pycache__"
                    | "tests"
                    | "docs"
                    | "target"
                    | "artifacts"
            )
        ) || name.to_string_lossy().ends_with(".pyc")
    })
}

fn contains_secret_key(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Object(object) => object.iter().any(|(key, child)| {
            let normalized = key.to_ascii_lowercase();
            matches!(
                normalized.as_str(),
                "api_key" | "apikey" | "password" | "passwd" | "secret" | "token" | "authorization"
            ) || contains_secret_key(child)
        }),
        serde_json::Value::Array(values) => values.iter().any(contains_secret_key),
        _ => false,
    }
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn is_git_commit(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn parse_mode(value: &str) -> Option<u32> {
    if value.len() != 4 || !value.starts_with('0') {
        return None;
    }
    u32::from_str_radix(value, 8)
        .ok()
        .filter(|mode| *mode <= 0o777)
}

fn error(items: &mut Vec<ValidationItem>, message: impl Into<String>) {
    items.push(ValidationItem {
        severity: Severity::Error,
        message: message.into(),
    });
}

fn warning(items: &mut Vec<ValidationItem>, message: impl Into<String>) {
    items.push(ValidationItem {
        severity: Severity::Warning,
        message: message.into(),
    });
}

fn info(items: &mut Vec<ValidationItem>, message: impl Into<String>) {
    items.push(ValidationItem {
        severity: Severity::Info,
        message: message.into(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::OnceLock;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture_signing_home() -> &'static PathBuf {
        static HOME: OnceLock<PathBuf> = OnceLock::new();
        HOME.get_or_init(|| {
            let home = std::env::temp_dir()
                .join(format!("sigil-flasher-test-signing-{}", std::process::id()));
            let _ = fs::remove_dir_all(&home);
            fs::create_dir_all(&home).expect("fixture signing home");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&home, fs::Permissions::from_mode(0o700))
                    .expect("fixture signing home mode");
            }
            let generated = std::process::Command::new("gpg")
                .args([
                    "--homedir",
                    home.to_str().expect("signing home"),
                    "--batch",
                    "--pinentry-mode",
                    "loopback",
                    "--passphrase",
                    "",
                    "--quick-generate-key",
                    "SIGIL Fixture <fixture@invalid>",
                    "ed25519",
                    "sign",
                    "0",
                ])
                .status()
                .expect("generate signing key");
            assert!(generated.success(), "fixture signing key generation failed");
            home
        })
    }

    fn create_offline_repository(root: &Path, contract_path: &Path) -> PathBuf {
        let repository = root.join("offline-packages");
        let packages_dir = repository.join("packages");
        let snapshot = repository.join("sources-snapshot");
        let keyrings = snapshot.join("keyrings");
        fs::create_dir_all(&packages_dir).expect("offline packages directory");
        fs::create_dir_all(&keyrings).expect("offline keyring directory");
        let contract_bytes = fs::read(contract_path).expect("contract bytes");
        let contract: crate::offline::PackageContract =
            serde_json::from_slice(&contract_bytes).expect("contract JSON");
        let mut package_entries = Vec::new();
        let mut index = String::new();
        let mut size_bytes = 0_u64;

        for requirement in contract.packages.iter().filter(|item| item.required) {
            let package_root = root.join(format!("deb-{}", requirement.name));
            fs::create_dir_all(package_root.join("DEBIAN")).expect("Debian control directory");
            fs::write(
                package_root.join("DEBIAN/control"),
                format!(
                    "Package: {}\nVersion: 1.0\nArchitecture: arm64\nMaintainer: SIGIL Tests <test@invalid>\nDescription: synthetic offline fixture\n",
                    requirement.name
                ),
            )
            .expect("Debian control");
            let filename = format!("packages/{}_1.0_arm64.deb", requirement.name);
            let destination = repository.join(&filename);
            let status = std::process::Command::new("dpkg-deb")
                .args(["--build", "--root-owner-group"])
                .arg(&package_root)
                .arg(&destination)
                .status()
                .expect("dpkg-deb fixture");
            assert!(status.success(), "dpkg-deb fixture failed");
            let size = fs::metadata(&destination).expect("deb metadata").len();
            let sha256 = sha256_file(&destination).expect("deb hash");
            size_bytes += size;
            index.push_str(&format!(
                "Package: {}\nVersion: 1.0\nArchitecture: arm64\nFilename: {}\nSize: {}\nSHA256: {}\nDescription: synthetic offline fixture\n\n",
                requirement.name, filename, size, sha256
            ));
            package_entries.push(json!({
                "name": requirement.name,
                "version": "1.0",
                "architecture": "arm64",
                "filename": filename,
                "sha256": sha256,
                "size": size,
            }));
            fs::remove_dir_all(package_root).expect("remove package fixture root");
        }

        fs::write(repository.join("Packages"), index).expect("Packages index");
        let compressed = std::process::Command::new("gzip")
            .args(["-n", "-9", "-c"])
            .arg(repository.join("Packages"))
            .output()
            .expect("gzip Packages");
        assert!(compressed.status.success(), "gzip fixture failed");
        fs::write(repository.join("Packages.gz"), compressed.stdout).expect("Packages.gz");

        let required: Vec<_> = contract
            .packages
            .iter()
            .filter(|requirement| requirement.required)
            .map(|requirement| requirement.name.clone())
            .collect();

        let debian_source = "Types: deb\nURIs: http://deb.debian.org/debian/\nSuites: trixie trixie-updates\nComponents: main contrib non-free non-free-firmware\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n";
        let raspi_source = "Types: deb\nURIs: http://archive.raspberrypi.com/debian/\nSuites: trixie\nComponents: main\nSigned-By: /usr/share/keyrings/raspberrypi-archive-keyring.pgp\n";
        fs::write(snapshot.join("debian.sources"), debian_source).expect("Debian source");
        fs::write(snapshot.join("raspi.sources"), raspi_source).expect("Pi source");
        fs::write(
            snapshot.join("os-release"),
            "ID=debian\nVERSION_ID=13\nVERSION_CODENAME=trixie\n",
        )
        .expect("os-release");
        fs::write(
            keyrings.join("debian-archive-keyring.pgp"),
            b"debian-test-keyring",
        )
        .expect("Debian keyring");
        fs::write(
            keyrings.join("raspberrypi-archive-keyring.pgp"),
            b"raspberry-pi-test-keyring",
        )
        .expect("Pi keyring");

        let sources = vec![
            json!({
                "file": "debian.sources",
                "sha256": sha256_file(&snapshot.join("debian.sources")).expect("source hash"),
                "uris": ["http://deb.debian.org/debian/"],
                "effective_uris": ["http://deb.debian.org/debian/"],
                "suites": ["trixie", "trixie-updates"],
                "signed_by": "/usr/share/keyrings/debian-archive-keyring.pgp",
                "scope": "Debian 13 Trixie and security archives"
            }),
            json!({
                "file": "raspi.sources",
                "sha256": sha256_file(&snapshot.join("raspi.sources")).expect("source hash"),
                "uris": ["http://archive.raspberrypi.com/debian/"],
                "effective_uris": ["https://ftp.uni-hannover.de/raspberrypi/"],
                "suites": ["trixie"],
                "signed_by": "/usr/share/keyrings/raspberrypi-archive-keyring.pgp",
                "scope": "Raspberry Pi Trixie archive"
            }),
        ];
        fs::write(
            snapshot.join("sources-metadata.json"),
            serde_json::to_vec_pretty(&json!({"sources": sources.clone()}))
                .expect("source metadata"),
        )
        .expect("source metadata");
        fs::write(
            snapshot.join("base-image-metadata.json"),
            serde_json::to_vec_pretty(&json!({
                "filename": contract.base_image_name,
                "sha256": contract.base_image_sha256,
                "distribution": contract.distribution,
                "distribution_version": contract.distribution_version,
                "distribution_codename": contract.distribution_codename,
                "architecture": contract.architecture,
            }))
            .expect("base image metadata"),
        )
        .expect("base image metadata");

        let signing_home = fixture_signing_home();
        let listing = std::process::Command::new("gpg")
            .args([
                "--homedir",
                signing_home.to_str().expect("signing home"),
                "--batch",
                "--with-colons",
                "--list-secret-keys",
            ])
            .output()
            .expect("list signing key");
        let listing = String::from_utf8(listing.stdout).expect("signing key listing");
        let fingerprint = listing
            .lines()
            .find_map(|line| {
                line.strip_prefix("fpr:::::::::")
                    .and_then(|rest| rest.split(':').next())
            })
            .expect("signing fingerprint");
        let repository_key = keyrings.join("sigil-offline-repository.gpg");
        let exported = std::process::Command::new("gpg")
            .args([
                "--homedir",
                signing_home.to_str().expect("signing home"),
                "--batch",
                "--output",
                repository_key.to_str().expect("repository key"),
                "--export",
                fingerprint,
            ])
            .status()
            .expect("export signing key");
        assert!(exported.success(), "fixture signing key export failed");

        let keyring_metadata = vec![
            json!({
                "package": "debian-archive-keyring",
                "package_version": "2025.1",
                "source_image": contract.base_image_name,
                "source_path": "/usr/share/keyrings/debian-archive-keyring.pgp",
                "artifact_path": "keyrings/debian-archive-keyring.pgp",
                "sha256": sha256_file(&keyrings.join("debian-archive-keyring.pgp")).expect("keyring hash"),
                "fingerprints": ["1111111111111111111111111111111111111111"],
                "scope": "Debian archives"
            }),
            json!({
                "package": "raspberrypi-archive-keyring",
                "package_version": "2025.1+rpt1",
                "source_image": contract.base_image_name,
                "source_path": "/usr/share/keyrings/raspberrypi-archive-keyring.pgp",
                "artifact_path": "keyrings/raspberrypi-archive-keyring.pgp",
                "sha256": sha256_file(&keyrings.join("raspberrypi-archive-keyring.pgp")).expect("keyring hash"),
                "fingerprints": ["2222222222222222222222222222222222222222"],
                "scope": "Raspberry Pi archive"
            }),
            json!({
                "package": null,
                "package_version": null,
                "source_image": null,
                "source_path": "generated fixture signing key",
                "artifact_path": "keyrings/sigil-offline-repository.gpg",
                "sha256": sha256_file(&repository_key).expect("keyring hash"),
                "fingerprints": [fingerprint],
                "scope": "SIGIL file:// offline repository"
            }),
        ];
        fs::write(
            snapshot.join("keyring-metadata.json"),
            serde_json::to_vec_pretty(&json!({"keyrings": keyring_metadata.clone()}))
                .expect("keyring metadata"),
        )
        .expect("keyring metadata");

        fs::write(
            repository.join("Release"),
            b"Date: Tue, 15 Jul 2026 00:00:00 UTC\n",
        )
        .expect("Release");
        for (output, arguments) in [
            ("InRelease", vec!["--clearsign"]),
            ("Release.gpg", vec!["--detach-sign"]),
        ] {
            let status = std::process::Command::new("gpg")
                .args([
                    "--homedir",
                    signing_home.to_str().expect("signing home"),
                    "--batch",
                    "--yes",
                    "--local-user",
                    fingerprint,
                ])
                .args(arguments)
                .args([
                    "--output",
                    repository.join(output).to_str().expect("signature output"),
                    repository.join("Release").to_str().expect("Release"),
                ])
                .status()
                .expect("sign fixture repository");
            assert!(status.success(), "fixture repository signing failed");
        }

        let manifest = json!({
            "schema_version": "2.0",
            "repository_type": "sigil-offline-apt",
            "package_contract_schema_version": contract.schema_version,
            "bundle_version": contract.bundle_version,
            "package_contract_sha256": sha256_file(contract_path).expect("contract hash"),
            "source_sigil_hardware_commit": null,
            "base_image_name": contract.base_image_name,
            "base_image_sha256": contract.base_image_sha256,
            "distribution": contract.distribution,
            "distribution_version": contract.distribution_version,
            "distribution_codename": contract.distribution_codename,
            "architecture": contract.architecture,
            "generation_timestamp": "2026-07-15T00:00:00Z",
            "direct_packages": required,
            "direct_package_count": package_entries.len(),
            "resolved_package_count": package_entries.len(),
            "total_bytes": size_bytes,
            "unresolved_packages": [],
            "sources": sources,
            "keyrings": keyring_metadata,
            "python_dependencies": {
                "fully_satisfied_by_debian_packages": {
                    "flask": "python3-flask",
                    "argon2": "python3-argon2",
                    "bluetooth": "python3-bluez"
                },
                "wheels": []
            },
            "packages": package_entries,
        });
        fs::write(
            repository.join("package-manifest.json"),
            serde_json::to_vec_pretty(&manifest).expect("offline manifest JSON"),
        )
        .expect("offline manifest");

        let mut checksums = String::new();
        for package in manifest["packages"].as_array().expect("packages") {
            let filename = package["filename"].as_str().expect("filename");
            checksums.push_str(&format!(
                "{}  {}\n",
                sha256_file(&repository.join(filename)).expect("package checksum"),
                filename
            ));
        }
        for relative in [
            "Packages",
            "Packages.gz",
            "Release",
            "Release.gpg",
            "InRelease",
            "package-manifest.json",
            "sources-snapshot/debian.sources",
            "sources-snapshot/raspi.sources",
            "sources-snapshot/os-release",
            "sources-snapshot/base-image-metadata.json",
            "sources-snapshot/sources-metadata.json",
            "sources-snapshot/keyring-metadata.json",
            "sources-snapshot/keyrings/debian-archive-keyring.pgp",
            "sources-snapshot/keyrings/raspberrypi-archive-keyring.pgp",
            "sources-snapshot/keyrings/sigil-offline-repository.gpg",
        ] {
            checksums.push_str(&format!(
                "{}  {}\n",
                sha256_file(&repository.join(relative)).expect("metadata checksum"),
                relative
            ));
        }
        fs::write(repository.join("checksums.sha256"), checksums).expect("checksums");
        repository
    }

    struct Fixture {
        root: std::path::PathBuf,
        image: std::path::PathBuf,
        payload: std::path::PathBuf,
        offline: std::path::PathBuf,
        provision: std::path::PathBuf,
        secrets: std::path::PathBuf,
        target: std::path::PathBuf,
        image_sha256: String,
    }

    impl Fixture {
        fn new() -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos();
            let root =
                std::env::temp_dir().join(format!("sigil-flasher-{unique}-{}", std::process::id()));
            let image = root.join("fixture.img.xz");
            fs::create_dir_all(&root).expect("fixture root");
            fs::write(&image, b"controlled compressed-image fixture").expect("image");
            let image_sha256 = sha256_file(&image).expect("image hash");
            let mut contract: serde_json::Value = serde_json::from_str(include_str!(
                "../../manifests/offline-package-contract.json"
            ))
            .expect("canonical contract");
            contract["base_image_name"] = json!("fixture.img.xz");
            contract["base_image_sha256"] = json!(image_sha256.clone());
            let contract_bytes = serde_json::to_vec_pretty(&contract).expect("fixture contract");

            let payload = root.join("payload");
            fs::create_dir_all(&payload).expect("payload directory");
            let files: Vec<(&str, Vec<u8>, u32)> = vec![
                ("install.sh", b"#!/bin/bash\n".to_vec(), 0o755),
                ("panel/app.py", b"print('sigil')\n".to_vec(), 0o644),
                ("scripts/firstboot.sh", b"#!/bin/bash\n".to_vec(), 0o755),
                (
                    "services/sigil-firstboot.service",
                    b"[Service]\n".to_vec(),
                    0o644,
                ),
                (
                    "conf/audio.conf",
                    b"API_KEY=\"<placeholder>\"\n".to_vec(),
                    0o644,
                ),
                (
                    "manifests/offline-package-contract.json",
                    contract_bytes,
                    0o644,
                ),
            ];
            let mut manifest_files = Vec::new();
            for (path, content, mode) in files {
                let destination = payload.join(path);
                fs::create_dir_all(destination.parent().expect("parent"))
                    .expect("parent directory");
                fs::write(&destination, content).expect("fixture file");
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&destination, fs::Permissions::from_mode(mode))
                        .expect("mode");
                }
                manifest_files.push(json!({
                    "path": path,
                    "sha256": sha256_file(&destination).expect("hash"),
                    "mode": format!("{mode:04o}")
                }));
            }
            let manifest = json!({
                "_schema_version": "1.0",
                "payload_type": "sigil-hardware-install",
                "source_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "target": {
                    "os": "raspberry-pi-os-lite",
                    "release": "trixie",
                    "architecture": "arm64",
                    "hardware": "raspberry-pi-zero-2-w"
                },
                "files": manifest_files
            });
            fs::write(
                payload.join(PAYLOAD_MANIFEST),
                serde_json::to_vec_pretty(&manifest).expect("manifest JSON"),
            )
            .expect("manifest");
            let offline = create_offline_repository(
                &root,
                &payload.join("manifests/offline-package-contract.json"),
            );

            let provision = root.join("provision.json");
            fs::write(
                &provision,
                br#"{"_schema_version":"1.0","serial_number":"SIGIL-TEST-0001","model":"Sigil-Streamer","model_version":"v1","batch":"TEST","capabilities":{"i2s_dac":false}}"#,
            )
            .expect("provision");
            let secrets = root.join("sigil_secrets.json");
            fs::write(
                &secrets,
                br#"{"_schema_version":"1.0","panel_pin":"80427159"}"#,
            )
            .expect("secrets");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&secrets, fs::Permissions::from_mode(0o600))
                    .expect("secret mode");
            }
            let target = root.join("target.img");
            fs::write(&target, []).expect("target");

            Self {
                root,
                image,
                payload,
                offline,
                provision,
                secrets,
                target,
                image_sha256,
            }
        }

        fn validate(&self) -> ValidationResult {
            validate_inputs(
                &self.image,
                Some(&self.image_sha256),
                &self.payload,
                &Some(self.offline.clone()),
                &Some(self.target.clone()),
                &Some(self.provision.clone()),
                &Some(self.secrets.clone()),
            )
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn valid_contract_passes_with_img_xz_and_regular_target() {
        let fixture = Fixture::new();
        let result = fixture.validate();
        assert!(
            result.valid,
            "{:?}",
            result
                .items
                .iter()
                .map(|item| &item.message)
                .collect::<Vec<_>>()
        );
    }

    fn refresh_manifest_checksum(repository: &Path) {
        let checksums_path = repository.join("checksums.sha256");
        let replacement = format!(
            "{}  package-manifest.json",
            sha256_file(&repository.join("package-manifest.json")).expect("manifest checksum")
        );
        let checksums = fs::read_to_string(&checksums_path)
            .expect("checksums")
            .lines()
            .map(|line| {
                if line.ends_with("  package-manifest.json") {
                    replacement.clone()
                } else {
                    line.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(checksums_path, format!("{checksums}\n")).expect("updated checksums");
    }

    #[test]
    fn offline_repository_rejects_invalid_manifest() {
        let fixture = Fixture::new();
        fs::write(fixture.offline.join("package-manifest.json"), b"not-json")
            .expect("corrupt manifest");
        let error = crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .expect_err("invalid manifest must fail");
        assert!(error.contains("manifest"));
    }

    #[test]
    fn offline_repository_rejects_checksum_corruption() {
        let fixture = Fixture::new();
        let package = fs::read_dir(fixture.offline.join("packages"))
            .expect("packages")
            .next()
            .expect("package")
            .expect("package entry")
            .path();
        let mut bytes = fs::read(&package).expect("package bytes");
        bytes.push(0);
        fs::write(package, bytes).expect("corrupt package");
        let error = crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .expect_err("checksum corruption must fail");
        assert!(error.contains("checksum mismatch"));
    }

    #[test]
    fn offline_repository_rejects_wrong_package_architecture() {
        let fixture = Fixture::new();
        let manifest_path = fixture.offline.join("package-manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).expect("manifest"))
                .expect("manifest JSON");
        manifest["packages"][0]["architecture"] = json!("amd64");
        fs::write(
            manifest_path,
            serde_json::to_vec_pretty(&manifest).expect("manifest JSON"),
        )
        .expect("wrong architecture manifest");
        refresh_manifest_checksum(&fixture.offline);
        let error = crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .expect_err("wrong architecture must fail");
        assert!(error.contains("wrong package architecture"));
    }

    #[test]
    fn offline_repository_rejects_wrong_bundle_version() {
        let fixture = Fixture::new();
        let manifest_path = fixture.offline.join("package-manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).expect("manifest"))
                .expect("manifest JSON");
        manifest["bundle_version"] = json!("2099.01.01.1");
        fs::write(
            &manifest_path,
            serde_json::to_vec_pretty(&manifest).expect("manifest JSON"),
        )
        .expect("wrong version manifest");
        refresh_manifest_checksum(&fixture.offline);

        let error = crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .expect_err("wrong bundle version must fail");
        assert!(error.contains("bundle version"));
    }

    #[test]
    fn offline_repository_rejects_wrong_base_image_contract() {
        let fixture = Fixture::new();
        let manifest_path = fixture.offline.join("package-manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).expect("manifest"))
                .expect("manifest JSON");
        manifest["base_image_name"] = json!("different.img.xz");
        fs::write(
            &manifest_path,
            serde_json::to_vec_pretty(&manifest).expect("manifest JSON"),
        )
        .expect("wrong base image manifest");
        refresh_manifest_checksum(&fixture.offline);

        let error = crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .expect_err("wrong base image must fail");
        assert!(error.contains("base image"));
    }

    #[test]
    fn offline_repository_rejects_missing_package_file() {
        let fixture = Fixture::new();
        let package = fs::read_dir(fixture.offline.join("packages"))
            .expect("packages")
            .next()
            .expect("package")
            .expect("package entry")
            .path();
        fs::remove_file(package).expect("remove package");
        assert!(crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .is_err());
    }

    #[test]
    fn offline_repository_rejects_packages_gzip_mismatch() {
        let fixture = Fixture::new();
        fs::write(fixture.offline.join("Packages.gz"), b"not-gzip").expect("corrupt Packages.gz");
        let error = crate::offline::validate_repository(
            &fixture.offline,
            &fixture
                .payload
                .join("manifests/offline-package-contract.json"),
        )
        .expect_err("invalid Packages.gz must fail");
        assert!(error.contains("Packages.gz"));
    }

    #[test]
    fn base_image_checksum_mismatch_fails() {
        let fixture = Fixture::new();
        let result = validate_inputs(
            &fixture.image,
            Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            &fixture.payload,
            &Some(fixture.offline.clone()),
            &Some(fixture.target.clone()),
            &Some(fixture.provision.clone()),
            &Some(fixture.secrets.clone()),
        );
        assert!(!result.valid);
    }

    #[test]
    fn undeclared_payload_file_fails() {
        let fixture = Fixture::new();
        fs::write(fixture.payload.join("local-backup"), b"not declared").expect("extra");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn modified_payload_file_fails_hash_validation() {
        let fixture = Fixture::new();
        fs::write(fixture.payload.join("panel/app.py"), b"modified").expect("modify");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_requires_identity_fields() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","model":"Zero 2 W"}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_secret_fields() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":false},"api_key":"do-not-store"}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_panel_pin_field() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":false},"panel_pin":"80427159"}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_accepts_boolean_i2s_capability() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":true}}"#,
        )
        .expect("provision");
        assert!(fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_non_boolean_i2s_capability() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":"auto"}}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_missing_model_version() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","batch":"B","capabilities":{"i2s_dac":false}}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_empty_serial_number() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":false}}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_string_true_i2s_capability() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":"true"}}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn provision_rejects_unknown_identity_fields() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.provision,
            br#"{"_schema_version":"1.0","serial_number":"S1","model":"M","model_version":"v1","batch":"B","capabilities":{"i2s_dac":false},"device_id":"not-manufacturing-input"}"#,
        )
        .expect("provision");
        assert!(!fixture.validate().valid);
    }

    #[test]
    fn image_and_target_must_differ() {
        let fixture = Fixture::new();
        let result = validate_inputs(
            &fixture.image,
            Some(&fixture.image_sha256),
            &fixture.payload,
            &Some(fixture.offline.clone()),
            &Some(fixture.image.clone()),
            &Some(fixture.provision.clone()),
            &Some(fixture.secrets.clone()),
        );
        assert!(!result.valid);
    }

    #[test]
    fn secrets_reject_unknown_fields_and_trivial_pins_without_disclosure() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.secrets,
            br#"{"_schema_version":"1.0","panel_pin":"123456","api_key":"synthetic"}"#,
        )
        .expect("secrets");
        let result = fixture.validate();
        assert!(!result.valid);
        let report = result
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!report.contains("123456"));
        assert!(!report.contains("synthetic"));
    }

    #[test]
    fn secrets_reject_malformed_pin_and_insecure_mode() {
        let fixture = Fixture::new();
        fs::write(
            &fixture.secrets,
            br#"{"_schema_version":"1.0","panel_pin":"80 27159"}"#,
        )
        .expect("secrets");
        assert!(!fixture.validate().valid);

        fs::write(
            &fixture.secrets,
            br#"{"_schema_version":"1.0","panel_pin":"80427159"}"#,
        )
        .expect("secrets");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&fixture.secrets, fs::Permissions::from_mode(0o644)).expect("mode");
            assert!(!fixture.validate().valid);
        }
    }

    #[cfg(unix)]
    #[test]
    fn secrets_reject_symlink() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let target = fixture.root.join("secret-target.json");
        fs::rename(&fixture.secrets, &target).expect("move");
        symlink(&target, &fixture.secrets).expect("link");
        assert!(!fixture.validate().valid);
    }
}
