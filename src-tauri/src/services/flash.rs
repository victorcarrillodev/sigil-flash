use crate::errors::{Result, SigilError};
use crate::models::DeviceConfig;
use crate::services::bundle::{
    validate_pair_against_image, validate_ssh_profile_available, BundlePair,
};
use crate::services::config::validate_device_config;
use crate::services::disk::{
    get_partition_path, is_e2fsck_exit_acceptable, is_growpart_result_acceptable,
    validate_expansion_within_tolerance, validate_target_not_system_disk,
};
use crate::services::progress::{write_progress_file, ProgressTracker};
use crate::services::provision::{
    apply_boot_tuning, architecture_from_boot_config, find_qemu_interpreter, provision_panel_pin,
    provision_remote_access, require_kernel_for_board, rewrite_server_url,
    validate_model_supports_architecture, write_enrollment_key, write_identity_document,
    write_wifi_profile,
};
use crate::services::verification::{
    detect_rootfs_architecture, restore_payload_modes, verify_payload_manifest,
};
use libc::{O_CLOEXEC, O_NOFOLLOW, O_RDONLY};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::io::FromRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;
use tracing::{info, warn};

/// Ruta de preparación del payload DENTRO de la imagen. install.sh se ejecuta
/// desde aquí porque exige tener panel/, scripts/, services/, conf/ y
/// manifests/ como hermanos suyos.
pub const PAYLOAD_STAGING_DIR: &str = "opt/sigil/install-payload";
pub const OFFLINE_REPO_DIR: &str = "opt/sigil/offline-repo";

/// Guarda para lock exclusivo de dispositivo con PID reclamable
pub struct LockFileGuard {
    lock_path: PathBuf,
    pid: u32,
}

/// Decide si un lock existente puede reclamarse. Separada de la E/S para poder
/// probar las dos ramas sin depender de PIDs reales del sistema.
pub fn lock_is_claimable(existing_pid: i32, pid_is_alive: bool) -> Result<()> {
    if pid_is_alive {
        return Err(SigilError::Flash(format!(
            "Dispositivo bloqueado por otro proceso de flasheo activo (PID {}). \
             Espere a que termine o cierre esa operación antes de reintentar.",
            existing_pid
        )));
    }
    Ok(())
}

fn pid_is_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    unsafe { libc::kill(pid, 0) == 0 }
}

impl LockFileGuard {
    pub fn acquire(device_path: &Path) -> Result<Self> {
        let dev_name = device_path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown");
        let lock_path = PathBuf::from(format!("/run/lock/sigil-flash-{}.lock", dev_name));
        let my_pid = std::process::id();

        if let Ok(content) = fs::read_to_string(&lock_path) {
            if let Ok(existing_pid) = content.trim().parse::<i32>() {
                lock_is_claimable(existing_pid, pid_is_alive(existing_pid))?;
                info!("Reclamando lock huérfano del PID muerto {}", existing_pid);
                let _ = fs::remove_file(&lock_path);
            }
        }

        // create_new cierra la carrera entre comprobar y escribir: si otro
        // proceso ganó entre medias, aquí falla en vez de pisar su lock.
        let mut file = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .custom_flags(O_NOFOLLOW | O_CLOEXEC)
            .open(&lock_path)
        {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                return Err(SigilError::Flash(
                    "Otro proceso adquirió el lock del dispositivo simultáneamente".to_string(),
                ))
            }
            Err(e) => return Err(e.into()),
        };
        file.write_all(format!("{}\n", my_pid).as_bytes())?;
        file.sync_all()?;

        Ok(Self { lock_path, pid: my_pid })
    }
}

impl Drop for LockFileGuard {
    fn drop(&mut self) {
        // Solo se libera si el archivo sigue conteniendo el PID propio.
        if let Ok(content) = fs::read_to_string(&self.lock_path) {
            if content.trim() == self.pid.to_string() {
                let _ = fs::remove_file(&self.lock_path);
            }
        }
    }
}

/// El proceso elevado corre como root, pero la configuración la creó el
/// operario antes de elevar: se aceptan esos dos dueños y ningún otro, para
/// que nadie más pueda plantar un archivo que este proceso vaya a leer.
pub fn config_owner_is_trusted(
    file_uid: u32,
    effective_uid: u32,
    invoking_uid: Option<u32>,
) -> bool {
    file_uid == effective_uid || Some(file_uid) == invoking_uid
}

fn pkexec_invoking_uid() -> Option<u32> {
    std::env::var("PKEXEC_UID").ok().and_then(|v| v.parse().ok())
}

/// 1. Leer configuración privada con controles estrictos de seguridad
pub fn read_and_verify_private_config(config_file: &Path) -> Result<DeviceConfig> {
    let meta = fs::symlink_metadata(config_file)?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return Err(SigilError::Flash(format!(
            "Archivo de configuración inseguro (es symlink o no regular): '{}'",
            config_file.display()
        )));
    }

    if meta.len() > 16384 {
        return Err(SigilError::Flash(
            "Tamaño de archivo de configuración excede los 16 KiB permitidos".to_string(),
        ));
    }

    let mode = meta.permissions().mode();
    if (mode & 0o077) != 0 {
        return Err(SigilError::Flash(format!(
            "Permisos inseguros en archivo de configuración ({:o}); no debe tener bits de grupo u otros",
            mode & 0o777
        )));
    }

    let effective_uid = unsafe { libc::geteuid() };
    if !config_owner_is_trusted(meta.uid(), effective_uid, pkexec_invoking_uid()) {
        return Err(SigilError::Flash(format!(
            "El archivo de configuración pertenece al UID {}, que no es ni el usuario \
             efectivo ({}) ni el operario que autorizó la elevación",
            meta.uid(),
            effective_uid
        )));
    }

    let dev_before = meta.dev();
    let ino_before = meta.ino();

    let c_path = std::ffi::CString::new(config_file.to_str().ok_or_else(|| {
        SigilError::Flash("Ruta de archivo de configuración no válida".to_string())
    })?)
    .map_err(|_| SigilError::Flash("Ruta de configuración con bytes nulos".to_string()))?;

    let fd = unsafe { libc::open(c_path.as_ptr(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC) };
    if fd < 0 {
        return Err(SigilError::Flash(format!(
            "No se pudo abrir el archivo de configuración con O_NOFOLLOW: {}",
            std::io::Error::last_os_error()
        )));
    }

    let mut file = unsafe { File::from_raw_fd(fd) };
    let meta_after = file.metadata()?;

    if meta_after.dev() != dev_before || meta_after.ino() != ino_before {
        return Err(SigilError::Flash(
            "Inconsistencia detectada (dev/inode cambiaron entre stat y open)".to_string(),
        ));
    }

    let mut content = String::new();
    file.read_to_string(&mut content)?;
    let config: DeviceConfig = serde_json::from_str(&content)?;

    Ok(config)
}

/// Proceso principal del escritor privilegiado (--flash-raw)
pub fn execute_flash_raw(
    src_image: &Path,
    dest_device: &Path,
    progress_file: &Path,
    offline_packages: &Path,
    payload_dir: &Path,
    config_file: &Path,
) -> Result<()> {
    let mut tracker = ProgressTracker::new();

    let p = tracker.update(0, 100, "running", "Verificando archivo de configuración privada...");
    write_progress_file(progress_file, &p)?;

    // 1. Leer configuración privada
    let config = read_and_verify_private_config(config_file)?;

    // 2. Revalidar con las mismas reglas que aplicó la GUI
    validate_device_config(&config)?;

    // 3. Borrar la configuración: es de un solo uso
    if let Err(e) = fs::remove_file(config_file) {
        return Err(SigilError::Flash(format!(
            "Fallo crítico borrando archivo de configuración privada de un solo uso: {}",
            e
        )));
    }

    // 4. Rechazar discos del sistema (control independiente del de la GUI)
    validate_target_not_system_disk(dest_device.to_str().unwrap_or_default())?;

    // 5. Validar el par bundle/payload contra la imagen seleccionada
    let pair = pair_from_artifacts(offline_packages, payload_dir)?;
    let image_name = src_image
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    validate_pair_against_image(&pair, image_name)?;

    // Control independiente del de la GUI: el escritor privilegiado no confía
    // en que quien lo invocó ya lo comprobara.
    validate_ssh_profile_available(&pair, config.ssh_enabled)?;
    if let Some(model) = &config.rpi_model {
        validate_model_supports_architecture(model, &pair.architecture)?;
    }

    // 6. Lock exclusivo por dispositivo
    let _lock_guard = LockFileGuard::acquire(dest_device)?;

    // 6.b Soltar el automontaje ANTES del primer byte. Escribir la imagen cruda
    // bajo un sistema de archivos montado deja al kernel con metadatos en caché
    // que ya no describen el disco: el FAT en memoria se vuelve incoherente
    // («fat_free_clusters: deleting FAT entry beyond EOF»), el kernel pone el
    // volumen en solo lectura y la fase de chroot muere con EROFS muy lejos de
    // la causa. Hacerlo después de escribir no sirve: el daño ya está hecho.
    release_foreign_mounts(dest_device);

    // 7. Tamaño total de la imagen ya descomprimida
    let is_xz = src_image.extension().and_then(|s| s.to_str()) == Some("xz");
    let total_bytes = if is_xz {
        get_xz_uncompressed_size(src_image)?
    } else {
        fs::metadata(src_image)?.len()
    };

    let p = tracker.update(0, total_bytes, "running", "Escribiendo imagen base en el dispositivo...");
    write_progress_file(progress_file, &p)?;

    let written_bytes =
        write_image_in_chunks(src_image, dest_device, total_bytes, is_xz, progress_file, &mut tracker)?;

    // 8. Conteo exacto
    if written_bytes != total_bytes {
        return Err(SigilError::Flash(format!(
            "Conteo de bytes escritos ({}) no coincide con el esperado ({})",
            written_bytes, total_bytes
        )));
    }

    // 9. Expandir el rootfs
    let p = tracker.update(written_bytes, total_bytes, "verifying", "Expandiendo partición de sistema...");
    write_progress_file(progress_file, &p)?;

    let root_part = PathBuf::from(get_partition_path(
        dest_device.to_str().unwrap_or_default(),
        2,
    ));
    expand_rootfs_partition(dest_device, &root_part)?;

    // 10. Verificar la expansión, no asumirla
    verify_expansion(dest_device, &root_part)?;

    // 11. Instalación y provisión dentro de la imagen
    let p = tracker.update(
        written_bytes,
        total_bytes,
        "verifying",
        "Instalando paquetes y personalizando el sistema (chroot)...",
    );
    write_progress_file(progress_file, &p)?;

    perform_chroot_installation(dest_device, &root_part, &pair, &config)?;

    let p = tracker.update(
        written_bytes,
        total_bytes,
        "done",
        "Flasheo, instalación y provisión completados exitosamente",
    );
    write_progress_file(progress_file, &p)?;

    Ok(())
}

/// Modo --configure-device: escribe en la partición BOOT de un dispositivo ya
/// flasheado la identidad de fabricación y los ajustes de arranque del modelo,
/// sin volver a escribir la imagen entera.
pub fn execute_configure_device(device: &Path, config_file: &Path) -> Result<()> {
    let config = read_and_verify_private_config(config_file)?;
    validate_device_config(&config)?;

    if let Err(e) = fs::remove_file(config_file) {
        return Err(SigilError::Flash(format!(
            "Fallo crítico borrando archivo de configuración privada de un solo uso: {}",
            e
        )));
    }

    validate_target_not_system_disk(device.to_str().unwrap_or_default())?;

    let boot_part = PathBuf::from(get_partition_path(device.to_str().unwrap_or_default(), 1));
    let mount_point = PathBuf::from("/run/sigil-flash/boot");
    if mount_point.exists() {
        let _ = Command::new("umount").arg(&mount_point).status();
    }
    fs::create_dir_all(&mount_point)?;

    let status = Command::new("mount").arg(&boot_part).arg(&mount_point).status()?;
    if !status.success() {
        return Err(SigilError::Flash(format!(
            "No se pudo montar la partición de arranque '{}'. \
             Verifique que la tarjeta esté insertada y ya flasheada.",
            boot_part.display()
        )));
    }

    let mut stack = MountStack::new(mount_point.clone());
    stack.push(mount_point.clone());

    let outcome = (|| -> Result<()> {
        write_identity_document(&mount_point, &config)?;
        if let Some(model) = &config.rpi_model {
            let config_txt = mount_point.join("config.txt");
            // Este modo reconfigura una tarjeta ya escrita y no conoce el par
            // bundle/imagen, así que la arquitectura se deduce de la propia
            // tarjeta en vez de suponerla por el modelo.
            let architecture = architecture_from_boot_config(&config_txt, model)?;
            apply_boot_tuning(&config_txt, model, &architecture)?;
            require_kernel_for_board(&mount_point, model, &architecture)?;
        }
        Ok(())
    })();

    let failures = stack.unmount_all();
    let _ = Command::new("sync").status();
    outcome?;

    if !failures.is_empty() {
        return Err(SigilError::Flash(format!(
            "La configuración se escribió pero no se pudo desmontar: {}",
            failures.join(", ")
        )));
    }

    info!("Configuración aplicada en la partición de arranque de {}", device.display());
    Ok(())
}

/// Reconstruye el par a partir de las rutas recibidas por argv y comprueba que
/// bundle y payload declaren la misma imagen y arquitectura. El proceso
/// elevado no confía en lo que la GUI le pasó.
fn pair_from_artifacts(offline_packages: &Path, payload_dir: &Path) -> Result<BundlePair> {
    let contract_path = payload_dir.join("manifests/offline-package-contract.json");
    let contract: serde_json::Value = serde_json::from_str(&fs::read_to_string(&contract_path)?)?;

    let base_image_name = contract
        .get("base_image_name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            SigilError::Validation(format!(
                "El contrato embebido en el payload no declara base_image_name: '{}'",
                contract_path.display()
            ))
        })?
        .to_string();
    let architecture = contract
        .get("architecture")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            SigilError::Validation("El contrato embebido en el payload no declara architecture".to_string())
        })?
        .to_string();
    let base_image_sha256 = contract
        .get("base_image_sha256")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();

    let repo_manifest_path = offline_packages.join("package-manifest.json");
    let repo_manifest: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&repo_manifest_path)?)?;
    let repo_image = repo_manifest
        .get("base_image_name")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let repo_arch = repo_manifest
        .get("architecture")
        .and_then(|v| v.as_str())
        .unwrap_or_default();

    if repo_image != base_image_name || repo_arch != architecture {
        return Err(SigilError::Validation(format!(
            "El repositorio APT ({} / {}) no corresponde al payload ({} / {}). \
             Reconstruya ambos con ./scripts/build-all-bundles.sh.",
            repo_image, repo_arch, base_image_name, architecture
        )));
    }

    Ok(BundlePair {
        contract_name: "argv".to_string(),
        repo: offline_packages.to_path_buf(),
        payload: payload_dir.to_path_buf(),
        architecture,
        base_image_name,
        base_image_sha256,
    })
}

fn get_xz_uncompressed_size(xz_path: &Path) -> Result<u64> {
    let output = Command::new("xz")
        .args(["--robot", "-l"])
        .arg(xz_path)
        .output()?;

    if !output.status.success() {
        return Err(SigilError::Flash(format!(
            "Fallo xz --robot -l: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.first() == Some(&"totals") && parts.len() >= 5 {
            if let Ok(bytes) = parts[4].parse::<u64>() {
                return Ok(bytes);
            }
        }
    }

    Err(SigilError::Flash(
        "No se pudo parsear el tamaño descomprimido del archivo .xz".to_string(),
    ))
}

fn write_image_in_chunks(
    src_image: &Path,
    dest_device: &Path,
    total_bytes: u64,
    is_xz: bool,
    progress_file: &Path,
    tracker: &mut ProgressTracker,
) -> Result<u64> {
    let mut dest_file = OpenOptions::new().write(true).open(dest_device)?;

    let mut bytes_written: u64 = 0;
    let buffer_size = 4 * 1024 * 1024; // 4 MB

    if is_xz {
        let mut child = Command::new("xz")
            .args(["-d", "-c"])
            .arg(src_image)
            .stdout(Stdio::piped())
            .spawn()?;

        let mut stdout = child.stdout.take().ok_or_else(|| {
            SigilError::Flash("No se pudo obtener stdout del descompresor xz".to_string())
        })?;

        let mut buffer = vec![0u8; buffer_size];
        loop {
            let count = stdout.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            dest_file.write_all(&buffer[..count])?;
            bytes_written += count as u64;

            let p = tracker.update(bytes_written, total_bytes, "running", "Escribiendo imagen descomprimida...");
            let _ = write_progress_file(progress_file, &p);
        }

        // Aunque el conteo cuadre, un descompresor que falló invalida todo.
        let status = child.wait()?;
        if !status.success() {
            return Err(SigilError::Flash(
                "El descompresor xz terminó con código de error: la imagen escrita no es fiable".to_string(),
            ));
        }
    } else {
        let mut src_file = File::open(src_image)?;
        let mut buffer = vec![0u8; buffer_size];

        loop {
            let count = src_file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            dest_file.write_all(&buffer[..count])?;
            bytes_written += count as u64;

            let p = tracker.update(bytes_written, total_bytes, "running", "Escribiendo imagen raw...");
            let _ = write_progress_file(progress_file, &p);
        }
    }

    dest_file.sync_all()?;
    Ok(bytes_written)
}

/// Tipo MBR que debe llevar la partición raíz. `0x00` marca una entrada como
/// no usada: el kernel la salta al resolver `root=PARTUUID=...`, así que un
/// equipo con la raíz a cero no arranca aunque su sistema de archivos esté
/// perfecto. Expandir la partición puede dejar el byte de tipo en cero.
pub const ROOT_PARTITION_MBR_TYPE: &str = "0x83";

/// `true` si el tipo declarado identifica una partición Linux utilizable como
/// raíz. Se acepta cualquier grafía de 0x83 y se rechaza explícitamente la
/// entrada vacía o a cero, que es el modo de fallo real.
pub fn is_bootable_root_partition_type(part_type: &str) -> bool {
    let normalizado = part_type.trim().to_lowercase();
    let normalizado = normalizado.strip_prefix("0x").unwrap_or(&normalizado);
    matches!(normalizado.trim_start_matches('0'), "83")
}

/// Cuántos bloques del sistema de archivos caben ENTEROS en la partición. La
/// división trunca a propósito: una partición que no es múltiplo exacto del
/// tamaño de bloque deja una cola inservible, y redondear hacia arriba es
/// exactamente lo que produce un sistema de archivos que no monta.
pub fn blocks_that_fit(partition_bytes: u64, block_size: u64) -> Result<u64> {
    if block_size == 0 {
        return Err(SigilError::Flash(
            "dumpe2fs reportó un tamaño de bloque de cero".to_string(),
        ));
    }
    let blocks = partition_bytes / block_size;
    if blocks == 0 {
        return Err(SigilError::Flash(format!(
            "La partición raíz ({} bytes) no admite ni un bloque de {} bytes",
            partition_bytes, block_size
        )));
    }
    Ok(blocks)
}

/// Tamaño objetivo en bloques, medido contra la partición real y no contra lo
/// que resize2fs crea que mide el dispositivo.
fn rootfs_target_blocks(root_part: &Path) -> Result<u64> {
    let part_str = root_part.to_str().unwrap_or_default();
    let size_text = command_stdout(
        "lsblk",
        &["--bytes", "--noheadings", "--nodeps", "--output", "SIZE", part_str],
    )?;
    let partition_bytes: u64 = size_text.trim().parse().map_err(|_| {
        SigilError::Flash(format!(
            "lsblk no devolvió un tamaño usable para '{}': {:?}",
            part_str,
            size_text.trim()
        ))
    })?;

    let dumpe2fs = Command::new("dumpe2fs").args(["-h"]).arg(root_part).output()?;
    let block_size = parse_dumpe2fs_field(&String::from_utf8_lossy(&dumpe2fs.stdout), "Block size:")
        .ok_or_else(|| {
            SigilError::Flash("dumpe2fs no reportó 'Block size' antes de redimensionar".to_string())
        })?;

    let blocks = blocks_that_fit(partition_bytes, block_size)?;
    info!(
        "Partición raíz de {} bytes: {} bloques de {} bytes caben enteros",
        partition_bytes, blocks, block_size
    );
    Ok(blocks)
}

fn expand_rootfs_partition(device: &Path, root_part: &Path) -> Result<()> {
    let _ = Command::new("partprobe").arg(device).status();
    let _ = Command::new("udevadm").args(["settle", "--timeout=30"]).status();

    let grow = Command::new("growpart").arg(device).arg("2").output();
    let grow_ok = match &grow {
        Ok(out) => is_growpart_result_acceptable(
            out.status.code().unwrap_or(-1),
            &String::from_utf8_lossy(&out.stdout),
            &String::from_utf8_lossy(&out.stderr),
        ),
        Err(_) => false,
    };

    if !grow_ok {
        warn!("growpart no pudo expandir la partición; probando con parted");
        let parted = Command::new("parted")
            .args(["-s"])
            .arg(device)
            .args(["resizepart", "2", "100%"])
            .status()?;
        if !parted.success() {
            return Err(SigilError::Flash(
                "No se pudo expandir la partición raíz ni con growpart ni con parted".to_string(),
            ));
        }
    }

    let _ = Command::new("partprobe").arg(device).status();
    let _ = Command::new("udevadm").args(["settle", "--timeout=30"]).status();

    let e2fsck = Command::new("e2fsck").args(["-f", "-p"]).arg(root_part).status()?;
    let code = e2fsck.code().unwrap_or(-1);
    if !is_e2fsck_exit_acceptable(code) {
        return Err(SigilError::Flash(format!(
            "e2fsck devolvió el código {} sobre '{}': el sistema de archivos tiene errores no corregibles automáticamente",
            code,
            root_part.display()
        )));
    }

    // resize2fs sin tamaño pregunta al kernel cuánto mide el dispositivo, y esa
    // respuesta puede estar obsoleta: `partprobe` falla en silencio si algo
    // tiene el disco ocupado, y growpart y parted no coinciden en dónde acaba
    // la última partición —parted descuenta 33 sectores para un GPT secundario
    // aunque la tabla sea MBR—. Sobrevivir a eso significa no preguntar: se
    // calcula el número de bloques desde el tamaño real de la partición y se le
    // pasa a resize2fs. Un sistema de archivos mayor que su partición no monta.
    let target_blocks = rootfs_target_blocks(root_part)?;
    let resize = Command::new("resize2fs")
        .arg(root_part)
        .arg(target_blocks.to_string())
        .status()?;
    if !resize.success() {
        return Err(SigilError::Flash(format!(
            "resize2fs falló al expandir el sistema de archivos a {} bloques",
            target_blocks
        )));
    }

    // Expandir la partición puede dejar su byte de tipo MBR en cero. Con la
    // entrada marcada como no usada, el kernel no resuelve
    // `root=PARTUUID=...` y el equipo no arranca, con la raíz intacta y sin
    // ningún error durante la fabricación. Se comprueba y se corrige.
    ensure_root_partition_type(device, root_part)?;

    let _ = Command::new("sync").status();
    Ok(())
}

/// Devuelve el tipo MBR de la partición según lo ve el kernel.
fn root_partition_type(root_part: &Path) -> Result<String> {
    let part_str = root_part.to_str().unwrap_or_default();
    Ok(
        command_stdout("lsblk", &["--noheadings", "--nodeps", "--output", "PARTTYPE", part_str])?
            .trim()
            .to_string(),
    )
}

fn ensure_root_partition_type(device: &Path, root_part: &Path) -> Result<()> {
    let actual = root_partition_type(root_part)?;
    if is_bootable_root_partition_type(&actual) {
        return Ok(());
    }

    warn!(
        "La partición raíz quedó con el tipo MBR '{}' tras expandirla; se restaura a {}",
        actual, ROOT_PARTITION_MBR_TYPE
    );
    let fixed = Command::new("sfdisk")
        .args(["--part-type"])
        .arg(device)
        .args(["2", ROOT_PARTITION_MBR_TYPE])
        .status()?;
    if !fixed.success() {
        return Err(SigilError::Flash(format!(
            "La partición raíz tiene el tipo MBR '{}' en vez de {} y no se pudo corregir. \
             Con la entrada marcada como no usada el kernel no resolverá root=PARTUUID \
             y el equipo no arrancará.",
            actual, ROOT_PARTITION_MBR_TYPE
        )));
    }

    let _ = Command::new("partprobe").arg(device).status();
    let _ = Command::new("udevadm").args(["settle", "--timeout=30"]).status();

    let after = root_partition_type(root_part)?;
    if !is_bootable_root_partition_type(&after) {
        return Err(SigilError::Flash(format!(
            "Se intentó restaurar el tipo de la partición raíz a {} pero sigue siendo '{}'. \
             El equipo no arrancaría.",
            ROOT_PARTITION_MBR_TYPE, after
        )));
    }
    info!("Tipo MBR de la partición raíz verificado: {}", after);
    Ok(())
}

fn command_stdout(program: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(program).args(args).output()?;
    if !out.status.success() {
        return Err(SigilError::Flash(format!(
            "'{}' falló: {}",
            program,
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Comprueba con tres fuentes independientes que la partición y el sistema de
/// archivos ocupan realmente el dispositivo.
fn verify_expansion(device: &Path, root_part: &Path) -> Result<()> {
    let device_str = device.to_str().unwrap_or_default();
    let part_str = root_part.to_str().unwrap_or_default();

    let device_size: u64 = command_stdout("blockdev", &["--getsize64", device_str])?
        .parse()
        .map_err(|_| SigilError::Flash("No se pudo leer el tamaño del dispositivo".to_string()))?;
    let sector_size: u64 = command_stdout("blockdev", &["--getss", device_str])?
        .parse()
        .unwrap_or(512);

    let lsblk = command_stdout(
        "lsblk",
        &["--bytes", "--noheadings", "--output", "START,SIZE", part_str],
    )?;
    let mut fields = lsblk.split_whitespace();
    let start_sectors: u64 = fields
        .next()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| SigilError::Flash("lsblk no devolvió el inicio de la partición".to_string()))?;
    let part_size: u64 = fields
        .next()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| SigilError::Flash("lsblk no devolvió el tamaño de la partición".to_string()))?;

    let dumpe2fs = Command::new("dumpe2fs").args(["-h"]).arg(root_part).output()?;
    let dump_text = String::from_utf8_lossy(&dumpe2fs.stdout);
    let block_count = parse_dumpe2fs_field(&dump_text, "Block count:")
        .ok_or_else(|| SigilError::Flash("dumpe2fs no reportó 'Block count'".to_string()))?;
    let block_size = parse_dumpe2fs_field(&dump_text, "Block size:")
        .ok_or_else(|| SigilError::Flash("dumpe2fs no reportó 'Block size'".to_string()))?;

    validate_expansion_within_tolerance(
        device_size,
        start_sectors * sector_size,
        part_size,
        block_count * block_size,
    )?;

    info!("Expansión verificada: partición {} bytes, sistema de archivos {} bytes", part_size, block_count * block_size);
    Ok(())
}

pub fn parse_dumpe2fs_field(text: &str, key: &str) -> Option<u64> {
    text.lines()
        .find(|l| l.trim_start().starts_with(key))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|v| v.trim().parse::<u64>().ok())
}

/// Punto de montaje con desmontaje en orden inverso y reporte de fallos.
struct MountStack {
    mounts: Vec<PathBuf>,
    root: PathBuf,
}

impl MountStack {
    fn new(root: PathBuf) -> Self {
        Self { mounts: Vec::new(), root }
    }

    fn push(&mut self, path: PathBuf) {
        self.mounts.push(path);
    }

    fn unmount_all(&mut self) -> Vec<String> {
        let mut failures = Vec::new();
        while let Some(path) = self.mounts.pop() {
            let status = Command::new("umount").arg(&path).status();
            let ok = status.map(|s| s.success()).unwrap_or(false);
            if !ok {
                // Un desmontaje perezoso evita dejar el dispositivo ocupado,
                // pero el fallo se reporta igualmente: no se ignora.
                let _ = Command::new("umount").arg("-l").arg(&path).status();
                failures.push(path.display().to_string());
            }
        }
        failures
    }
}

impl Drop for MountStack {
    fn drop(&mut self) {
        let failures = self.unmount_all();
        for f in &failures {
            warn!("Desmontaje fallido durante la limpieza: {}", f);
        }
        let _ = fs::remove_dir(&self.root);
    }
}

/// Raíz de los montajes propios del flasher. Todo lo que cuelgue de aquí es
/// nuestro; cualquier otro montaje del dispositivo es ajeno.
const OWN_MOUNT_ROOT: &str = "/run/sigil-flash";

/// Deshace el escape que `/proc/mounts` aplica a los caracteres especiales.
fn unescape_mount_field(field: &str) -> String {
    field
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

/// Puntos de montaje del dispositivo que pertenecen a otro: en la práctica, el
/// automontador del escritorio. udisks se queda con la tarjeta en cuanto el
/// kernel relee la tabla de particiones recién escrita, y la monta `ro` si el
/// sistema de archivos viene sucio. Como un dispositivo de bloque tiene un solo
/// superbloque, el montaje del flasher hereda ese `ro` y la escritura muere
/// después con EROFS, señalando a un punto de montaje que no es el culpable.
pub fn foreign_mount_points(mounts: &str, device: &str, own_root: &str) -> Vec<String> {
    mounts
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let source = unescape_mount_field(fields.next()?);
            let target = unescape_mount_field(fields.next()?);
            // El propio dispositivo y sus particiones: /dev/sdb, /dev/sdb1…
            if !source.starts_with(device) {
                return None;
            }
            if target == own_root || target.starts_with(&format!("{}/", own_root)) {
                return None;
            }
            Some(target)
        })
        .collect()
}

/// `true` si el punto de montaje está montado de lectura y escritura. `mount`
/// sale con código 0 cuando cae a solo lectura —solo imprime un aviso—, así que
/// su estado de salida no sirve para saberlo.
pub fn mount_is_read_write(mounts: &str, target: &str) -> bool {
    mounts
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let _source = fields.next()?;
            let mount_target = unescape_mount_field(fields.next()?);
            let _fstype = fields.next()?;
            let options = fields.next()?;
            (mount_target == target).then(|| options.to_string())
        })
        .next_back()
        .map(|options| !options.split(',').any(|o| o == "ro"))
        .unwrap_or(false)
}

/// Suelta los montajes ajenos del dispositivo antes de tocarlo. Sin esto, el
/// flasher hereda las opciones con las que el escritorio montó la tarjeta.
fn release_foreign_mounts(device: &Path) {
    let device = device.to_string_lossy().to_string();
    let mounts = fs::read_to_string("/proc/mounts").unwrap_or_default();
    for target in foreign_mount_points(&mounts, &device, OWN_MOUNT_ROOT) {
        info!("Soltando montaje ajeno del dispositivo: {}", target);
        let released = Command::new("umount")
            .arg(&target)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !released {
            // Perezoso: el automontador puede tener el descriptor abierto sin
            // estar escribiendo. El superbloque se libera igual.
            let _ = Command::new("umount").arg("-l").arg(&target).status();
        }
    }
}

/// Falla si el punto de montaje quedó en solo lectura. Se comprueba después de
/// cada montaje porque el fallback de `mount` es silencioso para el código de
/// salida y ruidoso solo en stderr.
fn require_read_write(mount_point: &Path, what: &str) -> Result<()> {
    let mounts = fs::read_to_string("/proc/mounts").unwrap_or_default();
    if mount_is_read_write(&mounts, &mount_point.to_string_lossy()) {
        return Ok(());
    }
    Err(SigilError::Flash(format!(
        "La partición {} quedó montada en SOLO LECTURA en '{}'. Suele significar que el \
         sistema de archivos viene sucio de un intento anterior y el kernel se niega a \
         montarlo de escritura. Extraiga la tarjeta, vuelva a insertarla y repita; si \
         persiste, revise la tarjeta con fsck.",
        what,
        mount_point.display()
    )))
}

fn perform_chroot_installation(
    device: &Path,
    root_part: &Path,
    pair: &BundlePair,
    config: &DeviceConfig,
) -> Result<()> {
    let target_mount = PathBuf::from("/run/sigil-flash/rootfs");
    if target_mount.exists() {
        let _ = Command::new("umount").args(["-R"]).arg(&target_mount).status();
    }
    fs::create_dir_all(&target_mount)?;

    // Antes de montar nada: el escritorio ya se quedó con la tarjeta en cuanto
    // el kernel releyó la tabla de particiones recién escrita.
    release_foreign_mounts(device);

    // El kernel tarda en releer una tabla de particiones recién escrita.
    let mut mounted = false;
    for attempt in 1..=10 {
        if Command::new("mount")
            .arg(root_part)
            .arg(&target_mount)
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
        {
            mounted = true;
            break;
        }
        let _ = Command::new("sync").status();
        let _ = Command::new("partprobe").arg(device).status();
        info!("Reintento {}/10 de montaje de la partición raíz...", attempt);
        thread::sleep(Duration::from_secs(2));
    }

    if !mounted {
        return Err(SigilError::Flash(format!(
            "No se pudo montar la partición raíz '{}' tras 10 intentos. \
             Extraiga y vuelva a insertar la tarjeta, o repita la fabricación.",
            root_part.display()
        )));
    }

    let mut stack = MountStack::new(target_mount.clone());
    stack.push(target_mount.clone());

    // La raíz montada en solo lectura deja pasar toda la copia del payload y
    // revienta más tarde, lejos de la causa.
    require_read_write(&target_mount, "raíz")?;

    let result = install_into_mounted_rootfs(&target_mount, root_part, device, pair, config, &mut stack);

    let failures = stack.unmount_all();
    let _ = Command::new("sync").status();

    result?;

    if !failures.is_empty() {
        return Err(SigilError::Flash(format!(
            "La instalación terminó pero no se pudieron desmontar: {}. \
             Ejecute 'sync' y espere antes de extraer la tarjeta.",
            failures.join(", ")
        )));
    }

    info!("Instalación y personalización en chroot completadas");
    Ok(())
}

fn install_into_mounted_rootfs(
    target_mount: &Path,
    root_part: &Path,
    device: &Path,
    pair: &BundlePair,
    config: &DeviceConfig,
    stack: &mut MountStack,
) -> Result<()> {
    // RED DE SEGURIDAD MULTIARQUITECTURA: la arquitectura real del rootfs
    // manda sobre cualquier heurística de selección previa.
    let real_arch = detect_rootfs_architecture(target_mount)?;
    if real_arch != pair.architecture {
        return Err(SigilError::Flash(format!(
            "ABORTADO: la imagen escrita es de arquitectura '{}' pero el bundle seleccionado es '{}'. \
             Seleccione la imagen que declara el contrato ('{}') o construya el bundle de '{}'.",
            real_arch, pair.architecture, pair.base_image_name, real_arch
        )));
    }
    info!("Arquitectura ELF del rootfs verificada contra el bundle: {}", real_arch);

    // Payload validado ANTES de copiar.
    verify_payload_manifest(&pair.payload)?;

    let staging = target_mount.join(PAYLOAD_STAGING_DIR);
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    fs::create_dir_all(&staging)?;

    let cp = Command::new("cp")
        .args(["-a"])
        .arg(format!("{}/.", pair.payload.display()))
        .arg(&staging)
        .status()?;
    if !cp.success() {
        return Err(SigilError::Flash(
            "Error copiando los archivos del payload dentro de la imagen".to_string(),
        ));
    }

    // cp -a NO preserva propietario si no se corre como root, y un payload con
    // dueños equivocados rompe el chroot de forma confusa.
    let chown = Command::new("chown").args(["-R", "root:root"]).arg(&staging).status()?;
    if !chown.success() {
        return Err(SigilError::Flash(
            "No se pudo forzar root:root sobre el payload copiado".to_string(),
        ));
    }
    restore_payload_modes(&staging)?;

    // Payload validado DESPUÉS de copiar.
    verify_payload_manifest(&staging)?;

    // Repositorio APT dentro de la imagen.
    let target_repo = target_mount.join(OFFLINE_REPO_DIR);
    fs::create_dir_all(&target_repo)?;
    let cp_repo = Command::new("cp")
        .args(["-a"])
        .arg(format!("{}/.", pair.repo.display()))
        .arg(&target_repo)
        .status()?;
    if !cp_repo.success() {
        return Err(SigilError::Flash(
            "Error copiando el repositorio APT offline a la imagen".to_string(),
        ));
    }

    // Partición de arranque montada DENTRO del rootfs montado.
    let boot_part = PathBuf::from(get_partition_path(device.to_str().unwrap_or_default(), 1));
    let boot_mount = if target_mount.join("boot/firmware").is_dir() {
        target_mount.join("boot/firmware")
    } else {
        target_mount.join("boot")
    };
    fs::create_dir_all(&boot_mount)?;
    // El automontador puede haber vuelto a por la partición de arranque entre
    // el montaje de la raíz y este.
    release_foreign_mounts(device);
    let boot_status = Command::new("mount").arg(&boot_part).arg(&boot_mount).status()?;
    if !boot_status.success() {
        return Err(SigilError::Flash(format!(
            "No se pudo montar la partición de arranque '{}'",
            boot_part.display()
        )));
    }
    stack.push(boot_mount.clone());
    require_read_write(&boot_mount, "de arranque")?;

    // En cuanto la partición de arranque es legible: si la imagen no trae el
    // kernel que esta placa necesita, abortar aquí ahorra la media hora del
    // chroot. La imagen armhf oficial, por ejemplo, no incluye kernel7l.img y
    // por tanto no arranca una Pi 4, 400 ni CM4.
    if let Some(model) = &config.rpi_model {
        require_kernel_for_board(&boot_mount, model, &pair.architecture)?;
    }

    // Identidad de fabricación: lleva el serial, nunca secretos.
    write_identity_document(&boot_mount, config)?;

    // Bind mounts del entorno de ejecución del chroot.
    for (source, kind, rel) in [
        ("/dev", "bind", "dev"),
        ("proc", "proc", "proc"),
        ("sysfs", "sysfs", "sys"),
    ] {
        let mount_point = target_mount.join(rel);
        fs::create_dir_all(&mount_point)?;
        let status = if kind == "bind" {
            Command::new("mount").args(["--bind", source]).arg(&mount_point).status()?
        } else {
            Command::new("mount").args(["-t", kind, source]).arg(&mount_point).status()?
        };
        if !status.success() {
            return Err(SigilError::Flash(format!(
                "No se pudo montar '{}' dentro de la imagen",
                rel
            )));
        }
        stack.push(mount_point);
    }

    let _policy = PolicyRcGuard::install(target_mount)?;
    let _qemu = QemuGuard::install(target_mount, &pair.architecture)?;

    // Instalador de sigil-hardware dentro del chroot.
    let installer_rel = format!("/{}/install.sh", PAYLOAD_STAGING_DIR);
    if !target_mount.join(PAYLOAD_STAGING_DIR).join("install.sh").is_file() {
        return Err(SigilError::Flash(format!(
            "El instalador no quedó en la imagen: falta '{}'",
            installer_rel
        )));
    }

    let mut chroot_cmd = Command::new("chroot");
    chroot_cmd
        .arg(target_mount)
        .args(["bash", &installer_rel, "--offline-repo", &format!("/{}", OFFLINE_REPO_DIR)])
        .env("SIGIL_IMAGE_PREPARATION", "1")
        .env("DEBIAN_FRONTEND", "noninteractive");

    if config.ssh_enabled {
        chroot_cmd.env("SIGIL_PACKAGE_PROFILES", "factory-debug");
    } else {
        // Eliminarla explícitamente: heredarla activaría paquetes de
        // diagnóstico en un equipo de cliente.
        chroot_cmd.env_remove("SIGIL_PACKAGE_PROFILES");
    }

    let install_status = chroot_cmd.status()?;
    if !install_status.success() {
        return Err(SigilError::Flash(
            "El instalador de sigil-hardware falló dentro del chroot. \
             Revise el log de la aplicación para ver su salida completa."
                .to_string(),
        ));
    }

    // ── Fase 7: provisión posterior al instalador ────────────────────────────
    // El hostname del operario se aplica DESPUÉS: el instalador fija el suyo
    // canónico y pisaría este valor si se escribiera antes.
    fs::write(target_mount.join("etc/hostname"), format!("{}\n", config.hostname))?;
    update_hosts_file(target_mount, &config.hostname)?;

    if let Some(server_url) = &config.server_url {
        rewrite_server_url(target_mount, server_url)?;
    }

    if let Some(pin) = &config.panel_pin {
        provision_panel_pin(target_mount, pin)?;
    }

    write_wifi_profile(target_mount, config)?;
    provision_remote_access(target_mount, config)?;

    if let Some(enrollment_key) = &config.api_key {
        write_enrollment_key(target_mount, enrollment_key)?;
    }

    if let Some(model) = &config.rpi_model {
        apply_boot_tuning(&boot_mount.join("config.txt"), model, &pair.architecture)?;
    }

    // El servicio de primer arranque es crítico: dentro de un chroot sin
    // systemd activo, `systemctl enable` puede fallar en silencio.
    reaffirm_firstboot_service(target_mount)?;

    let _ = Command::new("sync").status();
    let _ = root_part; // el desmontaje lo gestiona MountStack
    Ok(())
}

fn update_hosts_file(rootfs: &Path, hostname: &str) -> Result<()> {
    let hosts_path = rootfs.join("etc/hosts");
    if !hosts_path.is_file() {
        return Ok(());
    }
    let text = fs::read_to_string(&hosts_path)?;
    let updated: Vec<String> = text
        .lines()
        .map(|line| {
            if line.starts_with("127.0.1.1") {
                format!("127.0.1.1\t{}", hostname)
            } else {
                line.to_string()
            }
        })
        .collect();
    fs::write(&hosts_path, format!("{}\n", updated.join("\n")))?;
    Ok(())
}

fn reaffirm_firstboot_service(rootfs: &Path) -> Result<()> {
    let unit_rel = "etc/systemd/system/sigil-firstboot.service";
    if !rootfs.join(unit_rel).is_file() {
        return Err(SigilError::Flash(
            "La unidad sigil-firstboot.service no existe en la imagen preparada. \
             El equipo nunca se enrolaría: aborte y regenere el payload."
                .to_string(),
        ));
    }

    let wants_dir = rootfs.join("etc/systemd/system/multi-user.target.wants");
    fs::create_dir_all(&wants_dir)?;
    let link = wants_dir.join("sigil-firstboot.service");
    let _ = fs::remove_file(&link);
    std::os::unix::fs::symlink("/etc/systemd/system/sigil-firstboot.service", &link)?;

    if fs::symlink_metadata(&link).is_err() {
        return Err(SigilError::Flash(
            "No se pudo habilitar sigil-firstboot.service en la imagen".to_string(),
        ));
    }
    info!("Servicio de primer arranque habilitado explícitamente");
    Ok(())
}

/// policy-rc.d con "exit 101" para que ningún demonio arranque en el chroot.
/// Respalda el previo si existía y lo restaura al terminar.
struct PolicyRcGuard {
    path: PathBuf,
    backup: Option<PathBuf>,
}

impl PolicyRcGuard {
    fn install(rootfs: &Path) -> Result<Self> {
        let path = rootfs.join("usr/sbin/policy-rc.d");
        fs::create_dir_all(path.parent().unwrap())?;

        let backup = if path.exists() {
            let backup = rootfs.join("usr/sbin/policy-rc.d.sigil-backup");
            fs::rename(&path, &backup)?;
            Some(backup)
        } else {
            None
        };

        fs::write(&path, "#!/bin/sh\nexit 101\n")?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
        Ok(Self { path, backup })
    }
}

impl Drop for PolicyRcGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
        if let Some(backup) = &self.backup {
            let _ = fs::rename(backup, &self.path);
        }
    }
}

/// Intérprete qemu para preparar imágenes de otra arquitectura. Solo se borra
/// al terminar si fue este proceso quien lo copió.
struct QemuGuard {
    installed_path: Option<PathBuf>,
}

impl QemuGuard {
    fn install(rootfs: &Path, target_arch: &str) -> Result<Self> {
        let host_arch = match std::env::consts::ARCH {
            "aarch64" => "arm64",
            "arm" => "armhf",
            other => other,
        };
        if host_arch == target_arch {
            return Ok(Self { installed_path: None });
        }

        let interpreter = find_qemu_interpreter(target_arch)?;
        let file_name = interpreter.file_name().unwrap();
        let destination = rootfs.join("usr/bin").join(file_name);

        if destination.exists() {
            return Ok(Self { installed_path: None });
        }

        fs::create_dir_all(destination.parent().unwrap())?;
        fs::copy(&interpreter, &destination)?;
        fs::set_permissions(&destination, fs::Permissions::from_mode(0o755))?;
        info!("Intérprete {} copiado a la imagen para el chroot cruzado", file_name.to_string_lossy());

        Ok(Self { installed_path: Some(destination) })
    }
}

impl Drop for QemuGuard {
    fn drop(&mut self) {
        if let Some(path) = &self.installed_path {
            let _ = fs::remove_file(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    /// El montaje real que rompió la fabricación: udisks se quedó con la
    /// partición de arranque en `ro` y el flasher heredó el superbloque.
    const PROC_MOUNTS_CON_AUTOMONTAJE: &str = "\
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
/dev/nvme0n1p3 / ext4 rw,relatime 0 0
/dev/sdb1 /run/media/vic/bootfs vfat ro,nosuid,nodev,relatime,uid=1000 0 0
/dev/sdb2 /run/sigil-flash/rootfs ext4 rw,relatime 0 0
";

    #[test]
    fn test_the_desktop_automount_is_detected_as_foreign() {
        let ajenos = foreign_mount_points(PROC_MOUNTS_CON_AUTOMONTAJE, "/dev/sdb", OWN_MOUNT_ROOT);
        assert_eq!(ajenos, vec!["/run/media/vic/bootfs".to_string()]);
    }

    #[test]
    fn test_our_own_mounts_are_never_released() {
        let ajenos = foreign_mount_points(PROC_MOUNTS_CON_AUTOMONTAJE, "/dev/sdb", OWN_MOUNT_ROOT);
        assert!(
            !ajenos.iter().any(|m| m.starts_with(OWN_MOUNT_ROOT)),
            "desmontar lo nuestro aborta la fabricación en curso: {:?}",
            ajenos
        );
    }

    #[test]
    fn test_other_devices_are_left_alone() {
        let ajenos = foreign_mount_points(PROC_MOUNTS_CON_AUTOMONTAJE, "/dev/sdb", OWN_MOUNT_ROOT);
        assert!(
            !ajenos.iter().any(|m| m == "/"),
            "el disco del sistema no se toca: {:?}",
            ajenos
        );
    }

    #[test]
    fn test_mount_points_with_escaped_spaces_are_resolved() {
        let mounts = "/dev/sdb1 /run/media/vic/SIN\\040NOMBRE vfat ro 0 0\n";
        assert_eq!(
            foreign_mount_points(mounts, "/dev/sdb", OWN_MOUNT_ROOT),
            vec!["/run/media/vic/SIN NOMBRE".to_string()]
        );
    }

    /// `mount` sale con 0 cuando cae a solo lectura, así que el estado real hay
    /// que leerlo de `/proc/mounts` o la escritura muere después con EROFS.
    #[test]
    fn test_read_only_mount_is_not_mistaken_for_writable() {
        assert!(!mount_is_read_write(
            PROC_MOUNTS_CON_AUTOMONTAJE,
            "/run/media/vic/bootfs"
        ));
        assert!(mount_is_read_write(
            PROC_MOUNTS_CON_AUTOMONTAJE,
            "/run/sigil-flash/rootfs"
        ));
    }

    #[test]
    fn test_an_unmounted_path_is_not_writable() {
        assert!(!mount_is_read_write(
            PROC_MOUNTS_CON_AUTOMONTAJE,
            "/run/sigil-flash/rootfs/boot/firmware"
        ));
    }

    /// `remount` apila líneas para el mismo punto: manda la última.
    #[test]
    fn test_the_latest_mount_of_a_path_wins() {
        let mounts = "\
/dev/sdb1 /mnt vfat rw,relatime 0 0
/dev/sdb1 /mnt vfat ro,relatime 0 0
";
        assert!(!mount_is_read_write(mounts, "/mnt"));
    }

    /// 'ro' es una opción entera, no una subcadena: `errors=remount-ro` y
    /// `rootcontext=…` no significan solo lectura.
    #[test]
    fn test_ro_is_matched_as_a_whole_option() {
        let mounts = "/dev/sdb2 /mnt ext4 rw,relatime,errors=remount-ro 0 0\n";
        assert!(mount_is_read_write(mounts, "/mnt"));
    }

    #[test]
    /// La partición real de la tarjeta que no arrancó: 29470687 sectores no es
    /// múltiplo de 8, así que el último bloque de 4 KiB queda incompleto.
    /// Redondear hacia arriba es justo lo que produjo el sistema de archivos
    /// inmontable; truncar es la única respuesta correcta.
    /// El modo de fallo real: la entrada MBR de la raíz quedó con el byte de
    /// tipo a cero tras expandir la partición. El kernel salta las entradas
    /// vacías al resolver `root=PARTUUID=...`, así que el equipo no arranca
    /// aunque el sistema de archivos esté sano. `lsblk` lo reporta vacío.
    #[test]
    fn test_a_zeroed_partition_type_is_not_bootable() {
        for vacio in ["", "  ", "0x00", "0x0", "0"] {
            assert!(
                !is_bootable_root_partition_type(vacio),
                "una entrada no usada no arranca: {:?}",
                vacio
            );
        }
    }

    #[test]
    fn test_the_linux_type_is_accepted_in_any_spelling() {
        for bueno in ["0x83", "0X83", "83", " 0x83 "] {
            assert!(is_bootable_root_partition_type(bueno), "{:?}", bueno);
        }
    }

    /// El tipo de la partición de arranque no vale para la raíz.
    #[test]
    fn test_other_partition_types_are_rejected() {
        // 'lsblk --output PARTTYPE' imprime la de arranque como '0xc', sin el
        // cero de relleno: la normalización no puede confundirla con 0x83.
        for otro in ["0xc", "0x0c", "0x82", "0xee", "linux"] {
            assert!(!is_bootable_root_partition_type(otro), "{:?}", otro);
        }
    }

    #[test]
    fn test_a_partial_trailing_block_is_dropped_not_rounded_up() {
        let partition_bytes = 29_470_687u64 * 512;
        assert_eq!(blocks_that_fit(partition_bytes, 4096).unwrap(), 3_683_835);
        // 3683840 fue lo que se escribió en el superbloque; 5 bloques de más.
        assert!(blocks_that_fit(partition_bytes, 4096).unwrap() < 3_683_840);
    }

    #[test]
    fn test_an_exact_partition_keeps_every_block() {
        assert_eq!(blocks_that_fit(4096 * 1000, 4096).unwrap(), 1000);
    }

    #[test]
    fn test_absurd_geometry_fails_instead_of_dividing_by_zero() {
        assert!(blocks_that_fit(4096, 0).is_err());
        let err = blocks_that_fit(1024, 4096).unwrap_err();
        assert!(err.to_string().contains("ni un bloque"), "{}", err);
    }

    #[test]
    fn test_lock_claimed_from_dead_pid_and_rejected_from_live_pid() {
        // Un PID vivo bloquea; el propio proceso siempre está vivo.
        let err = lock_is_claimable(std::process::id() as i32, true).unwrap_err();
        assert!(err.to_string().contains("otro proceso"), "{}", err);

        // Un PID muerto deja reclamar el lock.
        assert!(lock_is_claimable(999_999, false).is_ok());
    }

    #[test]
    fn test_lock_guard_releases_only_its_own_pid() {
        let dir = tempdir().unwrap();
        let lock_path = dir.path().join("device.lock");
        fs::write(&lock_path, "999999\n").unwrap();

        {
            let _guard = LockFileGuard {
                lock_path: lock_path.clone(),
                pid: std::process::id(),
            };
            // El archivo contiene otro PID: la guarda no debe borrarlo.
        }
        assert!(lock_path.exists(), "no debe borrar un lock ajeno");

        fs::write(&lock_path, format!("{}\n", std::process::id())).unwrap();
        {
            let _guard = LockFileGuard {
                lock_path: lock_path.clone(),
                pid: std::process::id(),
            };
        }
        assert!(!lock_path.exists(), "debe borrar su propio lock");
    }

    #[test]
    fn test_dumpe2fs_parsing() {
        let text = "Filesystem volume name:   <none>\nBlock count:              7654321\nBlock size:               4096\n";
        assert_eq!(parse_dumpe2fs_field(text, "Block count:"), Some(7_654_321));
        assert_eq!(parse_dumpe2fs_field(text, "Block size:"), Some(4096));
        assert_eq!(parse_dumpe2fs_field(text, "Inode count:"), None);
    }

    #[test]
    fn test_private_config_rejects_insecure_modes() {
        let dir = tempdir().unwrap();
        let config_file = dir.path().join("config.json");
        fs::write(&config_file, "{}").unwrap();
        fs::set_permissions(&config_file, fs::Permissions::from_mode(0o644)).unwrap();

        let err = read_and_verify_private_config(&config_file).unwrap_err();
        assert!(err.to_string().contains("Permisos inseguros"), "{}", err);
    }

    #[test]
    fn test_private_config_rejects_oversized_file() {
        let dir = tempdir().unwrap();
        let config_file = dir.path().join("config.json");
        fs::write(&config_file, "x".repeat(16 * 1024 + 1)).unwrap();
        fs::set_permissions(&config_file, fs::Permissions::from_mode(0o600)).unwrap();

        let err = read_and_verify_private_config(&config_file).unwrap_err();
        assert!(err.to_string().contains("16 KiB"), "{}", err);
    }

    #[test]
    fn test_config_owner_rules() {
        // root leyendo un archivo del operario que autorizó pkexec: aceptado.
        assert!(config_owner_is_trusted(1000, 0, Some(1000)));
        // El propio usuario efectivo: aceptado.
        assert!(config_owner_is_trusted(0, 0, None));
        assert!(config_owner_is_trusted(1000, 1000, None));
        // Un tercero que plantó el archivo: rechazado.
        assert!(!config_owner_is_trusted(1001, 0, Some(1000)));
        assert!(!config_owner_is_trusted(1001, 0, None));
    }

    #[test]
    fn test_private_config_rejects_symlink() {
        let dir = tempdir().unwrap();
        let real = dir.path().join("real.json");
        fs::write(&real, "{}").unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o600)).unwrap();

        let link = dir.path().join("link.json");
        std::os::unix::fs::symlink(&real, &link).unwrap();

        let err = read_and_verify_private_config(&link).unwrap_err();
        assert!(err.to_string().contains("symlink"), "{}", err);
    }

    #[test]
    fn test_policy_rc_guard_backs_up_and_restores() {
        let dir = tempdir().unwrap();
        let rootfs = dir.path();
        let policy = rootfs.join("usr/sbin/policy-rc.d");
        fs::create_dir_all(policy.parent().unwrap()).unwrap();
        fs::write(&policy, "#!/bin/sh\nexit 0\n").unwrap();

        {
            let _guard = PolicyRcGuard::install(rootfs).unwrap();
            let content = fs::read_to_string(&policy).unwrap();
            assert!(content.contains("exit 101"));
            let mode = fs::metadata(&policy).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }

        let restored = fs::read_to_string(&policy).unwrap();
        assert_eq!(restored, "#!/bin/sh\nexit 0\n", "debe restaurar el policy-rc.d previo");
    }

    #[test]
    fn test_pair_from_artifacts_rejects_mismatched_repo() {
        let dir = tempdir().unwrap();
        let payload = dir.path().join("payload");
        let repo = dir.path().join("repo");
        fs::create_dir_all(payload.join("manifests")).unwrap();
        fs::create_dir_all(&repo).unwrap();

        fs::write(
            payload.join("manifests/offline-package-contract.json"),
            serde_json::json!({"base_image_name": "a-arm64.img.xz", "architecture": "arm64"}).to_string(),
        )
        .unwrap();
        fs::write(
            repo.join("package-manifest.json"),
            serde_json::json!({"base_image_name": "b-armhf.img.xz", "architecture": "armhf"}).to_string(),
        )
        .unwrap();

        let err = pair_from_artifacts(&repo, &payload).unwrap_err();
        assert!(err.to_string().contains("no corresponde"), "{}", err);
    }
}
