use crate::model::{Provision, Severity, ValidationItem, ValidationResult};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, BufReader, Read};
use std::path::{Component, Path};

pub const OFFICIAL_IMAGE_FILENAME: &str = "2026-06-18-raspios-trixie-arm64-lite.img.xz";
pub const OFFICIAL_IMAGE_SHA256: &str =
    "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3";

const PAYLOAD_MANIFEST: &str = "payload-manifest.json";
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_PROVISION_BYTES: u64 = 4096;

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
    target_device: &Option<std::path::PathBuf>,
    provision: &Option<std::path::PathBuf>,
) -> ValidationResult {
    let mut items = Vec::new();

    validate_base_image(base_image, expected_base_sha256, &mut items);
    validate_payload(payload, &mut items);
    validate_provision(provision.as_deref(), &mut items);
    validate_target(base_image, target_device.as_deref(), &mut items);

    let valid = items
        .iter()
        .all(|item| !matches!(item.severity, Severity::Error));
    ValidationResult { valid, items }
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
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Fixture {
        root: std::path::PathBuf,
        image: std::path::PathBuf,
        payload: std::path::PathBuf,
        provision: std::path::PathBuf,
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
            let payload = root.join("payload");
            fs::create_dir_all(&payload).expect("payload directory");
            let files = [
                ("install.sh", "#!/bin/bash\n", 0o755),
                ("panel/app.py", "print('sigil')\n", 0o644),
                ("scripts/firstboot.sh", "#!/bin/bash\n", 0o755),
                ("services/sigil-firstboot.service", "[Service]\n", 0o644),
                ("conf/audio.conf", "API_KEY=\"<placeholder>\"\n", 0o644),
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

            let image = root.join("fixture.img.xz");
            fs::write(&image, b"controlled compressed-image fixture").expect("image");
            let image_sha256 = sha256_file(&image).expect("image hash");
            let provision = root.join("provision.json");
            fs::write(
                &provision,
                br#"{"_schema_version":"1.0","serial_number":"SIGIL-TEST-0001","model":"Sigil-Streamer","model_version":"v1","batch":"TEST","capabilities":{"i2s_dac":false}}"#,
            )
            .expect("provision");
            let target = root.join("target.img");
            fs::write(&target, []).expect("target");

            Self {
                root,
                image,
                payload,
                provision,
                target,
                image_sha256,
            }
        }

        fn validate(&self) -> ValidationResult {
            validate_inputs(
                &self.image,
                Some(&self.image_sha256),
                &self.payload,
                &Some(self.target.clone()),
                &Some(self.provision.clone()),
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

    #[test]
    fn base_image_checksum_mismatch_fails() {
        let fixture = Fixture::new();
        let result = validate_inputs(
            &fixture.image,
            Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            &fixture.payload,
            &Some(fixture.target.clone()),
            &Some(fixture.provision.clone()),
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
            &Some(fixture.image.clone()),
            &Some(fixture.provision.clone()),
        );
        assert!(!result.valid);
    }
}
