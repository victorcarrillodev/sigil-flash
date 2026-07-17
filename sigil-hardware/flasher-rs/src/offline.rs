//! Validation for manufacturing-owned offline APT repositories.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{BufReader, Read};
use std::path::{Component, Path};
use std::process::Command;

const CONTRACT_FILE: &str = "manifests/offline-package-contract.json";
const MANIFEST_FILE: &str = "package-manifest.json";
const CHECKSUM_FILE: &str = "checksums.sha256";
const PACKAGES_FILE: &str = "Packages";
const PACKAGES_GZ_FILE: &str = "Packages.gz";
const RELEASE_FILE: &str = "Release";
const RELEASE_GPG_FILE: &str = "Release.gpg";
const INRELEASE_FILE: &str = "InRelease";
const SNAPSHOT_DIRECTORY: &str = "sources-snapshot";
const REPOSITORY_KEY: &str = "sources-snapshot/keyrings/sigil-offline-repository.gpg";
const MAX_METADATA_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageRequirement {
    pub name: String,
    pub required: bool,
    pub version: Option<String>,
    pub profile: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageContract {
    pub schema_version: String,
    pub bundle_version: String,
    pub distribution: String,
    pub distribution_version: String,
    pub distribution_codename: String,
    pub architecture: String,
    pub allowed_package_architectures: Vec<String>,
    pub base_image_name: String,
    pub base_image_sha256: String,
    pub install_recommends: bool,
    pub version_policy: String,
    pub packages: Vec<PackageRequirement>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct PackageManifest {
    schema_version: String,
    repository_type: String,
    package_contract_schema_version: String,
    bundle_version: String,
    package_contract_sha256: String,
    source_sigil_hardware_commit: Option<String>,
    base_image_name: String,
    base_image_sha256: String,
    distribution: String,
    distribution_version: String,
    distribution_codename: String,
    architecture: String,
    generation_timestamp: String,
    direct_packages: Vec<String>,
    direct_package_count: usize,
    resolved_package_count: usize,
    total_bytes: u64,
    unresolved_packages: Vec<String>,
    sources: Vec<SourceMetadata>,
    keyrings: Vec<KeyringMetadata>,
    python_dependencies: PythonDependencies,
    packages: Vec<ManifestPackage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceMetadata {
    file: String,
    sha256: String,
    uris: Vec<String>,
    effective_uris: Vec<String>,
    suites: Vec<String>,
    signed_by: String,
    scope: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyringMetadata {
    package: Option<String>,
    package_version: Option<String>,
    source_image: Option<String>,
    source_path: String,
    artifact_path: String,
    sha256: String,
    fingerprints: Vec<String>,
    scope: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct PythonDependencies {
    fully_satisfied_by_debian_packages: BTreeMap<String, String>,
    wheels: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourcesMetadataDocument {
    sources: Vec<SourceMetadata>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyringMetadataDocument {
    keyrings: Vec<KeyringMetadata>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestPackage {
    name: String,
    version: String,
    architecture: String,
    filename: String,
    sha256: String,
    size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OfflineRepositorySummary {
    pub path: String,
    pub bundle_version: String,
    pub package_contract_schema_version: String,
    pub direct_package_count: usize,
    pub resolved_package_count: usize,
    pub architecture: String,
    pub distribution: String,
    pub base_image_name: String,
    pub base_image_sha256: String,
    pub total_bytes: u64,
    pub keyring_status: String,
    pub sources_status: String,
    pub unresolved_packages: Vec<String>,
    pub manifest_status: String,
}

#[derive(Debug)]
struct IndexPackage {
    name: String,
    version: String,
    architecture: String,
    filename: String,
    sha256: String,
    size: u64,
}

/// Load and validate the canonical package contract from a generated payload.
pub fn load_contract(payload: &Path) -> Result<PackageContract, String> {
    let path = payload.join(CONTRACT_FILE);
    let bytes = read_metadata(&path)?;
    let contract: PackageContract = serde_json::from_slice(&bytes)
        .map_err(|error| format!("invalid canonical package contract: {error}"))?;
    validate_contract(&contract)?;
    Ok(contract)
}

/// Validate every metadata layer and package in an offline APT repository.
///
/// # Errors
///
/// Returns a descriptive error if the contract, repository manifest, indexes,
/// checksums, package metadata, architecture, or dependency closure is invalid.
pub fn validate_repository(
    repository: &Path,
    contract_path: &Path,
) -> Result<OfflineRepositorySummary, String> {
    if !repository.is_dir() {
        return Err(format!(
            "offline package repository is not a directory: {}",
            repository.display()
        ));
    }
    let contract_bytes = read_metadata(contract_path)?;
    let contract: PackageContract = serde_json::from_slice(&contract_bytes)
        .map_err(|error| format!("invalid canonical package contract: {error}"))?;
    validate_contract(&contract)?;

    let manifest_path = repository.join(MANIFEST_FILE);
    let manifest: PackageManifest = serde_json::from_slice(&read_metadata(&manifest_path)?)
        .map_err(|error| format!("invalid offline package manifest: {error}"))?;
    validate_manifest_contract(&manifest, &contract, &contract_bytes)?;
    validate_source_and_keyring_metadata(repository, &manifest)?;
    validate_repository_signature(repository)?;

    let packages_bytes = read_metadata(&repository.join(PACKAGES_FILE))?;
    let compressed_path = repository.join(PACKAGES_GZ_FILE);
    let _ = read_metadata(&compressed_path)?;
    let output = Command::new("gzip")
        .args(["-d", "-c"])
        .arg(&compressed_path)
        .output()
        .map_err(|error| format!("cannot execute gzip: {error}"))?;
    if !output.status.success() {
        return Err("invalid Packages.gz".into());
    }
    let decoded = output.stdout;
    if decoded != packages_bytes {
        return Err("Packages.gz does not expand to the canonical Packages index".into());
    }
    let packages_text = std::str::from_utf8(&packages_bytes)
        .map_err(|error| format!("Packages is not UTF-8: {error}"))?;
    let index = parse_packages_index(packages_text)?;

    let checksums = parse_checksums(&repository.join(CHECKSUM_FILE))?;
    let expected_checksum_paths = expected_checksum_paths(&manifest);
    if checksums.keys().cloned().collect::<BTreeSet<_>>() != expected_checksum_paths {
        return Err("checksums.sha256 does not cover exactly the repository artifacts".into());
    }
    for (relative, expected) in &checksums {
        let path = safe_repository_file(repository, relative)?;
        let actual = sha256_file(&path)?;
        if &actual != expected {
            return Err(format!("checksum mismatch for {relative}"));
        }
    }

    let mut filenames = BTreeSet::new();
    let mut package_names = BTreeSet::new();
    let mut total_size = 0_u64;
    for package in &manifest.packages {
        validate_manifest_package(package, &contract)?;
        if !filenames.insert(package.filename.clone()) {
            return Err(format!("duplicate package filename: {}", package.filename));
        }
        package_names.insert(package.name.clone());
        let path = safe_repository_file(repository, &package.filename)?;
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("cannot inspect {}: {error}", package.filename))?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(format!(
                "package is not a regular file: {}",
                package.filename
            ));
        }
        if metadata.len() != package.size {
            return Err(format!("package size mismatch: {}", package.filename));
        }
        total_size = total_size
            .checked_add(metadata.len())
            .ok_or_else(|| "offline repository size overflow".to_string())?;
        if sha256_file(&path)? != package.sha256 {
            return Err(format!(
                "package manifest checksum mismatch: {}",
                package.filename
            ));
        }
        validate_deb_metadata(&path, package)?;
        let indexed = index
            .get(&package.filename)
            .ok_or_else(|| format!("package missing from Packages index: {}", package.filename))?;
        if indexed.name != package.name
            || indexed.version != package.version
            || indexed.architecture != package.architecture
            || indexed.filename != package.filename
            || indexed.sha256 != package.sha256
            || indexed.size != package.size
        {
            return Err(format!("Packages index mismatch: {}", package.filename));
        }
    }

    if manifest.resolved_package_count != manifest.packages.len()
        || manifest.resolved_package_count != index.len()
    {
        return Err("resolved package count does not match manifest and Packages indexes".into());
    }
    if manifest.total_bytes != total_size {
        return Err("repository size does not match package manifest".into());
    }
    let included_names: BTreeSet<_> = contract
        .packages
        .iter()
        .filter(|package| package.required || package.profile == "factory-debug")
        .map(|package| package.name.clone())
        .collect();
    let missing: Vec<_> = included_names.difference(&package_names).cloned().collect();
    if !missing.is_empty() {
        return Err(format!(
            "offline repository is missing required bundle-profile packages: {}",
            missing.join(", ")
        ));
    }
    validate_no_unexpected_debs(repository, &filenames)?;

    Ok(OfflineRepositorySummary {
        path: repository.to_string_lossy().to_string(),
        bundle_version: manifest.bundle_version,
        package_contract_schema_version: manifest.package_contract_schema_version,
        direct_package_count: manifest.direct_package_count,
        resolved_package_count: manifest.resolved_package_count,
        architecture: manifest.architecture,
        distribution: format!(
            "{} {} ({})",
            manifest.distribution, manifest.distribution_version, manifest.distribution_codename
        ),
        base_image_name: manifest.base_image_name,
        base_image_sha256: manifest.base_image_sha256,
        total_bytes: manifest.total_bytes,
        keyring_status: "valid".into(),
        sources_status: "valid".into(),
        unresolved_packages: manifest.unresolved_packages,
        manifest_status: "valid".into(),
    })
}

fn validate_contract(contract: &PackageContract) -> Result<(), String> {
    if contract.schema_version != "2.0" {
        return Err("unsupported canonical package contract".into());
    }
    if !valid_bundle_version(&contract.bundle_version) {
        return Err("bundle version must use YYYY.MM.DD.N".into());
    }
    if contract.distribution != "debian"
        || contract.distribution_version != "13"
        || contract.distribution_codename != "trixie"
        || contract.architecture != "arm64"
    {
        return Err("package contract must target Debian 13 Trixie arm64".into());
    }
    let allowed: BTreeSet<_> = contract
        .allowed_package_architectures
        .iter()
        .cloned()
        .collect();
    if allowed != BTreeSet::from(["all".to_string(), "arm64".to_string()]) {
        return Err("allowed package architectures must be arm64 and all".into());
    }
    if !is_sha256(&contract.base_image_sha256)
        || contract.base_image_name.is_empty()
        || !contract.base_image_name.ends_with(".img.xz")
    {
        return Err("package contract has an invalid official base image".into());
    }
    if contract.packages.is_empty() {
        return Err("canonical required package list is empty".into());
    }
    let mut names = BTreeSet::new();
    let mut required_count = 0;
    for requirement in &contract.packages {
        if !valid_package_name(&requirement.name) || !names.insert(requirement.name.clone()) {
            return Err(format!(
                "invalid or duplicate package: {}",
                requirement.name
            ));
        }
        if !matches!(
            requirement.profile.as_str(),
            "runtime" | "factory-debug" | "optional"
        ) {
            return Err(format!("invalid package profile: {}", requirement.name));
        }
        if requirement.version.as_deref().is_some_and(str::is_empty) {
            return Err(format!("empty version constraint: {}", requirement.name));
        }
        required_count += usize::from(requirement.required);
    }
    if required_count != 23 {
        return Err(format!(
            "canonical contract must contain 23 required packages, found {required_count}"
        ));
    }
    if !contract.packages.iter().any(|package| {
        package.name == "openssh-server" && !package.required && package.profile == "factory-debug"
    }) {
        return Err("openssh-server factory-debug profile is missing".into());
    }
    if contract.version_policy != "distribution-candidate" || contract.install_recommends {
        return Err("unsupported package version or recommends policy".into());
    }
    Ok(())
}

fn validate_manifest_contract(
    manifest: &PackageManifest,
    contract: &PackageContract,
    contract_bytes: &[u8],
) -> Result<(), String> {
    if manifest.schema_version != "2.0" || manifest.repository_type != "sigil-offline-apt" {
        return Err("unsupported offline package manifest".into());
    }
    if manifest.package_contract_schema_version != contract.schema_version {
        return Err("bundle package-contract schema version is incompatible".into());
    }
    if manifest.bundle_version != contract.bundle_version {
        return Err("bundle version is incompatible with package contract".into());
    }
    if manifest.distribution != contract.distribution
        || manifest.distribution_version != contract.distribution_version
        || manifest.distribution_codename != contract.distribution_codename
        || manifest.architecture != contract.architecture
    {
        return Err(
            "offline repository distribution or architecture does not match contract".into(),
        );
    }
    if manifest.base_image_name != contract.base_image_name
        || manifest.base_image_sha256 != contract.base_image_sha256
    {
        return Err("offline repository targets a different base image".into());
    }
    if manifest.package_contract_sha256 != sha256_bytes(contract_bytes) {
        return Err("offline repository was built from a different package contract".into());
    }
    let required: Vec<_> = contract
        .packages
        .iter()
        .filter(|package| package.required)
        .map(|package| package.name.clone())
        .collect();
    if manifest.direct_packages != required || manifest.direct_package_count != required.len() {
        return Err("offline repository required package set does not match contract".into());
    }
    if !manifest.unresolved_packages.is_empty() {
        return Err(format!(
            "offline repository contains unresolved packages: {}",
            manifest.unresolved_packages.join(", ")
        ));
    }
    if manifest.resolved_package_count < manifest.direct_package_count {
        return Err("resolved package count is smaller than direct package count".into());
    }
    if !valid_generation_timestamp(&manifest.generation_timestamp) {
        return Err("invalid bundle generation timestamp".into());
    }
    if manifest
        .source_sigil_hardware_commit
        .as_deref()
        .is_some_and(|commit| {
            commit.len() != 40 || !commit.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
    {
        return Err("invalid source sigil-hardware commit".into());
    }
    let python = &manifest.python_dependencies;
    if !python.wheels.is_empty()
        || python
            .fully_satisfied_by_debian_packages
            .get("flask")
            .map(String::as_str)
            != Some("python3-flask")
        || python
            .fully_satisfied_by_debian_packages
            .get("argon2")
            .map(String::as_str)
            != Some("python3-argon2")
    {
        return Err(
            "Python runtime dependencies are not fully satisfied by Debian packages".into(),
        );
    }
    Ok(())
}

fn validate_manifest_package(
    package: &ManifestPackage,
    contract: &PackageContract,
) -> Result<(), String> {
    if !valid_package_name(&package.name) || package.version.is_empty() {
        return Err(format!("invalid package metadata: {}", package.filename));
    }
    if !contract
        .allowed_package_architectures
        .contains(&package.architecture)
    {
        return Err(format!(
            "wrong package architecture {}: {}",
            package.architecture, package.filename
        ));
    }
    if !is_sha256(&package.sha256) || package.size == 0 {
        return Err(format!(
            "invalid package checksum or size: {}",
            package.filename
        ));
    }
    if !package.filename.starts_with("packages/") || !package.filename.ends_with(".deb") {
        return Err(format!("unsafe package filename: {}", package.filename));
    }
    Ok(())
}

fn validate_source_and_keyring_metadata(
    repository: &Path,
    manifest: &PackageManifest,
) -> Result<(), String> {
    let expected_sources = BTreeMap::from([
        (
            "debian.sources",
            (
                "/usr/share/keyrings/debian-archive-keyring.pgp",
                "http://deb.debian.org/debian/",
                "http://deb.debian.org/debian/",
            ),
        ),
        (
            "raspi.sources",
            (
                "/usr/share/keyrings/raspberrypi-archive-keyring.pgp",
                "http://archive.raspberrypi.com/debian/",
                "https://ftp.uni-hannover.de/raspberrypi/",
            ),
        ),
    ]);
    if manifest.sources.len() != expected_sources.len() {
        return Err("bundle source metadata is incomplete".into());
    }
    for source in &manifest.sources {
        let Some((signed_by, required_uri, effective_uri)) =
            expected_sources.get(source.file.as_str())
        else {
            return Err(format!(
                "unexpected bundle source metadata: {}",
                source.file
            ));
        };
        if &source.signed_by != signed_by
            || !source.uris.iter().any(|uri| uri == required_uri)
            || !source.effective_uris.iter().any(|uri| uri == effective_uri)
            || !source
                .suites
                .iter()
                .any(|suite| suite.starts_with("trixie"))
            || source.scope.is_empty()
            || !is_sha256(&source.sha256)
        {
            return Err(format!("invalid bundle source metadata: {}", source.file));
        }
        let relative = format!("{SNAPSHOT_DIRECTORY}/{}", source.file);
        let path = safe_repository_file(repository, &relative)?;
        let bytes = read_metadata(&path)?;
        if sha256_bytes(&bytes) != source.sha256 {
            return Err(format!("bundle source hash mismatch: {}", source.file));
        }
        let text = std::str::from_utf8(&bytes)
            .map_err(|error| format!("bundle source is not UTF-8: {error}"))?;
        let lower = text.to_ascii_lowercase();
        if lower.contains("trusted: yes")
            || lower.contains("trusted=yes")
            || lower.contains("allow-unauthenticated")
            || lower.contains("allow-insecure")
        {
            return Err(format!("unauthenticated APT source: {}", source.file));
        }
    }

    let expected_keyrings = BTreeSet::from([
        "keyrings/debian-archive-keyring.pgp".to_string(),
        "keyrings/raspberrypi-archive-keyring.pgp".to_string(),
        "keyrings/sigil-offline-repository.gpg".to_string(),
    ]);
    if manifest
        .keyrings
        .iter()
        .map(|keyring| keyring.artifact_path.clone())
        .collect::<BTreeSet<_>>()
        != expected_keyrings
    {
        return Err("bundle keyring metadata is incomplete".into());
    }
    for keyring in &manifest.keyrings {
        if !safe_relative_path(&keyring.artifact_path)
            || !is_sha256(&keyring.sha256)
            || keyring.scope.is_empty()
            || keyring.source_path.is_empty()
            || keyring.fingerprints.is_empty()
            || keyring.fingerprints.iter().any(|fingerprint| {
                fingerprint.len() != 40 || !fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
        {
            return Err(format!(
                "invalid keyring metadata: {}",
                keyring.artifact_path
            ));
        }
        let relative = format!("{SNAPSHOT_DIRECTORY}/{}", keyring.artifact_path);
        let bytes = read_metadata(&safe_repository_file(repository, &relative)?)?;
        if sha256_bytes(&bytes) != keyring.sha256 {
            return Err(format!("keyring hash mismatch: {}", keyring.artifact_path));
        }
        if keyring.package.is_some() != keyring.package_version.is_some() {
            return Err(format!(
                "incomplete keyring package origin: {}",
                keyring.artifact_path
            ));
        }
    }

    let sources_document: SourcesMetadataDocument = serde_json::from_slice(&read_metadata(
        &repository
            .join(SNAPSHOT_DIRECTORY)
            .join("sources-metadata.json"),
    )?)
    .map_err(|error| format!("invalid sources metadata document: {error}"))?;
    if sources_document.sources != manifest.sources {
        return Err("manifest source metadata differs from source snapshot".into());
    }
    let keyring_document: KeyringMetadataDocument = serde_json::from_slice(&read_metadata(
        &repository
            .join(SNAPSHOT_DIRECTORY)
            .join("keyring-metadata.json"),
    )?)
    .map_err(|error| format!("invalid keyring metadata document: {error}"))?;
    if keyring_document.keyrings != manifest.keyrings {
        return Err("manifest keyring metadata differs from source snapshot".into());
    }
    validate_snapshot_file_set(repository, manifest)
}

fn validate_snapshot_file_set(repository: &Path, manifest: &PackageManifest) -> Result<(), String> {
    let snapshot = repository.join(SNAPSHOT_DIRECTORY);
    let mut actual = BTreeSet::new();
    let mut directories = vec![snapshot.clone()];
    while let Some(directory) = directories.pop() {
        for entry in fs::read_dir(&directory)
            .map_err(|error| format!("cannot enumerate source snapshot: {error}"))?
        {
            let entry =
                entry.map_err(|error| format!("cannot enumerate source snapshot: {error}"))?;
            let metadata = fs::symlink_metadata(entry.path())
                .map_err(|error| format!("cannot inspect source snapshot: {error}"))?;
            if metadata.file_type().is_symlink() {
                return Err("source snapshot contains a symlink".into());
            }
            if metadata.is_dir() {
                directories.push(entry.path());
            } else if metadata.is_file() {
                actual.insert(
                    entry
                        .path()
                        .strip_prefix(repository)
                        .map_err(|_| "source snapshot escaped repository".to_string())?
                        .to_string_lossy()
                        .to_string(),
                );
            } else {
                return Err("source snapshot contains a non-regular entry".into());
            }
        }
    }
    let expected: BTreeSet<_> = expected_checksum_paths(manifest)
        .into_iter()
        .filter(|path| path.starts_with(SNAPSHOT_DIRECTORY))
        .collect();
    if actual != expected {
        return Err("source snapshot file set does not match manifest".into());
    }
    Ok(())
}

fn validate_repository_signature(repository: &Path) -> Result<(), String> {
    let keyring = repository.join(REPOSITORY_KEY);
    for relative in [RELEASE_FILE, RELEASE_GPG_FILE, INRELEASE_FILE] {
        let _ = read_metadata(&repository.join(relative))?;
    }
    for arguments in [
        vec![
            "--keyring".to_string(),
            keyring.to_string_lossy().to_string(),
            repository
                .join(RELEASE_GPG_FILE)
                .to_string_lossy()
                .to_string(),
            repository.join(RELEASE_FILE).to_string_lossy().to_string(),
        ],
        vec![
            "--keyring".to_string(),
            keyring.to_string_lossy().to_string(),
            repository
                .join(INRELEASE_FILE)
                .to_string_lossy()
                .to_string(),
        ],
    ] {
        let output = Command::new("gpgv")
            .args(arguments)
            .output()
            .map_err(|error| format!("cannot execute gpgv: {error}"))?;
        if !output.status.success() {
            return Err("offline repository signature validation failed".into());
        }
    }
    Ok(())
}

fn validate_deb_metadata(path: &Path, expected: &ManifestPackage) -> Result<(), String> {
    let mut fields = Vec::with_capacity(3);
    for field in ["Package", "Version", "Architecture"] {
        let output = Command::new("dpkg-deb")
            .args(["-f"])
            .arg(path)
            .arg(field)
            .output()
            .map_err(|error| format!("cannot execute dpkg-deb: {error}"))?;
        if !output.status.success() {
            return Err(format!("invalid Debian package: {}", path.display()));
        }
        let value = String::from_utf8(output.stdout)
            .map_err(|error| format!("invalid dpkg-deb output: {error}"))?
            .trim()
            .to_owned();
        if value.is_empty() || value.contains('\n') {
            return Err(format!("invalid {field} metadata: {}", path.display()));
        }
        fields.push(value);
    }
    if fields
        != [
            expected.name.clone(),
            expected.version.clone(),
            expected.architecture.clone(),
        ]
    {
        return Err(format!(
            "Debian control metadata mismatch: {}",
            path.display()
        ));
    }
    Ok(())
}

fn parse_packages_index(text: &str) -> Result<BTreeMap<String, IndexPackage>, String> {
    let mut result = BTreeMap::new();
    for stanza in text.split("\n\n").filter(|value| !value.trim().is_empty()) {
        let mut fields = BTreeMap::new();
        for line in stanza.lines().filter(|line| !line.starts_with([' ', '\t'])) {
            if let Some((key, value)) = line.split_once(": ") {
                fields.insert(key, value);
            }
        }
        let field = |name: &str| {
            fields
                .get(name)
                .copied()
                .ok_or_else(|| format!("Packages stanza is missing {name}"))
        };
        let package = IndexPackage {
            name: field("Package")?.to_owned(),
            version: field("Version")?.to_owned(),
            architecture: field("Architecture")?.to_owned(),
            filename: field("Filename")?.to_owned(),
            sha256: field("SHA256")?.to_owned(),
            size: field("Size")?
                .parse()
                .map_err(|_| "Packages stanza has invalid Size".to_string())?,
        };
        if result.insert(package.filename.clone(), package).is_some() {
            return Err("Packages contains duplicate filenames".into());
        }
    }
    if result.is_empty() {
        return Err("Packages index is empty".into());
    }
    Ok(result)
}

fn parse_checksums(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let text = String::from_utf8(read_metadata(path)?)
        .map_err(|error| format!("checksums.sha256 is not UTF-8: {error}"))?;
    let mut checksums = BTreeMap::new();
    for line in text.lines() {
        let (digest, relative) = line
            .split_once("  ")
            .ok_or_else(|| "invalid checksums.sha256 line".to_string())?;
        if !is_sha256(digest) || !safe_relative_path(relative) {
            return Err("invalid checksums.sha256 entry".into());
        }
        if checksums
            .insert(relative.to_owned(), digest.to_owned())
            .is_some()
        {
            return Err(format!("duplicate checksum path: {relative}"));
        }
    }
    Ok(checksums)
}

fn expected_checksum_paths(manifest: &PackageManifest) -> BTreeSet<String> {
    manifest
        .packages
        .iter()
        .map(|package| package.filename.clone())
        .chain(
            manifest
                .sources
                .iter()
                .map(|source| format!("{SNAPSHOT_DIRECTORY}/{}", source.file)),
        )
        .chain(
            manifest
                .keyrings
                .iter()
                .map(|keyring| format!("{SNAPSHOT_DIRECTORY}/{}", keyring.artifact_path)),
        )
        .chain([
            PACKAGES_FILE.to_string(),
            PACKAGES_GZ_FILE.to_string(),
            RELEASE_FILE.to_string(),
            RELEASE_GPG_FILE.to_string(),
            INRELEASE_FILE.to_string(),
            MANIFEST_FILE.to_string(),
            format!("{SNAPSHOT_DIRECTORY}/os-release"),
            format!("{SNAPSHOT_DIRECTORY}/base-image-metadata.json"),
            format!("{SNAPSHOT_DIRECTORY}/sources-metadata.json"),
            format!("{SNAPSHOT_DIRECTORY}/keyring-metadata.json"),
        ])
        .collect()
}

fn validate_no_unexpected_debs(
    repository: &Path,
    expected: &BTreeSet<String>,
) -> Result<(), String> {
    let packages = repository.join("packages");
    let mut actual = BTreeSet::new();
    for entry in fs::read_dir(&packages)
        .map_err(|error| format!("cannot enumerate packages directory: {error}"))?
    {
        let entry = entry.map_err(|error| format!("cannot enumerate package: {error}"))?;
        let metadata = entry
            .metadata()
            .map_err(|error| format!("cannot inspect package: {error}"))?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| "non-UTF-8 package filename".to_string())?;
        if !metadata.is_file() || !name.ends_with(".deb") {
            return Err(format!("unexpected packages directory entry: {name}"));
        }
        actual.insert(format!("packages/{name}"));
    }
    if &actual != expected {
        return Err("package manifest does not match packages directory".into());
    }
    Ok(())
}

fn safe_repository_file(repository: &Path, relative: &str) -> Result<std::path::PathBuf, String> {
    if !safe_relative_path(relative) {
        return Err(format!("unsafe repository path: {relative}"));
    }
    Ok(repository.join(relative))
}

fn safe_relative_path(value: &str) -> bool {
    let path = Path::new(value);
    !value.is_empty()
        && !value.contains('\\')
        && !path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn read_metadata(path: &Path) -> Result<Vec<u8>, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "metadata is not a regular file: {}",
            path.display()
        ));
    }
    if metadata.len() > MAX_METADATA_BYTES {
        return Err(format!("metadata file is too large: {}", path.display()));
    }
    fs::read(path).map_err(|error| format!("cannot read {}: {error}", path.display()))
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut reader = BufReader::new(
        File::open(path).map_err(|error| format!("cannot open {}: {error}", path.display()))?,
    );
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let bytes = reader
            .read(&mut buffer)
            .map_err(|error| format!("cannot hash {}: {error}", path.display()))?;
        if bytes == 0 {
            break;
        }
        digest.update(&buffer[..bytes]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn sha256_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_bundle_version(value: &str) -> bool {
    let fields: Vec<_> = value.split('.').collect();
    fields.len() == 4
        && fields[0].len() == 4
        && fields[1].len() == 2
        && fields[2].len() == 2
        && fields
            .iter()
            .all(|field| !field.is_empty() && field.bytes().all(|byte| byte.is_ascii_digit()))
        && fields[3].parse::<u32>().is_ok_and(|sequence| sequence > 0)
}

fn valid_generation_timestamp(value: &str) -> bool {
    value.len() >= 20
        && value.ends_with('Z')
        && value.as_bytes().get(4) == Some(&b'-')
        && value.as_bytes().get(7) == Some(&b'-')
        && value.as_bytes().get(10) == Some(&b'T')
        && value.as_bytes().get(13) == Some(&b':')
        && value.as_bytes().get(16) == Some(&b':')
}

fn valid_package_name(value: &str) -> bool {
    value.len() >= 2
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || (index > 0 && matches!(byte, b'+' | b'.' | b'-'))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canonical_contract() -> PackageContract {
        serde_json::from_str(include_str!(
            "../../manifests/offline-package-contract.json"
        ))
        .expect("canonical package contract")
    }

    #[test]
    fn safe_relative_path_should_reject_parent_traversal() {
        assert!(!safe_relative_path("packages/../secret.deb"));
    }

    #[test]
    fn parse_packages_index_should_reject_missing_sha256() {
        let error = parse_packages_index(
            "Package: demo\nVersion: 1\nArchitecture: arm64\nFilename: packages/demo.deb\nSize: 1\n",
        )
        .expect_err("index without SHA256 must fail");
        assert!(error.contains("SHA256"));
    }

    #[test]
    fn valid_package_name_should_accept_debian_package_names() {
        assert!(valid_package_name("libfoo2.0+sigil"));
    }

    #[test]
    fn canonical_contract_parses_runtime_and_factory_debug_profiles() {
        let contract = canonical_contract();
        validate_contract(&contract).expect("valid package contract");
        assert_eq!(
            contract
                .packages
                .iter()
                .filter(|package| package.required && package.profile == "runtime")
                .count(),
            23
        );
        assert!(contract.packages.iter().any(|package| {
            package.name == "openssh-server"
                && !package.required
                && package.profile == "factory-debug"
        }));
    }

    #[test]
    fn factory_debug_profile_is_required_in_manufacturing_bundle() {
        let contract = canonical_contract();
        let included: BTreeSet<_> = contract
            .packages
            .iter()
            .filter(|package| package.required || package.profile == "factory-debug")
            .map(|package| package.name.as_str())
            .collect();

        assert!(included.contains("openssh-server"));
    }

    #[test]
    fn contract_requires_a_non_ambiguous_bundle_version() {
        let mut contract = canonical_contract();
        contract.bundle_version.clear();
        assert!(validate_contract(&contract)
            .expect_err("missing bundle version must fail")
            .contains("bundle version"));
        contract.bundle_version = "2026.7.15.1".into();
        assert!(validate_contract(&contract).is_err());
    }
}
