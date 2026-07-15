use crate::errors::{AppError, AppResult};
use crate::models::FlashProgress;
use sha2::{Digest, Sha256};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;

pub struct FlashService {
    // Stores the active child process spawn handle for cancellation
    active_process: Arc<Mutex<Option<tokio::process::Child>>>,
    // Serializes flash requests inside this application process.
    operation_lock: Arc<Mutex<()>>,
    offline_packages: PathBuf,
    package_contract: PathBuf,
}

const ELEVATED_LAUNCHER_GRACE: Duration = Duration::from_secs(2);
const DETACHED_WRITER_TIMEOUT: Duration = Duration::from_secs(45 * 60);

#[derive(Debug, PartialEq, Eq)]
enum FlashCompletion {
    Running,
    Succeeded,
    Failed(String),
}

fn completion_from_observation(
    progress: Option<&FlashProgress>,
    launcher_exit_success: Option<bool>,
    elapsed_since_launcher_exit: Option<Duration>,
) -> FlashCompletion {
    if let Some(progress) = progress {
        match progress.status.as_str() {
            "done" if launcher_exit_success.is_some() => return FlashCompletion::Succeeded,
            "error" | "cancelled" if launcher_exit_success.is_some() => {
                return FlashCompletion::Failed(progress.message.clone());
            }
            _ => {}
        }
    }

    let Some(elapsed) = elapsed_since_launcher_exit else {
        return FlashCompletion::Running;
    };
    if progress.is_none() && elapsed >= ELEVATED_LAUNCHER_GRACE {
        return FlashCompletion::Failed(match launcher_exit_success {
            Some(true) => "El proceso elevado terminó sin publicar un resultado".to_string(),
            _ => "La autorización administrativa fue cancelada o falló".to_string(),
        });
    }
    if elapsed >= DETACHED_WRITER_TIMEOUT {
        return FlashCompletion::Failed(
            "El escritor privilegiado no publicó un resultado final dentro del tiempo límite"
                .to_string(),
        );
    }
    FlashCompletion::Running
}

impl FlashService {
    pub fn new() -> Self {
        let flash_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        Self {
            active_process: Arc::new(Mutex::new(None)),
            operation_lock: Arc::new(Mutex::new(())),
            offline_packages: flash_root
                .join("artifacts")
                .join("offline-packages")
                .join("trixie-arm64"),
            package_contract: flash_root
                .join("sigil-hardware")
                .join("manifests")
                .join("offline-package-contract.json"),
        }
    }

    /// Spawns the elevated writer child process and polls its progress file.
    pub async fn start_flash(
        &self,
        image_path: &str,
        device_path: &str,
        app: AppHandle,
    ) -> AppResult<()> {
        let _operation_guard = self.operation_lock.try_lock().map_err(|_| {
            AppError::Flash(
                "Ya hay un flasheo en curso. Espera a que termine antes de iniciar otro."
                    .to_string(),
            )
        })?;

        let image_p = PathBuf::from(image_path);
        let device_p = PathBuf::from(device_path);

        if !image_p.exists() {
            return Err(AppError::Validation(
                "La ruta del archivo de imagen no existe".to_string(),
            ));
        }
        validate_bundle_for_image(&image_p, &self.offline_packages, &self.package_contract)?;

        // 1. Establish progress monitoring file in temp directory
        let progress_file = unique_progress_path();

        // Initialize progress state
        let image_size = std::fs::metadata(&image_p)?.len();
        let _ = app.emit(
            "flash-progress",
            FlashProgress {
                bytes_written: 0,
                total_bytes: image_size,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status: "running".to_string(),
                message: "Iniciando proceso de elevación de privilegios...".to_string(),
            },
        );

        // 2. Build command arguments
        let current_exe = std::env::current_exe()?;
        let flash_args = vec![
            "--flash-raw".to_string(),
            "--src".to_string(),
            image_p.to_string_lossy().to_string(),
            "--dest".to_string(),
            device_p.to_string_lossy().to_string(),
            "--progress-file".to_string(),
            progress_file.to_string_lossy().to_string(),
            "--offline-packages".to_string(),
            self.offline_packages.to_string_lossy().to_string(),
        ];

        // 3. Spawn elevated command depending on platform
        let child = spawn_elevated_process(&current_exe, &flash_args).await?;

        // Register the active child process for cancellation
        {
            let mut guard = self.active_process.lock().await;
            *guard = Some(child);
        }

        // 4. Poll progress file while the child process runs
        let start_time = Instant::now();
        let mut last_bytes = 0u64;
        let mut launcher_exit_success = None;
        let mut launcher_exited_at = None;
        let mut last_progress = None;
        let final_result;

        loop {
            if launcher_exit_success.is_none() {
                let mut guard = self.active_process.lock().await;
                if let Some(ref mut c) = *guard {
                    match c.try_wait() {
                        Ok(Some(status)) => {
                            launcher_exit_success = Some(status.success());
                            launcher_exited_at = Some(Instant::now());
                            *guard = None;
                        }
                        Ok(None) => {}
                        Err(error) => {
                            final_result = Err(AppError::Flash(format!(
                                "No se pudo consultar el proceso elevado: {error}"
                            )));
                            break;
                        }
                    }
                } else {
                    launcher_exit_success = Some(false);
                    launcher_exited_at = Some(Instant::now());
                }
            }

            if progress_file.exists() {
                if let Ok(content) = std::fs::read_to_string(&progress_file) {
                    if let Ok(progress) = serde_json::from_str::<FlashProgress>(&content) {
                        let elapsed = start_time.elapsed().as_secs_f64();
                        let current_bytes = progress.bytes_written;

                        let speed = if elapsed > 0.0 {
                            (current_bytes as f64 / elapsed) / (1024.0 * 1024.0)
                        } else {
                            0.0
                        };

                        let eta = if speed > 0.0 && image_size > current_bytes {
                            ((image_size - current_bytes) as f64) / (speed * 1024.0 * 1024.0)
                        } else {
                            0.0
                        };

                        last_bytes = current_bytes;
                        last_progress = Some(progress.clone());

                        let _ = app.emit(
                            "flash-progress",
                            FlashProgress {
                                bytes_written: current_bytes,
                                total_bytes: progress.total_bytes,
                                speed_mbps: speed,
                                eta_seconds: eta,
                                status: progress.status,
                                message: progress.message,
                            },
                        );
                    }
                }
            }

            let elapsed_since_launcher_exit = launcher_exited_at.map(|instant| instant.elapsed());
            match completion_from_observation(
                last_progress.as_ref(),
                launcher_exit_success,
                elapsed_since_launcher_exit,
            ) {
                FlashCompletion::Running => {}
                FlashCompletion::Succeeded => {
                    final_result = Ok(());
                    break;
                }
                FlashCompletion::Failed(message) => {
                    final_result = Err(AppError::Flash(message));
                    break;
                }
            }

            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        // Cleanup progress file
        if progress_file.exists() {
            let _ = std::fs::remove_file(&progress_file);
        }

        let final_total = last_progress
            .as_ref()
            .map_or(image_size, |progress| progress.total_bytes);
        match final_result {
            Ok(()) => {
                let _ = app.emit(
                    "flash-progress",
                    FlashProgress {
                        bytes_written: final_total,
                        total_bytes: final_total,
                        speed_mbps: 0.0,
                        eta_seconds: 0.0,
                        status: "done".to_string(),
                        message: "Flasheo completado y sincronizado exitosamente.".to_string(),
                    },
                );
                Ok(())
            }
            Err(error) => {
                let _ = app.emit(
                    "flash-progress",
                    FlashProgress {
                        bytes_written: last_bytes,
                        total_bytes: final_total,
                        speed_mbps: 0.0,
                        eta_seconds: 0.0,
                        status: "error".to_string(),
                        message: format!("Error de ejecución: {error}"),
                    },
                );
                Err(error)
            }
        }
    }

    /// Cancels the active flash process
    pub async fn cancel_flash(&self) -> AppResult<()> {
        let mut guard = self.active_process.lock().await;
        if let Some(mut child) = guard.take() {
            tracing::info!("Cancelando el flasheo de unidad...");
            let _ = child.kill().await;
        }
        Ok(())
    }
}

/// Helper function to spawn binary with platform-specific privilege elevation.
async fn spawn_elevated_process(
    exe_path: &Path,
    args: &[String],
) -> AppResult<tokio::process::Child> {
    let _exe_str = exe_path.to_string_lossy();

    #[cfg(target_os = "linux")]
    {
        tracing::info!("Elevando privilegios en Linux usando pkexec...");
        let mut cmd = tokio::process::Command::new("pkexec");
        cmd.arg(exe_path);
        cmd.args(args);
        cmd.spawn()
            .map_err(|e| AppError::Flash(format!("Error iniciando pkexec: {}", e)))
    }

    #[cfg(target_os = "macos")]
    {
        tracing::info!("Elevando privilegios en macOS usando osascript...");
        let cmd_str = format!("'{}' {}", _exe_str, args.join(" "));
        let script = format!(
            "do shell script \"{}\" with administrator privileges",
            cmd_str
        );

        let mut cmd = tokio::process::Command::new("osascript");
        cmd.args(["-e", &script]);
        cmd.spawn()
            .map_err(|e| AppError::Flash(format!("Error iniciando osascript: {}", e)))
    }

    #[cfg(target_os = "windows")]
    {
        tracing::info!("Elevando privilegios en Windows usando PowerShell RunAs...");
        let escaped_args = args
            .iter()
            .map(|a| format!("'{}'", a))
            .collect::<Vec<String>>()
            .join(", ");

        let ps_cmd = format!(
            "Start-Process -FilePath '{}' -ArgumentList {} -Verb RunAs -WindowStyle Hidden -PassThru",
            _exe_str, escaped_args
        );

        let mut cmd = tokio::process::Command::new("powershell");
        cmd.args(["-NoProfile", "-Command", &ps_cmd]);
        cmd.spawn()
            .map_err(|e| AppError::Flash(format!("Error iniciando PowerShell elevated: {}", e)))
    }
}

fn unique_progress_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());

    std::env::temp_dir().join(format!(
        "sigil-flash-progress-{}-{nonce}.json",
        std::process::id()
    ))
}

/// Prevents independent application instances from writing the same device.
///
/// The elevated writer owns this lock for the complete write and post-install
/// sequence. A PID left behind by a crashed process is reclaimed on the next
/// attempt.
#[derive(Debug)]
struct DeviceWriteLock {
    path: PathBuf,
    owner_pid: u32,
}

impl DeviceWriteLock {
    fn acquire(device: &str) -> AppResult<Self> {
        Self::acquire_in(Path::new("/run/lock"), device)
    }

    fn acquire_in(lock_dir: &Path, device: &str) -> AppResult<Self> {
        let device_name = Path::new(device)
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| {
                !name.is_empty()
                    && name.chars().all(|character| {
                        character.is_ascii_alphanumeric() || "._-".contains(character)
                    })
            })
            .ok_or_else(|| {
                AppError::Validation(format!(
                    "Nombre de dispositivo no válido para bloqueo: {device}"
                ))
            })?;

        std::fs::create_dir_all(lock_dir)?;
        let lock_path = lock_dir.join(format!("sigil-flash-{device_name}.lock"));
        let owner_pid = std::process::id();

        for _ in 0..2 {
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&lock_path)
            {
                Ok(mut file) => {
                    writeln!(file, "{owner_pid}")?;
                    file.sync_all()?;
                    return Ok(Self {
                        path: lock_path,
                        owner_pid,
                    });
                }
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    let existing_pid = std::fs::read_to_string(&lock_path)
                        .ok()
                        .and_then(|contents| contents.trim().parse::<u32>().ok());

                    if existing_pid.is_some_and(|pid| Path::new(&format!("/proc/{pid}")).exists()) {
                        return Err(AppError::Flash(format!(
                            "Ya hay otro proceso escribiendo {device}. Espera a que termine."
                        )));
                    }

                    std::fs::remove_file(&lock_path).map_err(|remove_error| {
                        AppError::Flash(format!(
                            "No se pudo recuperar el bloqueo de {device}: {remove_error}"
                        ))
                    })?;
                }
                Err(error) => {
                    return Err(AppError::Flash(format!(
                        "No se pudo bloquear {device} para escritura exclusiva: {error}"
                    )));
                }
            }
        }

        Err(AppError::Flash(format!(
            "No se pudo obtener el bloqueo exclusivo de {device}."
        )))
    }
}

impl Drop for DeviceWriteLock {
    fn drop(&mut self) {
        let still_owned = std::fs::read_to_string(&self.path)
            .is_ok_and(|contents| contents.trim() == self.owner_pid.to_string());
        if still_owned {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Raw block-by-block image copier executing under administrative rights.
/// Periodically saves status to the progress file.
pub async fn run_raw_flash_cli(
    src: &str,
    dest: &str,
    progress_file: &str,
    offline_packages: &str,
) -> AppResult<()> {
    // Safety verification check: Block writing to critical mountpoints on Linux/macOS
    #[cfg(unix)]
    {
        let system_disks = get_system_disks();
        let dest_parent = get_parent_disk(dest);
        if system_disks.contains(&dest_parent) {
            return Err(AppError::Flash(format!(
                "RECHAZADO: Se detectó intento de flashear disco del sistema principal o partición del mismo: {}",
                dest
            )));
        }
    }

    let src_path = PathBuf::from(src);
    let dest_path = PathBuf::from(dest);
    let prog_path = PathBuf::from(progress_file);
    write_progress_file(
        &prog_path,
        &FlashProgress {
            bytes_written: 0,
            total_bytes: 0,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: "Validando imagen y dependencias offline...".to_string(),
        },
    );
    let flash_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| AppError::Validation("No se pudo resolver SIGIL Flash".into()))?;
    let package_contract = flash_root
        .join("sigil-hardware")
        .join("manifests")
        .join("offline-package-contract.json");
    validate_bundle_for_image(&src_path, Path::new(offline_packages), &package_contract)?;
    let _device_lock = DeviceWriteLock::acquire(dest)?;

    let total_bytes = if src.to_lowercase().ends_with(".xz") {
        get_xz_uncompressed_size(src)?
    } else {
        let metadata = std::fs::metadata(&src_path)?;
        metadata.len()
    };

    let mut xz_child = None;
    let mut src_file: std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>> = if src
        .to_lowercase()
        .ends_with(".xz")
    {
        let mut child = tokio::process::Command::new("xz")
            .args(["-d", "-c", src])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| AppError::Flash(format!("No se pudo iniciar descompresión xz: {}", e)))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AppError::Flash("No se pudo obtener la salida de xz".to_string()))?;
        xz_child = Some(child);
        Box::pin(stdout)
    } else {
        let file = File::open(&src_path)
            .await
            .map_err(|e| AppError::Flash(format!("No se pudo abrir imagen: {}", e)))?;
        Box::pin(file)
    };

    // Open physical drive for writing (Direct Sync Mode if possible depending on OS)
    let mut dest_file = File::create(&dest_path).await.map_err(|e| {
        AppError::Flash(format!(
            "No se pudo abrir unidad física para escritura: {}",
            e
        ))
    })?;

    let mut buffer = vec![0; 4 * 1024 * 1024]; // 4MB buffer
    let mut bytes_written = 0u64;

    while bytes_written < total_bytes {
        let read_len = src_file.read(&mut buffer).await.map_err(AppError::Io)?;

        if read_len == 0 {
            break;
        }

        dest_file
            .write_all(&buffer[..read_len])
            .await
            .map_err(AppError::Io)?;

        bytes_written += read_len as u64;

        // Write progress state
        let progress = FlashProgress {
            bytes_written,
            total_bytes,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: format!(
                "Escribiendo bloques a la unidad... {:.1}%",
                (bytes_written as f64 / total_bytes as f64) * 100.0
            ),
        };

        if let Ok(json) = serde_json::to_string(&progress) {
            let _ = std::fs::write(&prog_path, json);
        }
    }

    // Force synchronization of buffers to physical platter
    dest_file.sync_all().await?;
    drop(dest_file);

    if let Some(mut child) = xz_child {
        let status = child.wait().await.map_err(AppError::Io)?;
        if !status.success() {
            return Err(AppError::Flash(
                "La descompresión xz terminó con errores.".to_string(),
            ));
        }
    }

    if bytes_written != total_bytes {
        return Err(AppError::Flash(format!(
            "La imagen quedó incompleta: se escribieron {} de {} bytes.",
            bytes_written, total_bytes
        )));
    }

    // Report post-install status
    let copy_progress = FlashProgress {
        bytes_written: total_bytes,
        total_bytes,
        speed_mbps: 0.0,
        eta_seconds: 0.0,
        status: "running".to_string(),
        message: "Instalando sistema sigil-hardware en la microSD...".to_string(),
    };
    if let Ok(json) = serde_json::to_string(&copy_progress) {
        let _ = std::fs::write(&prog_path, json);
    }

    // Perform offline installation of sigil-hardware on the microSD
    if let Err(e) = install_sigil_hardware(dest, Path::new(offline_packages)) {
        let err_progress = FlashProgress {
            bytes_written: total_bytes,
            total_bytes,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "error".to_string(),
            message: format!("Error en post-instalación: {}", e),
        };
        if let Ok(json) = serde_json::to_string(&err_progress) {
            let _ = std::fs::write(&prog_path, json);
        }
        return Err(e);
    }

    let final_progress = FlashProgress {
        bytes_written: total_bytes,
        total_bytes,
        speed_mbps: 0.0,
        eta_seconds: 0.0,
        status: "done".to_string(),
        message: "Flasheo e instalación de sigil-hardware completados exitosamente.".to_string(),
    };
    if let Ok(json) = serde_json::to_string(&final_progress) {
        let _ = std::fs::write(&prog_path, json);
    }

    Ok(())
}

fn write_progress_file(path: &Path, progress: &FlashProgress) {
    if let Ok(json) = serde_json::to_string(progress) {
        let _ = std::fs::write(path, json);
    }
}

pub fn write_raw_flash_error(progress_file: &str, error: &AppError) {
    let path = Path::new(progress_file);
    let previous = std::fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str::<FlashProgress>(&content).ok());
    write_progress_file(
        path,
        &FlashProgress {
            bytes_written: previous.as_ref().map_or(0, |value| value.bytes_written),
            total_bytes: previous.as_ref().map_or(0, |value| value.total_bytes),
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "error".to_string(),
            message: format!("Error en flasheo o postinstalación: {error}"),
        },
    );
}

// ============================================================
// HELPERS FOR SAFETY & DYNAMIC SYSTEM DISK DETECTION
// ============================================================

#[cfg(unix)]
fn get_parent_disk(path: &str) -> String {
    let path = path.trim();
    if path.starts_with("/dev/nvme") {
        if let Some(pos) = path.rfind('p') {
            if pos > "/dev/nvme".len() {
                return path[..pos].to_string();
            }
        }
    } else if path.starts_with("/dev/sd")
        || path.starts_with("/dev/hd")
        || path.starts_with("/dev/vd")
    {
        let parent = path.trim_end_matches(|c: char| c.is_ascii_digit());
        return parent.to_string();
    } else if path.starts_with("/dev/mmcblk") {
        if let Some(pos) = path.rfind('p') {
            if pos > "/dev/mmcblk".len() {
                return path[..pos].to_string();
            }
        }
    }
    path.to_string()
}

#[cfg(unix)]
fn get_system_disks() -> Vec<String> {
    let mut disks = Vec::new();

    #[cfg(target_os = "linux")]
    {
        if let Ok(content) = std::fs::read_to_string("/proc/mounts") {
            for line in content.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 2 && parts[1] == "/" {
                    let source = parts[0];
                    if source.starts_with("/dev/") {
                        let parent = get_parent_disk(source);
                        disks.push(parent);
                    }
                }
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = std::process::Command::new("df").arg("/").output() {
            if output.status.success() {
                let stdout_str = String::from_utf8_lossy(&output.stdout);
                for line in stdout_str.lines().skip(1) {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if let Some(source) = parts.first() {
                        if source.starts_with("/dev/") {
                            let parent = get_parent_disk(source);
                            disks.push(parent);
                        }
                    }
                }
            }
        }
    }

    if disks.is_empty() {
        disks.push("/dev/nvme0n1".to_string());
    }

    disks
}

// ============================================================
// HELPERS FOR COMPRESSED IMAGES (.XZ)
// ============================================================

pub fn get_xz_uncompressed_size(path: &str) -> AppResult<u64> {
    let output = std::process::Command::new("xz")
        .args(["--robot", "-l", path])
        .output()
        .map_err(|e| AppError::Flash(format!("No se pudo ejecutar xz: {}", e)))?;

    if !output.status.success() {
        return Err(AppError::Flash(
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }

    let stdout_str = String::from_utf8_lossy(&output.stdout);
    for line in stdout_str.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.first() == Some(&"totals") && parts.len() >= 5 {
            if let Ok(size) = parts[4].parse::<u64>() {
                return Ok(size);
            }
        }
    }

    Err(AppError::Flash(
        "No se pudo obtener el tamaño descomprimido del archivo xz.".to_string(),
    ))
}

fn install_sigil_hardware(device: &str, offline_packages: &Path) -> AppResult<()> {
    let root_partition = partition_path(device, 2);
    let boot_partition = partition_path(device, 1);
    let flash_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| AppError::Validation("No se pudo resolver SIGIL Flash".into()))?;
    let hardware_source = flash_root.join("sigil-hardware");
    let package_contract = hardware_source
        .join("manifests")
        .join("offline-package-contract.json");

    flasher_rs::offline::validate_repository(offline_packages, &package_contract)
        .map_err(|error| AppError::Validation(format!("Bundle offline inválido: {error}")))?;

    println!("Recargando tabla de particiones en {device}...");
    let _ = std::process::Command::new("partprobe").arg(device).status();
    std::thread::sleep(Duration::from_secs(1));
    let _ = std::process::Command::new("umount")
        .arg(&boot_partition)
        .status();
    let _ = std::process::Command::new("umount")
        .arg(&root_partition)
        .status();

    let mount_dir = std::env::temp_dir().join(format!("sigil-rootfs-{}", std::process::id()));
    std::fs::create_dir_all(&mount_dir)?;
    let mut mounted = Vec::new();

    if let Err(error) = mount_partition_with_retry(device, &root_partition, &mount_dir) {
        let _ = std::fs::remove_dir(&mount_dir);
        return Err(error);
    }
    mounted.push(mount_dir.clone());

    let preparation = (|| -> AppResult<()> {
        let boot_mount = mount_dir.join("boot/firmware");
        std::fs::create_dir_all(&boot_mount)?;
        mount_checked(&boot_partition, &boot_mount)?;
        mounted.push(boot_mount);

        println!("Copiando payload sigil-hardware sin artefactos de desarrollo...");
        let hardware_target = mount_dir.join("opt/sigil-hardware");
        copy_hardware_payload(&hardware_source, &hardware_target)?;

        println!("Inyectando repositorio APT offline en /opt/sigil/offline-repo...");
        let repository_target = mount_dir.join("opt/sigil/offline-repo");
        copy_directory_contents(offline_packages, &repository_target)?;

        for (source, relative, mount_type) in [
            ("/dev", "dev", "bind"),
            ("proc", "proc", "proc"),
            ("sysfs", "sys", "sysfs"),
        ] {
            let target = mount_dir.join(relative);
            std::fs::create_dir_all(&target)?;
            let status = if mount_type == "bind" {
                std::process::Command::new("mount")
                    .args(["--bind", source])
                    .arg(&target)
                    .status()
            } else {
                std::process::Command::new("mount")
                    .args(["-t", mount_type, source])
                    .arg(&target)
                    .status()
            }
            .map_err(|error| AppError::Flash(format!("No se pudo montar {relative}: {error}")))?;
            if !status.success() {
                return Err(AppError::Flash(format!(
                    "No se pudo montar {relative} para preparar la imagen"
                )));
            }
            mounted.push(target);
        }

        let policy_path = mount_dir.join("usr/sbin/policy-rc.d");
        let policy_backup = mount_dir.join("usr/sbin/policy-rc.d.sigil-backup");
        if policy_path.exists() {
            std::fs::rename(&policy_path, &policy_backup)?;
        }
        std::fs::write(&policy_path, "#!/bin/sh\nexit 101\n")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&policy_path, std::fs::Permissions::from_mode(0o755))?;
        }

        let qemu_target = mount_dir.join("usr/bin/qemu-aarch64-static");
        let copied_qemu = std::env::consts::ARCH != "aarch64" && !qemu_target.exists();
        let install_result = (|| -> AppResult<()> {
            if copied_qemu {
                let qemu_source = Path::new("/usr/bin/qemu-aarch64-static");
                if !qemu_source.is_file() {
                    return Err(AppError::Flash(
                        "qemu-aarch64-static es obligatorio para preparar una imagen ARM64 desde este host"
                            .into(),
                    ));
                }
                std::fs::copy(qemu_source, &qemu_target)?;
            }

            println!("Instalando dependencias y configuración dentro de la imagen (sin red)...");
            let mut command = std::process::Command::new("chroot");
            command.arg(&mount_dir);
            if std::env::consts::ARCH != "aarch64" {
                command.arg("/usr/bin/qemu-aarch64-static");
            }
            let output = command
                .args([
                    "/bin/bash",
                    "/opt/sigil-hardware/install.sh",
                    "--offline-repo",
                    "/opt/sigil/offline-repo",
                ])
                .env("SIGIL_IMAGE_PREPARATION", "1")
                .env("DEBIAN_FRONTEND", "noninteractive")
                .output()
                .map_err(|error| AppError::Flash(format!("No se pudo iniciar chroot: {error}")))?;
            if !output.status.success() {
                let detail = summarize_command_failure(&output.stdout, &output.stderr);
                return Err(AppError::Flash(format!(
                    "La instalación offline dentro de la imagen falló con estado {}: {detail}",
                    output.status
                )));
            }
            Ok(())
        })();
        let _ = std::fs::remove_file(&policy_path);
        if policy_backup.exists() {
            std::fs::rename(&policy_backup, &policy_path)?;
        }
        if copied_qemu {
            let _ = std::fs::remove_file(&qemu_target);
        }
        install_result?;

        let sync_status = std::process::Command::new("sync").status()?;
        if !sync_status.success() {
            return Err(AppError::Flash("No se pudo sincronizar la microSD".into()));
        }
        Ok(())
    })();

    let cleanup_result = unmount_all(&mut mounted);
    let _ = std::fs::remove_dir(&mount_dir);
    preparation?;
    cleanup_result?;
    println!("Imagen preparada: paquetes instalados offline y firstboot mínimo habilitado.");
    Ok(())
}

fn summarize_command_failure(stdout: &[u8], stderr: &[u8]) -> String {
    fn tail(bytes: &[u8]) -> String {
        let text = String::from_utf8_lossy(bytes);
        let mut lines = text
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .rev()
            .take(8)
            .collect::<Vec<_>>();
        lines.reverse();
        lines.join(" | ")
    }

    let stderr = tail(stderr);
    let stdout = tail(stdout);
    match (stderr.is_empty(), stdout.is_empty()) {
        (false, false) => format!("stderr: {stderr}; stdout: {stdout}"),
        (false, true) => format!("stderr: {stderr}"),
        (true, false) => format!("stdout: {stdout}"),
        (true, true) => "el instalador no produjo salida de diagnóstico".to_string(),
    }
}

fn validate_bundle_for_image(
    image: &Path,
    offline_packages: &Path,
    package_contract: &Path,
) -> AppResult<()> {
    let summary = flasher_rs::offline::validate_repository(offline_packages, package_contract)
        .map_err(|error| {
            AppError::Validation(format!(
                "El bundle de dependencias offline no es válido: {error}"
            ))
        })?;
    let image_name = image
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            AppError::Validation("La imagen base no tiene un nombre de archivo válido".into())
        })?;
    if image_name != summary.base_image_name {
        return Err(AppError::Validation(format!(
            "El bundle {} requiere la imagen {}, no {}",
            summary.bundle_version, summary.base_image_name, image_name
        )));
    }

    let image_sha256 = sha256_file(image)?;
    if image_sha256 != summary.base_image_sha256 {
        return Err(AppError::Validation(format!(
            "La imagen base {} no coincide con el SHA-256 requerido por el bundle {}",
            image.display(),
            summary.bundle_version
        )));
    }
    Ok(())
}

fn sha256_file(path: &Path) -> AppResult<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn partition_path(device: &str, number: u8) -> String {
    if device.contains("mmcblk") || device.contains("nvme") || device.contains("loop") {
        format!("{device}p{number}")
    } else {
        format!("{device}{number}")
    }
}

fn mount_partition_with_retry(device: &str, partition: &str, target: &Path) -> AppResult<()> {
    for attempt in 1..=10 {
        let status = std::process::Command::new("mount")
            .arg(partition)
            .arg(target)
            .status();
        if status.as_ref().is_ok_and(|value| value.success()) {
            return Ok(());
        }
        println!("Montaje de {partition}: intento {attempt}/10...");
        let _ = std::process::Command::new("sync").status();
        let _ = std::process::Command::new("partprobe").arg(device).status();
        std::thread::sleep(Duration::from_secs(2));
    }
    Err(AppError::Flash(format!(
        "No se pudo montar la partición raíz {partition}"
    )))
}

fn mount_checked(source: &str, target: &Path) -> AppResult<()> {
    let status = std::process::Command::new("mount")
        .arg(source)
        .arg(target)
        .status()
        .map_err(|error| AppError::Flash(format!("No se pudo ejecutar mount: {error}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(AppError::Flash(format!(
            "No se pudo montar {source} en {}",
            target.display()
        )))
    }
}

fn copy_hardware_payload(source: &Path, target: &Path) -> AppResult<()> {
    if target.exists() {
        std::fs::remove_dir_all(target)?;
    }
    std::fs::create_dir_all(target)?;
    copy_path(&source.join("install.sh"), &target.join("install.sh"))?;
    for directory in ["panel", "scripts", "services", "conf", "manifests"] {
        copy_path(&source.join(directory), &target.join(directory))?;
    }
    Ok(())
}

fn copy_directory_contents(source: &Path, target: &Path) -> AppResult<()> {
    if target.exists() {
        std::fs::remove_dir_all(target)?;
    }
    std::fs::create_dir_all(target)?;
    let status = std::process::Command::new("cp")
        .args(["-a"])
        .arg(source.join("."))
        .arg(target)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(AppError::Flash(format!(
            "No se pudo copiar el repositorio offline desde {}",
            source.display()
        )))
    }
}

fn copy_path(source: &Path, target: &Path) -> AppResult<()> {
    if !source.exists() {
        return Err(AppError::Flash(format!(
            "Falta un componente del payload: {}",
            source.display()
        )));
    }
    let status = std::process::Command::new("cp")
        .args(["-a"])
        .arg(source)
        .arg(target)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(AppError::Flash(format!(
            "No se pudo copiar {}",
            source.display()
        )))
    }
}

fn unmount_all(mounted: &mut Vec<PathBuf>) -> AppResult<()> {
    let mut failures = Vec::new();
    while let Some(target) = mounted.pop() {
        let status = std::process::Command::new("umount").arg(&target).status();
        if !status.as_ref().is_ok_and(|value| value.success()) {
            failures.push(target.display().to_string());
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(AppError::Flash(format!(
            "No se pudieron desmontar de forma segura: {}",
            failures.join(", ")
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_lock_dir(test_name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("sigil-flash-{test_name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create isolated lock directory");
        path
    }

    #[test]
    fn device_write_lock_should_reject_second_writer_for_same_device() {
        let lock_dir = isolated_lock_dir("reject-second-writer");
        let _first = DeviceWriteLock::acquire_in(&lock_dir, "/dev/test-card")
            .expect("first writer should acquire lock");

        let error = DeviceWriteLock::acquire_in(&lock_dir, "/dev/test-card")
            .expect_err("second writer should be rejected");

        assert!(error
            .to_string()
            .contains("Ya hay otro proceso escribiendo"));
        let _ = std::fs::remove_dir_all(lock_dir);
    }

    #[test]
    fn device_write_lock_should_allow_writer_after_previous_lock_is_dropped() {
        let lock_dir = isolated_lock_dir("allow-after-drop");
        let first = DeviceWriteLock::acquire_in(&lock_dir, "/dev/test-card")
            .expect("first writer should acquire lock");
        drop(first);

        let second = DeviceWriteLock::acquire_in(&lock_dir, "/dev/test-card");

        assert!(second.is_ok(), "lock was not released: {second:?}");
        drop(second);
        let _ = std::fs::remove_dir_all(lock_dir);
    }

    #[test]
    fn device_write_lock_should_reclaim_stale_pid_file() {
        let lock_dir = isolated_lock_dir("reclaim-stale-lock");
        let lock_path = lock_dir.join("sigil-flash-test-card.lock");
        std::fs::write(&lock_path, u32::MAX.to_string()).expect("write stale lock");

        let lock = DeviceWriteLock::acquire_in(&lock_dir, "/dev/test-card");

        assert!(lock.is_ok(), "stale lock was not reclaimed: {lock:?}");
        drop(lock);
        let _ = std::fs::remove_dir_all(lock_dir);
    }

    #[test]
    fn repository_copy_replaces_stale_files_idempotently() {
        let root = isolated_lock_dir("repository-copy-idempotent");
        let source = root.join("source");
        let target = root.join("target");
        std::fs::create_dir_all(source.join("packages")).expect("source packages");
        std::fs::write(source.join("Packages"), b"fixture index").expect("source index");
        std::fs::write(source.join("packages/demo.deb"), b"fixture package")
            .expect("source package");
        std::fs::create_dir_all(&target).expect("target");
        std::fs::write(target.join("stale.deb"), b"stale").expect("stale package");

        copy_directory_contents(&source, &target).expect("first repository copy");
        copy_directory_contents(&source, &target).expect("second repository copy");

        assert!(!target.join("stale.deb").exists());
        assert_eq!(
            std::fs::read(target.join("Packages")).expect("copied index"),
            b"fixture index"
        );
        assert!(target.join("packages/demo.deb").is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn empty_mount_cleanup_is_idempotent() {
        let mut mounted = Vec::new();
        assert!(unmount_all(&mut mounted).is_ok());
        assert!(unmount_all(&mut mounted).is_ok());
    }

    fn progress(status: &str, message: &str) -> FlashProgress {
        FlashProgress {
            bytes_written: 1,
            total_bytes: 2,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: status.to_string(),
            message: message.to_string(),
        }
    }

    #[test]
    fn running_writer_should_remain_authoritative_after_launcher_failure() {
        let running = progress("running", "installing offline packages");

        let outcome =
            completion_from_observation(Some(&running), Some(false), Some(Duration::from_secs(60)));

        assert_eq!(outcome, FlashCompletion::Running);
    }

    #[test]
    fn terminal_writer_success_should_override_launcher_failure() {
        let done = progress("done", "complete");

        let outcome =
            completion_from_observation(Some(&done), Some(false), Some(Duration::from_secs(60)));

        assert_eq!(outcome, FlashCompletion::Succeeded);
    }

    #[test]
    fn terminal_writer_error_should_preserve_actionable_message() {
        let error = progress("error", "dpkg configuration failed");

        let outcome =
            completion_from_observation(Some(&error), Some(false), Some(Duration::from_secs(60)));

        assert_eq!(
            outcome,
            FlashCompletion::Failed("dpkg configuration failed".to_string())
        );
    }

    #[test]
    fn launcher_failure_without_writer_progress_should_fail_after_grace() {
        let outcome = completion_from_observation(None, Some(false), Some(ELEVATED_LAUNCHER_GRACE));

        assert!(matches!(outcome, FlashCompletion::Failed(_)));
    }

    #[test]
    fn command_failure_summary_should_include_stderr_and_stdout_tail() {
        let stdout = b"old\nuseful stdout\n";
        let stderr = b"warning\nactionable failure\n";

        let summary = summarize_command_failure(stdout, stderr);

        assert_eq!(
            summary,
            "stderr: warning | actionable failure; stdout: old | useful stdout"
        );
    }

    #[test]
    fn raw_flash_error_should_preserve_existing_progress_counts() {
        let root = isolated_lock_dir("raw-error-progress");
        let path = root.join("progress.json");
        write_progress_file(&path, &progress("running", "writing"));

        write_raw_flash_error(
            path.to_str().expect("UTF-8 fixture path"),
            &AppError::Flash("dpkg failed".to_string()),
        );

        let actual: FlashProgress =
            serde_json::from_slice(&std::fs::read(&path).expect("read error progress"))
                .expect("parse error progress");
        assert_eq!(actual.bytes_written, 1);
        assert_eq!(actual.total_bytes, 2);
        assert_eq!(actual.status, "error");
        assert!(actual.message.contains("dpkg failed"));
        let _ = std::fs::remove_dir_all(root);
    }
}
