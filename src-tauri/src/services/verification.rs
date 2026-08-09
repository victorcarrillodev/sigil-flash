use crate::errors::{Result, SigilError};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{BufReader, Read};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// Calcula el SHA-256 de un archivo en disco
pub fn calculate_sha256(path: &Path) -> Result<String> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];

    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

/// Detecta la arquitectura real de un rootfs montado leyendo la cabecera ELF
/// de /bin/bash, /usr/bin/bash, /bin/sh, /usr/bin/sh o /lib/systemd/systemd
/// Resuelve symlinks hasta 5 niveles y respeta el endianness de la cabecera ELF.
pub fn detect_rootfs_architecture(rootfs_path: &Path) -> Result<String> {
    let candidates = [
        "bin/bash",
        "usr/bin/bash",
        "bin/sh",
        "usr/bin/sh",
        "lib/systemd/systemd",
        "usr/lib/systemd/systemd",
    ];

    for rel_path in &candidates {
        let full_path = rootfs_path.join(rel_path);
        if full_path.exists() {
            if let Ok(resolved) = resolve_symlink_limit(&full_path, 5) {
                if let Ok(arch) = read_elf_architecture(&resolved) {
                    return Ok(arch);
                }
            }
        }
    }

    Err(SigilError::Validation(format!(
        "No se pudo determinar la arquitectura ELF de los binarios del rootfs en '{}'",
        rootfs_path.display()
    )))
}

fn resolve_symlink_limit(path: &Path, max_depth: usize) -> Result<PathBuf> {
    let mut current = path.to_path_buf();
    for _ in 0..max_depth {
        if fs::symlink_metadata(&current)?.file_type().is_symlink() {
            current = fs::read_link(&current)?;
        } else {
            return Ok(current);
        }
    }
    Ok(current)
}

/// Lee e_machine de una cabecera ELF respetando el byte order (little vs big endian)
pub fn read_elf_architecture(file_path: &Path) -> Result<String> {
    let mut file = File::open(file_path)?;
    let mut header = [0u8; 20];
    file.read_exact(&mut header)?;

    // Magia ELF: 0x7F 'E' 'L' 'F'
    if &header[0..4] != b"\x7fELF" {
        return Err(SigilError::Validation(format!("'{}' no es un ejecutable ELF válido", file_path.display())));
    }

    let endianness = header[5]; // 1 = Little Endian, 2 = Big Endian
    let e_machine_bytes = [header[18], header[19]];

    let e_machine = if endianness == 1 {
        u16::from_le_bytes(e_machine_bytes)
    } else {
        u16::from_be_bytes(e_machine_bytes)
    };

    match e_machine {
        40 => Ok("armhf".to_string()),   // ARM 32-bit
        183 => Ok("arm64".to_string()),  // ARM 64-bit (AArch64)
        62 => Ok("x86_64".to_string()),  // x86-64
        3 => Ok("x86".to_string()),      // x86 32-bit
        other => Ok(format!("unknown({})", other)),
    }
}

/// Valida que los archivos de un payload coincidan byte a byte con su payload-manifest.json
pub fn verify_payload_manifest(payload_dir: &Path) -> Result<()> {
    let manifest_path = payload_dir.join("payload-manifest.json");
    if !manifest_path.is_file() {
        return Err(SigilError::Validation(format!(
            "Manifiesto de payload ausente: '{}'",
            manifest_path.display()
        )));
    }

    let content = fs::read_to_string(&manifest_path)?;
    let json: serde_json::Value = serde_json::from_str(&content)?;

    let files = json.get("files").and_then(|f| f.as_array()).ok_or_else(|| {
        SigilError::Validation("payload-manifest.json no contiene la lista 'files'".to_string())
    })?;

    for file_entry in files {
        let rel_path = file_entry.get("path").and_then(|p| p.as_str()).ok_or_else(|| {
            SigilError::Validation("Entrada de archivo en manifiesto sin campo 'path'".to_string())
        })?;
        let expected_hash = file_entry.get("sha256").and_then(|h| h.as_str()).ok_or_else(|| {
            SigilError::Validation("Entrada de archivo en manifiesto sin campo 'sha256'".to_string())
        })?;

        let file_path = payload_dir.join(rel_path);
        if !file_path.is_file() {
            return Err(SigilError::Validation(format!(
                "Archivo de payload ausente según el manifiesto: '{}'",
                rel_path
            )));
        }

        let actual_hash = calculate_sha256(&file_path)?;
        if actual_hash != expected_hash {
            return Err(SigilError::Validation(format!(
                "Checksum no coincide en archivo de payload '{}': esperado {}, obtenido {}",
                rel_path, expected_hash, actual_hash
            )));
        }
    }

    Ok(())
}

/// Restaura los modos declarados en el manifiesto tras copiar el payload y
/// normaliza los directorios a 0755. `cp -a` conserva modos pero no
/// propietario cuando no se corre como root, y una copia con permisos
/// relajados rompe el chroot posterior de forma confusa.
pub fn restore_payload_modes(payload_dir: &Path) -> Result<()> {
    let manifest_path = payload_dir.join("payload-manifest.json");
    let content = fs::read_to_string(&manifest_path)?;
    let json: serde_json::Value = serde_json::from_str(&content)?;

    let files = json.get("files").and_then(|f| f.as_array()).ok_or_else(|| {
        SigilError::Validation("payload-manifest.json no contiene la lista 'files'".to_string())
    })?;

    for entry in files {
        let rel_path = entry
            .get("path")
            .and_then(|p| p.as_str())
            .ok_or_else(|| SigilError::Validation("Entrada sin campo 'path'".to_string()))?;
        let mode_str = entry
            .get("mode")
            .and_then(|m| m.as_str())
            .ok_or_else(|| SigilError::Validation(format!("Entrada '{}' sin campo 'mode'", rel_path)))?;
        let mode = u32::from_str_radix(mode_str, 8).map_err(|_| {
            SigilError::Validation(format!("Modo no octal en el manifiesto: '{}'", mode_str))
        })?;

        let file_path = payload_dir.join(rel_path);
        fs::set_permissions(&file_path, fs::Permissions::from_mode(mode))?;
    }

    normalize_directory_modes(payload_dir)?;
    Ok(())
}

fn normalize_directory_modes(dir: &Path) -> Result<()> {
    fs::set_permissions(dir, fs::Permissions::from_mode(0o755))?;
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            normalize_directory_modes(&entry.path())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    fn write_fake_elf(path: &Path, e_machine: u16, little_endian: bool) -> Result<()> {
        let mut header = [0u8; 20];
        header[0..4].copy_from_slice(b"\x7fELF");
        header[4] = 2;
        header[5] = if little_endian { 1 } else { 2 };
        let bytes = if little_endian {
            e_machine.to_le_bytes()
        } else {
            e_machine.to_be_bytes()
        };
        header[18] = bytes[0];
        header[19] = bytes[1];
        File::create(path)?.write_all(&header)?;
        Ok(())
    }

    #[test]
    fn test_elf_architecture_detection() -> Result<()> {
        let dir = tempdir()?;

        for (name, machine, expected) in [
            ("bin_arm32", 40u16, "armhf"),
            ("bin_arm64", 183u16, "arm64"),
            ("bin_x86_64", 62u16, "x86_64"),
            ("bin_x86", 3u16, "x86"),
        ] {
            let path = dir.path().join(name);
            write_fake_elf(&path, machine, true)?;
            assert_eq!(read_elf_architecture(&path)?, expected, "fallo en {}", name);
        }

        // El orden de bytes declarado en la cabecera debe respetarse.
        let big_endian = dir.path().join("bin_arm64_be");
        write_fake_elf(&big_endian, 183, false)?;
        assert_eq!(read_elf_architecture(&big_endian)?, "arm64");

        // Un archivo que no es ELF se rechaza en vez de adivinarse.
        let not_elf = dir.path().join("no_elf");
        fs::write(&not_elf, "#!/bin/sh\necho hola\n")?;
        assert!(read_elf_architecture(&not_elf).is_err());

        Ok(())
    }

    #[test]
    fn test_rootfs_architecture_resolves_through_symlinks() -> Result<()> {
        let dir = tempdir()?;
        let rootfs = dir.path();
        fs::create_dir_all(rootfs.join("usr/bin"))?;
        fs::create_dir_all(rootfs.join("bin"))?;

        write_fake_elf(&rootfs.join("usr/bin/bash"), 183, true)?;
        std::os::unix::fs::symlink(rootfs.join("usr/bin/bash"), rootfs.join("bin/bash"))?;

        assert_eq!(detect_rootfs_architecture(rootfs)?, "arm64");
        Ok(())
    }

    #[test]
    fn test_copied_payload_matches_manifest_and_modes_are_restored() -> Result<()> {
        let dir = tempdir()?;
        let source = dir.path().join("payload");
        fs::create_dir_all(source.join("scripts"))?;

        let script = source.join("scripts/firstboot.sh");
        fs::write(&script, "#!/bin/bash\nexit 0\n")?;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755))?;
        let conf = source.join("audio.conf");
        fs::write(&conf, "SERVER_URL=\"https://x\"\n")?;

        let manifest = serde_json::json!({
            "files": [
                {"path": "scripts/firstboot.sh", "sha256": calculate_sha256(&script)?, "mode": "0755"},
                {"path": "audio.conf", "sha256": calculate_sha256(&conf)?, "mode": "0640"}
            ]
        });
        fs::write(source.join("payload-manifest.json"), manifest.to_string())?;

        // Copia equivalente a la que hace el proceso elevado, con los modos
        // perdidos como ocurre cuando no se copia como root.
        let copied = dir.path().join("copied");
        fs::create_dir_all(copied.join("scripts"))?;
        for rel in ["scripts/firstboot.sh", "audio.conf", "payload-manifest.json"] {
            fs::copy(source.join(rel), copied.join(rel))?;
            fs::set_permissions(&copied.join(rel), fs::Permissions::from_mode(0o666))?;
        }

        restore_payload_modes(&copied)?;
        verify_payload_manifest(&copied)?;

        let script_mode = fs::metadata(copied.join("scripts/firstboot.sh"))?.permissions().mode();
        let conf_mode = fs::metadata(copied.join("audio.conf"))?.permissions().mode();
        let dir_mode = fs::metadata(copied.join("scripts"))?.permissions().mode();
        assert_eq!(script_mode & 0o777, 0o755);
        assert_eq!(conf_mode & 0o777, 0o640);
        assert_eq!(dir_mode & 0o777, 0o755, "los directorios se normalizan a 0755");

        // Un archivo alterado tras copiarse debe detectarse.
        fs::write(copied.join("audio.conf"), "SERVER_URL=\"https://malicioso\"\n")?;
        assert!(verify_payload_manifest(&copied).is_err());

        Ok(())
    }

    #[test]
    fn test_payload_tamper_detection() -> Result<()> {
        let dir = tempdir()?;
        let payload_dir = dir.path().join("payload");
        fs::create_dir_all(&payload_dir)?;

        let file1 = payload_dir.join("install.sh");
        fs::write(&file1, "echo hello")?;
        let hash1 = calculate_sha256(&file1)?;

        let manifest = serde_json::json!({
            "files": [
                {
                    "path": "install.sh",
                    "sha256": hash1,
                    "mode": "0755"
                }
            ]
        });
        fs::write(payload_dir.join("payload-manifest.json"), manifest.to_string())?;

        // Verificación exitosa
        assert!(verify_payload_manifest(&payload_dir).is_ok());

        // Modificar archivo para simular alteración
        fs::write(&file1, "echo TAMPERED")?;
        assert!(verify_payload_manifest(&payload_dir).is_err());

        Ok(())
    }
}
