use crate::errors::{Result, SigilError};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use tracing::info;

/// Par bundle/payload ya emparejado y coherente entre sí.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BundlePair {
    pub contract_name: String,
    pub repo: PathBuf,
    pub payload: PathBuf,
    pub architecture: String,
    pub base_image_name: String,
    pub base_image_sha256: String,
}

pub const CANONICAL_CONTRACT: &str = "offline-package-contract";

/// El paquete que el perfil de diagnóstico añade. Sin él en el bundle, activar
/// el acceso remoto aborta el instalador dentro del chroot.
pub const SSH_SERVER_PACKAGE: &str = "openssh-server";

/// `true` si el bundle trae el paquete pedido, mirando los `.deb` reales del
/// repositorio. Se comprueba el disco y no `direct_packages` del manifiesto:
/// lo que el instalador exige es el archivo, no la declaración.
pub fn repository_has_package(repo: &Path, package: &str) -> bool {
    let packages_dir = repo.join("packages");
    let prefix = format!("{}_", package);
    fs::read_dir(packages_dir)
        .map(|entries| {
            entries.flatten().any(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .map(|name| name.starts_with(&prefix) && name.ends_with(".deb"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// El acceso remoto activa el perfil `factory-debug`, y ese perfil exige
/// `openssh-server` dentro del repositorio offline. Un bundle construido sin el
/// perfil mata al instalador ya dentro del chroot: 2,5 GB escritos y media hora
/// perdida por algo que se sabe antes de tocar la tarjeta.
pub fn validate_ssh_profile_available(pair: &BundlePair, ssh_enabled: bool) -> Result<()> {
    if !ssh_enabled || repository_has_package(&pair.repo, SSH_SERVER_PACKAGE) {
        return Ok(());
    }
    Err(SigilError::Validation(format!(
        "El acceso remoto SSH está activado, pero el bundle '{}' no incluye '{}': se \
         construyó sin el perfil de diagnóstico y el instalador abortaría dentro del \
         chroot.\nDesactive el acceso remoto —es un perfil de diagnóstico, no algo que \
         deba ir en un equipo de cliente— o reconstruya el bundle exportando el perfil, \
         para que la variable llegue también al constructor del repositorio:\n  \
         export SIGIL_PACKAGE_PROFILES=factory-debug\n  ./scripts/build-all-bundles.sh",
        pair.contract_name, SSH_SERVER_PACKAGE
    )))
}

/// Un nombre de variante viaja desde la UI hasta una ruta de disco: cualquier
/// separador o componente relativo permitiría salir del árbol de artefactos.
pub fn validate_variant_name(variant: &str) -> Result<()> {
    if variant.is_empty() {
        return Err(SigilError::Validation(
            "El nombre de variante no puede estar vacío".to_string(),
        ));
    }
    if variant.len() > 64 {
        return Err(SigilError::Validation(
            "El nombre de variante excede los 64 caracteres permitidos".to_string(),
        ));
    }
    if variant.contains('/') || variant.contains('\\') || variant.contains("..") {
        return Err(SigilError::Validation(format!(
            "Nombre de variante rechazado por intento de path traversal: '{}'",
            variant
        )));
    }
    if !variant
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
    {
        return Err(SigilError::Validation(format!(
            "El nombre de variante solo admite caracteres [A-Za-z0-9._-]: '{}'",
            variant
        )));
    }
    Ok(())
}

fn contract_name_for_variant(variant: Option<&str>) -> Result<String> {
    match variant {
        None => Ok(CANONICAL_CONTRACT.to_string()),
        Some(v) => {
            validate_variant_name(v)?;
            Ok(format!("{}.{}", CANONICAL_CONTRACT, v))
        }
    }
}

fn read_json(path: &Path) -> Result<serde_json::Value> {
    let content = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&content)?)
}

/// Construye el par a partir del nombre de contrato, exigiendo que el payload y
/// el repositorio existan Y que declaren la misma imagen base y arquitectura.
/// Un payload sin su repositorio correspondiente nunca produce un par válido.
fn build_pair(artifacts_root: &Path, contract_name: &str) -> Option<BundlePair> {
    let payload = artifacts_root
        .join("payloads")
        .join(format!("{}-payload", contract_name));
    let repo = artifacts_root
        .join("bundles")
        .join(format!("{}-repo", contract_name));

    let contract = read_json(&payload.join("manifests/offline-package-contract.json")).ok()?;
    let base_image_name = contract.get("base_image_name")?.as_str()?.to_string();
    let architecture = contract.get("architecture")?.as_str()?.to_string();
    let base_image_sha256 = contract
        .get("base_image_sha256")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();

    let repo_manifest = read_json(&repo.join("package-manifest.json")).ok()?;
    let repo_image = repo_manifest.get("base_image_name")?.as_str()?;
    let repo_arch = repo_manifest.get("architecture")?.as_str()?;

    if repo_image != base_image_name || repo_arch != architecture {
        return None;
    }

    Some(BundlePair {
        contract_name: contract_name.to_string(),
        repo,
        payload,
        architecture,
        base_image_name,
        base_image_sha256,
    })
}

/// Enumera los contratos descubiertos por patrón de nombre en artifacts/payloads.
fn discover_contract_names(artifacts_root: &Path) -> Vec<String> {
    let mut names = Vec::new();
    let payloads_dir = artifacts_root.join("payloads");
    if let Ok(entries) = fs::read_dir(&payloads_dir) {
        for entry in entries.flatten() {
            if let Some(dir_name) = entry.file_name().to_str() {
                if let Some(stripped) = dir_name.strip_suffix("-payload") {
                    if stripped.starts_with(CANONICAL_CONTRACT) {
                        names.push(stripped.to_string());
                    }
                }
            }
        }
    }
    names.sort();
    names
}

/// Tokens que anuncian arquitectura sin ambigüedad. "32bits"/"64bits" quedan
/// deliberadamente fuera: aparecen en nombres de descargas mal etiquetadas.
pub fn architecture_from_decisive_token(image_name: &str) -> Option<String> {
    let lower = image_name.to_lowercase();
    let decisive: [(&str, &str); 5] = [
        ("aarch64", "arm64"),
        ("arm64", "arm64"),
        ("armhf", "armhf"),
        ("armv7", "armhf"),
        ("armv6", "armhf"),
    ];
    for (token, arch) in decisive {
        if lower.contains(token) {
            return Some(arch.to_string());
        }
    }
    None
}

/// Resolución del par bundle/payload en tres niveles.
pub fn resolve_bundle_payload(
    artifacts_root: &Path,
    image_name: &str,
    variant: Option<&str>,
) -> Result<BundlePair> {
    // Una variante explícita fija el contrato: no se cae a heurísticas.
    if variant.is_some() {
        let contract_name = contract_name_for_variant(variant)?;
        return build_pair(artifacts_root, &contract_name).ok_or_else(|| {
            SigilError::Validation(format!(
                "No hay un par bundle/payload completo para la variante '{}'. \
                 Ejecute ./scripts/build-all-bundles.sh para generarlo.",
                contract_name
            ))
        });
    }

    let candidates: Vec<BundlePair> = discover_contract_names(artifacts_root)
        .iter()
        .filter_map(|name| build_pair(artifacts_root, name))
        .collect();

    if candidates.is_empty() {
        return Err(SigilError::Validation(
            "No existe ningún repositorio APT offline construido junto a su payload. \
             Ejecute ./scripts/build-all-bundles.sh antes de fabricar."
                .to_string(),
        ));
    }

    // Nivel a) el contrato embebido fija EXACTAMENTE este nombre de imagen
    if let Some(pair) = candidates.iter().find(|c| c.base_image_name == image_name) {
        info!("Par bundle/payload resuelto por nombre exacto de imagen: {}", pair.contract_name);
        return Ok(pair.clone());
    }

    // Nivel b) arquitectura anunciada por un token decisivo del nombre
    if let Some(arch) = architecture_from_decisive_token(image_name) {
        if let Some(pair) = candidates.iter().find(|c| c.architecture == arch) {
            info!("Par bundle/payload resuelto por token decisivo '{}': {}", arch, pair.contract_name);
            return Ok(pair.clone());
        }
        return Err(SigilError::Validation(format!(
            "La imagen '{}' declara arquitectura '{}' pero no hay bundle construido para ella. \
             Ejecute ./scripts/build-all-bundles.sh con el contrato correspondiente.",
            image_name, arch
        )));
    }

    // Nivel c) valores por defecto canónicos
    if let Some(pair) = candidates.iter().find(|c| c.contract_name == CANONICAL_CONTRACT) {
        info!("Par bundle/payload resuelto por defecto canónico: {}", pair.contract_name);
        return Ok(pair.clone());
    }

    Err(SigilError::Validation(format!(
        "No se pudo emparejar la imagen '{}' con ningún bundle disponible y no existe el contrato canónico",
        image_name
    )))
}

/// Localiza la raíz del proyecto subiendo desde el ejecutable y desde el
/// directorio de trabajo. Nunca se codifica la ruta del equipo de un
/// desarrollador: el árbol se reconoce por sus marcas.
pub fn project_root() -> PathBuf {
    if let Ok(dir) = std::env::var("SIGIL_PROJECT_ROOT") {
        return PathBuf::from(dir);
    }

    let marks = ["sigil-hardware/manifests", "scripts/build-all-bundles.sh"];
    let is_root = |dir: &Path| marks.iter().all(|m| dir.join(m).exists());

    for start in [
        std::env::current_exe().ok().and_then(|e| e.parent().map(|p| p.to_path_buf())),
        std::env::current_dir().ok(),
    ]
    .into_iter()
    .flatten()
    {
        let mut cursor = Some(start);
        while let Some(dir) = cursor {
            if is_root(&dir) {
                return dir;
            }
            cursor = dir.parent().map(|p| p.to_path_buf());
        }
    }

    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Raíz de artefactos (bundles y payloads) del proyecto.
pub fn default_artifacts_root() -> PathBuf {
    if let Ok(dir) = std::env::var("SIGIL_ARTIFACTS_DIR") {
        return PathBuf::from(dir);
    }
    project_root().join("artifacts")
}

/// Valida que la imagen seleccionada y el par elegido no se contradigan.
pub fn validate_pair_against_image(pair: &BundlePair, image_name: &str) -> Result<()> {
    if pair.base_image_name == image_name {
        return Ok(());
    }
    if let Some(arch) = architecture_from_decisive_token(image_name) {
        if arch != pair.architecture {
            return Err(SigilError::Validation(format!(
                "La imagen '{}' anuncia arquitectura '{}' pero el bundle '{}' es '{}'. \
                 Seleccione la imagen correcta o construya el bundle de esa arquitectura.",
                image_name, arch, pair.contract_name, pair.architecture
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn write_pair(root: &Path, contract: &str, image: &str, arch: &str, with_repo: bool) {
        let payload = root.join("payloads").join(format!("{}-payload", contract));
        fs::create_dir_all(payload.join("manifests")).unwrap();
        let contract_json = serde_json::json!({
            "base_image_name": image,
            "architecture": arch,
            "base_image_sha256": "0".repeat(64),
        });
        fs::write(
            payload.join("manifests/offline-package-contract.json"),
            contract_json.to_string(),
        )
        .unwrap();

        if with_repo {
            let repo = root.join("bundles").join(format!("{}-repo", contract));
            fs::create_dir_all(&repo).unwrap();
            let manifest = serde_json::json!({
                "base_image_name": image,
                "architecture": arch,
            });
            fs::write(repo.join("package-manifest.json"), manifest.to_string()).unwrap();
        }
    }

    #[test]
    fn test_resolution_level_a_exact_image_name() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        write_pair(root, "offline-package-contract", "img-arm64.img.xz", "arm64", true);
        write_pair(root, "offline-package-contract.armhf", "32bits-img-armhf.img.xz", "armhf", true);

        let pair = resolve_bundle_payload(root, "32bits-img-armhf.img.xz", None).unwrap();
        assert_eq!(pair.contract_name, "offline-package-contract.armhf");
        assert_eq!(pair.architecture, "armhf");
    }

    #[test]
    fn test_resolution_level_b_decisive_token_ignores_ambiguous() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        write_pair(root, "offline-package-contract", "canonical-arm64.img.xz", "arm64", true);
        write_pair(root, "offline-package-contract.armhf", "canonical-armhf.img.xz", "armhf", true);

        // "32bits" es ambiguo y se ignora; "armhf" es decisivo y manda.
        let pair = resolve_bundle_payload(root, "descarga-32bits-armhf-lite.img.xz", None).unwrap();
        assert_eq!(pair.architecture, "armhf");

        let pair = resolve_bundle_payload(root, "otra-64bits-aarch64-lite.img.xz", None).unwrap();
        assert_eq!(pair.architecture, "arm64");

        // Un nombre solo con tokens ambiguos no decide nada por sí mismo.
        assert!(architecture_from_decisive_token("imagen-64bits.img.xz").is_none());
    }

    #[test]
    fn test_resolution_level_c_canonical_default() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        write_pair(root, "offline-package-contract", "canonical.img.xz", "arm64", true);

        let pair = resolve_bundle_payload(root, "imagen-sin-tokens.img.xz", None).unwrap();
        assert_eq!(pair.contract_name, CANONICAL_CONTRACT);
    }

    #[test]
    fn test_payload_without_repository_is_never_selected() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        write_pair(root, "offline-package-contract", "canonical.img.xz", "arm64", false);

        let err = resolve_bundle_payload(root, "canonical.img.xz", None).unwrap_err();
        assert!(err.to_string().contains("build-all-bundles"));
    }

    #[test]
    fn test_variant_path_traversal_rejected() {
        assert!(validate_variant_name("armhf").is_ok());
        assert!(validate_variant_name("../../etc/passwd").is_err());
        assert!(validate_variant_name("armhf/../..").is_err());
        assert!(validate_variant_name("arm\\hf").is_err());
        assert!(validate_variant_name("..").is_err());
        assert!(validate_variant_name("").is_err());

        let dir = tempdir().unwrap();
        let err = resolve_bundle_payload(dir.path(), "x.img", Some("../secret")).unwrap_err();
        assert!(err.to_string().contains("path traversal"));
    }

    #[test]
    fn test_wrong_architecture_contract_is_rejected() {
        let pair = BundlePair {
            contract_name: "offline-package-contract".to_string(),
            repo: PathBuf::from("/tmp/repo"),
            payload: PathBuf::from("/tmp/payload"),
            architecture: "arm64".to_string(),
            base_image_name: "canonical-arm64.img.xz".to_string(),
            base_image_sha256: "0".repeat(64),
        };

        assert!(validate_pair_against_image(&pair, "canonical-arm64.img.xz").is_ok());
        let err = validate_pair_against_image(&pair, "otra-armhf-lite.img.xz").unwrap_err();
        assert!(err.to_string().contains("armhf"));
    }

    fn pair_con_repositorio(repo: &Path) -> BundlePair {
        BundlePair {
            contract_name: "offline-package-contract.armhf".to_string(),
            repo: repo.to_path_buf(),
            payload: PathBuf::from("/tmp/payload"),
            architecture: "armhf".to_string(),
            base_image_name: "canonical-armhf.img.xz".to_string(),
            base_image_sha256: "0".repeat(64),
        }
    }

    /// Un bundle sin el perfil de diagnóstico mata al instalador ya dentro del
    /// chroot, con la tarjeta escrita entera. Se detecta antes de tocarla.
    #[test]
    fn test_ssh_without_the_package_in_the_bundle_is_rejected_up_front() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("packages")).unwrap();
        fs::write(
            dir.path().join("packages/libssh2-1t64_1.11.1-1_armhf.deb"),
            "x",
        )
        .unwrap();
        let pair = pair_con_repositorio(dir.path());

        let err = validate_ssh_profile_available(&pair, true).unwrap_err();
        assert!(err.to_string().contains("openssh-server"), "{}", err);
        assert!(err.to_string().contains("factory-debug"), "sin salida: {}", err);
    }

    #[test]
    fn test_a_lookalike_package_does_not_pass_for_the_real_one() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("packages")).unwrap();
        // 'openssh-client' comparte prefijo hasta el guion; el separador real
        // del nombre de un .deb es '_'.
        for name in ["openssh-client_9.2_armhf.deb", "openssh-sftp-server_9.2_armhf.deb"] {
            fs::write(dir.path().join("packages").join(name), "x").unwrap();
        }
        assert!(!repository_has_package(dir.path(), SSH_SERVER_PACKAGE));
        assert!(validate_ssh_profile_available(&pair_con_repositorio(dir.path()), true).is_err());
    }

    #[test]
    fn test_the_bundle_with_the_profile_passes() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("packages")).unwrap();
        fs::write(
            dir.path().join("packages/openssh-server_9.2p1-2_armhf.deb"),
            "x",
        )
        .unwrap();
        assert!(repository_has_package(dir.path(), SSH_SERVER_PACKAGE));
        assert!(validate_ssh_profile_available(&pair_con_repositorio(dir.path()), true).is_ok());
    }

    /// Sin acceso remoto no se pide el perfil, así que el paquete no hace falta.
    #[test]
    fn test_without_ssh_the_bundle_needs_nothing_extra() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("packages")).unwrap();
        assert!(validate_ssh_profile_available(&pair_con_repositorio(dir.path()), false).is_ok());
    }

    #[test]
    fn test_an_unreadable_repository_is_not_taken_as_satisfied() {
        let dir = tempdir().unwrap();
        // Sin directorio 'packages' siquiera.
        assert!(!repository_has_package(dir.path(), SSH_SERVER_PACKAGE));
    }
}
