use crate::errors::{AppError, AppResult};
use crate::models::{DeviceConfig, FlashProgress};
use sha2::{Digest, Sha256};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
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
const MAX_PRIVATE_CONFIG_BYTES: u64 = 16 * 1024;

struct PrivateConfigFile {
    path: PathBuf,
}

impl PrivateConfigFile {
    #[cfg(unix)]
    fn create(config: &DeviceConfig) -> AppResult<Self> {
        use std::os::unix::fs::OpenOptionsExt;

        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| duration.as_nanos());
        let path = std::env::temp_dir().join(format!(
            "sigil-manufacturing-config-{}-{nonce}.json",
            std::process::id()
        ));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        if let Err(error) = serde_json::to_writer(&mut file, config) {
            let _ = std::fs::remove_file(&path);
            return Err(error.into());
        }
        file.sync_all()?;
        Ok(Self { path })
    }

    #[cfg(not(unix))]
    fn create(config: &DeviceConfig) -> AppResult<Self> {
        let _ = config;
        Err(AppError::Validation(
            "El aprovisionamiento seguro integrado requiere un host Unix".into(),
        ))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PrivateConfigFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

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
        config: &DeviceConfig,
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
        validate_device_config(config)?;
        validate_bundle_for_image(&image_p, &self.offline_packages, &self.package_contract)?;
        let private_config = PrivateConfigFile::create(config)?;

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
            "--config-file".to_string(),
            private_config.path().to_string_lossy().to_string(),
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

fn validate_device_config(config: &DeviceConfig) -> AppResult<()> {
    if config.username != "sigil" {
        return Err(AppError::Validation(
            "El usuario del sistema debe ser 'sigil'".into(),
        ));
    }
    if !is_valid_hostname(&config.hostname) {
        return Err(AppError::Validation(
            "El hostname debe tener entre 1 y 63 caracteres seguros".into(),
        ));
    }
    let serial = config.serial_number.as_deref().ok_or_else(|| {
        AppError::Validation("El número de serie de fabricación es obligatorio".into())
    })?;
    if serial.is_empty()
        || serial.len() > 64
        || !serial
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
    {
        return Err(AppError::Validation(
            "El número de serie contiene caracteres no permitidos".into(),
        ));
    }
    let rpi_model = config
        .rpi_model
        .as_deref()
        .ok_or_else(|| AppError::Validation("El modelo de Raspberry Pi es obligatorio".into()))?;
    if !matches!(
        rpi_model,
        "Raspberry Pi 5 (64-bit)"
            | "Raspberry Pi 4 (64-bit)"
            | "Raspberry Pi 3 (64-bit)"
            | "Raspberry Pi Zero 2 W (64-bit)"
    ) {
        return Err(AppError::Validation(
            "El bundle ARM64 solo admite modelos Raspberry Pi de 64 bits compatibles".into(),
        ));
    }
    validate_panel_pin(config.panel_pin.as_deref())?;

    if config.ssh_enabled {
        let password = config.password.as_deref().ok_or_else(|| {
            AppError::Validation("La contraseña SSH es obligatoria cuando SSH está activo".into())
        })?;
        if !(6..=128).contains(&password.len())
            || password
                .chars()
                .any(|character| matches!(character, '\r' | '\n' | '\0'))
        {
            return Err(AppError::Validation(
                "La contraseña SSH debe tener entre 6 y 128 caracteres válidos".into(),
            ));
        }
    }

    match (&config.wifi_ssid, &config.wifi_password) {
        (None, None) => {}
        (Some(ssid), Some(password))
            if !ssid.is_empty()
                && ssid.len() <= 32
                && !ssid
                    .chars()
                    .any(|character| matches!(character, '\r' | '\n' | '\0'))
                && (8..=63).contains(&password.len())
                && !password
                    .chars()
                    .any(|character| matches!(character, '\r' | '\n' | '\0')) => {}
        _ => {
            return Err(AppError::Validation(
                "La red Wi-Fi requiere SSID y contraseña WPA válidos".into(),
            ));
        }
    }
    Ok(())
}

fn is_valid_hostname(hostname: &str) -> bool {
    let bytes = hostname.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 63
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
}

fn validate_panel_pin(pin: Option<&str>) -> AppResult<()> {
    let pin = pin.ok_or_else(|| {
        AppError::Validation("El PIN del panel es obligatorio para fabricación".into())
    })?;
    if !(6..=12).contains(&pin.len()) || !pin.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(AppError::Validation(
            "El PIN del panel debe contener entre 6 y 12 dígitos".into(),
        ));
    }
    let repeated = pin.bytes().all(|byte| Some(byte) == pin.bytes().next());
    let ascending = "12345678901234567890".contains(pin);
    let descending = "98765432109876543210".contains(pin);
    if repeated || ascending || descending {
        return Err(AppError::Validation(
            "El PIN del panel es demasiado predecible".into(),
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn read_private_device_config(path: &Path) -> AppResult<DeviceConfig> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let before = std::fs::symlink_metadata(path)?;
    if !before.file_type().is_file() || before.file_type().is_symlink() {
        return Err(AppError::Validation(
            "La configuración temporal debe ser un archivo regular".into(),
        ));
    }
    if before.len() > MAX_PRIVATE_CONFIG_BYTES || before.permissions().mode() & 0o077 != 0 {
        return Err(AppError::Validation(
            "La configuración temporal tiene tamaño o permisos inseguros".into(),
        ));
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    let opened = file.metadata()?;
    if before.dev() != opened.dev() || before.ino() != opened.ino() {
        return Err(AppError::Validation(
            "La configuración temporal cambió mientras se abría".into(),
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_PRIVATE_CONFIG_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_PRIVATE_CONFIG_BYTES {
        return Err(AppError::Validation(
            "La configuración temporal excede el tamaño permitido".into(),
        ));
    }
    serde_json::from_slice(&bytes).map_err(Into::into)
}

#[cfg(not(unix))]
fn read_private_device_config(path: &Path) -> AppResult<DeviceConfig> {
    let _ = path;
    Err(AppError::Validation(
        "El aprovisionamiento seguro integrado requiere un host Unix".into(),
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
    config_file: &str,
) -> AppResult<()> {
    let config = read_private_device_config(Path::new(config_file))?;
    validate_device_config(&config)?;
    std::fs::remove_file(config_file).map_err(|error| {
        AppError::Validation(format!(
            "No se pudo eliminar la configuración temporal después de consumirla: {error}"
        ))
    })?;

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
    if let Err(e) = install_sigil_hardware(dest, Path::new(offline_packages), &config) {
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

fn write_manufacturing_provision(root: &Path, config: &DeviceConfig) -> AppResult<()> {
    let serial = config.serial_number.as_deref().ok_or_else(|| {
        AppError::Validation("El número de serie de fabricación es obligatorio".into())
    })?;
    let provision = serde_json::json!({
        "_schema_version": "1.0",
        "serial_number": serial,
        "model": "Sigil-Streamer",
        "model_version": "v1",
        "batch": format!("flash-{}", chrono::Utc::now().format("%Y-%m")),
        "capabilities": {
            "i2s_dac": false
        }
    });
    let boot = root.join("boot/firmware");
    std::fs::create_dir_all(&boot)?;
    std::fs::write(
        boot.join("sigil_provision.json"),
        serde_json::to_vec_pretty(&provision)?,
    )?;
    Ok(())
}

fn apply_hostname(root: &Path, hostname: &str) -> AppResult<()> {
    if !is_valid_hostname(hostname) {
        return Err(AppError::Validation("Hostname inválido".into()));
    }
    std::fs::write(root.join("etc/hostname"), format!("{hostname}\n"))?;
    let hosts_path = root.join("etc/hosts");
    let original = std::fs::read_to_string(&hosts_path).unwrap_or_default();
    let mut found = false;
    let mut lines = original
        .lines()
        .map(|line| {
            if line
                .split_whitespace()
                .next()
                .is_some_and(|address| address == "127.0.1.1")
            {
                found = true;
                format!("127.0.1.1\t{hostname}")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>();
    if !found {
        lines.push(format!("127.0.1.1\t{hostname}"));
    }
    std::fs::write(hosts_path, format!("{}\n", lines.join("\n")))?;
    Ok(())
}

fn apply_rpi_model_optimizations(boot: &Path, rpi_model: Option<&str>) -> AppResult<()> {
    let settings = match rpi_model {
        Some("Raspberry Pi 5 (64-bit)") => "arm_64bit=1\ndtparam=pciex1_gen=3\ngpu_mem=64\n",
        Some("Raspberry Pi 4 (64-bit)") => "arm_64bit=1\ngpu_mem=64\n",
        Some("Raspberry Pi 3 (64-bit)" | "Raspberry Pi Zero 2 W (64-bit)") => {
            "arm_64bit=1\ngpu_mem=32\nmax_usb_current=1\n"
        }
        _ => {
            return Err(AppError::Validation(
                "El modelo físico no es compatible con la imagen ARM64".into(),
            ));
        }
    };
    let config_path = boot.join("config.txt");
    let mut config = std::fs::read_to_string(&config_path).unwrap_or_default();
    config.push_str("\n# --- Sigil Flash Auto-Optimizations ---\n");
    config.push_str(settings);
    config.push_str("# --- End Sigil Flash Auto-Optimizations ---\n");
    std::fs::write(config_path, config)?;
    Ok(())
}

#[cfg(unix)]
fn write_private_root_file(path: &Path, contents: &[u8]) -> AppResult<()> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(contents)?;
    file.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn write_private_root_file(path: &Path, contents: &[u8]) -> AppResult<()> {
    let _ = (path, contents);
    Err(AppError::Validation(
        "El aprovisionamiento seguro requiere un host Unix".into(),
    ))
}

fn erase_plaintext_file(path: &Path) {
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if metadata.file_type().is_file() && !metadata.file_type().is_symlink() {
            if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(path) {
                let zeroes = vec![0_u8; metadata.len() as usize];
                let _ = file.write_all(&zeroes);
                let _ = file.sync_all();
            }
        }
    }
    let _ = std::fs::remove_file(path);
}

fn run_target_command(
    root: &Path,
    program: &str,
    args: &[&str],
    stdin: Option<&[u8]>,
) -> AppResult<Output> {
    let mut command = std::process::Command::new("chroot");
    command.arg(root);
    if std::env::consts::ARCH != "aarch64" {
        command.arg("/usr/bin/qemu-aarch64-static");
    }
    command
        .arg(program)
        .args(args)
        .env("DEBIAN_FRONTEND", "noninteractive")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if stdin.is_some() {
        command.stdin(Stdio::piped());
    } else {
        command.stdin(Stdio::null());
    }
    let mut child = command
        .spawn()
        .map_err(|error| AppError::Flash(format!("No se pudo iniciar {program}: {error}")))?;
    if let Some(input) = stdin {
        let mut child_stdin = child.stdin.take().ok_or_else(|| {
            AppError::Flash(format!("No se pudo abrir la entrada estándar de {program}"))
        })?;
        if let Err(error) = child_stdin.write_all(input) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(AppError::Flash(format!(
                "No se pudo suministrar la entrada protegida a {program}: {error}"
            )));
        }
    }
    child
        .wait_with_output()
        .map_err(|error| AppError::Flash(format!("No se pudo esperar a {program}: {error}")))
}

fn provision_panel_credential(root: &Path, config: &DeviceConfig) -> AppResult<()> {
    let pin = config.panel_pin.as_deref().ok_or_else(|| {
        AppError::Validation("El PIN del panel es obligatorio para fabricación".into())
    })?;
    let manufacturing_dir = root.join("etc/sigil/manufacturing");
    std::fs::create_dir_all(&manufacturing_dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&manufacturing_dir, std::fs::Permissions::from_mode(0o700))?;
    }
    let input_path = manufacturing_dir.join("sigil_secrets.json");
    let document = serde_json::json!({
        "_schema_version": "1.0",
        "panel_pin": pin
    });
    write_private_root_file(&input_path, &serde_json::to_vec(&document)?)?;

    let output = run_target_command(
        root,
        "/usr/bin/python3",
        &[
            "/opt/sigil/panel/panel_auth.py",
            "--input",
            "/etc/sigil/manufacturing/sigil_secrets.json",
            "--output",
            "/etc/sigil/secrets/panel-pin.hash",
        ],
        None,
    );
    let output = match output {
        Ok(output) => output,
        Err(error) => {
            erase_plaintext_file(&input_path);
            return Err(error);
        }
    };
    if !output.status.success() {
        erase_plaintext_file(&input_path);
        let detail = summarize_command_failure(&output.stdout, &output.stderr);
        return Err(AppError::Flash(format!(
            "No se pudo generar el hash Argon2id del panel: {detail}"
        )));
    }
    if input_path.exists() || !root.join("etc/sigil/secrets/panel-pin.hash").is_file() {
        erase_plaintext_file(&input_path);
        return Err(AppError::Flash(
            "La credencial del panel no quedó consumida de forma segura".into(),
        ));
    }
    Ok(())
}

fn escape_network_manager_value(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for (index, character) in value.chars().enumerate() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '\t' => escaped.push_str("\\t"),
            ' ' if index == 0 => escaped.push_str("\\s"),
            other => escaped.push(other),
        }
    }
    if value.ends_with(' ') && value.len() > 1 {
        escaped.pop();
        escaped.push_str("\\s");
    }
    escaped
}

fn provision_wifi_profile(root: &Path, config: &DeviceConfig) -> AppResult<()> {
    let (Some(ssid), Some(password)) = (&config.wifi_ssid, &config.wifi_password) else {
        return Ok(());
    };
    let serial = config.serial_number.as_deref().ok_or_else(|| {
        AppError::Validation("El número de serie de fabricación es obligatorio".into())
    })?;
    let mut hasher = Sha256::new();
    hasher.update(serial.as_bytes());
    hasher.update([0]);
    hasher.update(ssid.as_bytes());
    let digest = format!("{:x}", hasher.finalize());
    let uuid = format!(
        "{}-{}-{}-{}-{}",
        &digest[0..8],
        &digest[8..12],
        &digest[12..16],
        &digest[16..20],
        &digest[20..32]
    );
    let contents = format!(
        "[connection]\nid=sigil-manufacturing\nuuid={uuid}\ntype=wifi\ninterface-name=wlan0\nautoconnect=true\nautoconnect-priority=100\n\n[wifi]\nmode=infrastructure\nssid={}\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk={}\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n",
        escape_network_manager_value(ssid),
        escape_network_manager_value(password)
    );
    let directory = root.join("etc/NetworkManager/system-connections");
    std::fs::create_dir_all(&directory)?;
    let path = directory.join("sigil-manufacturing.nmconnection");
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    write_private_root_file(&path, contents.as_bytes())
}

fn write_ssh_dropin(root: &Path, enabled: bool) -> AppResult<()> {
    let dropin_dir = root.join("etc/ssh/sshd_config.d");
    std::fs::create_dir_all(&dropin_dir)?;
    let dropin = dropin_dir.join("90-sigil-access.conf");
    let contents = if enabled {
        "PasswordAuthentication yes\nPubkeyAuthentication yes\nPermitRootLogin no\nAllowUsers sigil\n"
    } else {
        "PasswordAuthentication no\nPubkeyAuthentication yes\nPermitRootLogin no\nAllowUsers sigil\n"
    };
    std::fs::write(&dropin, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dropin, std::fs::Permissions::from_mode(0o644))?;
    }
    Ok(())
}

fn provision_ssh_access(root: &Path, config: &DeviceConfig) -> AppResult<()> {
    write_ssh_dropin(root, config.ssh_enabled)?;

    let systemctl_status = std::process::Command::new("systemctl")
        .arg("--root")
        .arg(root)
        .arg(if config.ssh_enabled {
            "enable"
        } else {
            "disable"
        })
        .arg("ssh.service")
        .status()
        .map_err(|error| AppError::Flash(format!("No se pudo configurar ssh.service: {error}")))?;
    if !systemctl_status.success() {
        return Err(AppError::Flash(
            "No se pudo configurar el inicio automático de SSH".into(),
        ));
    }
    if !config.ssh_enabled {
        return Ok(());
    }

    if !std::fs::read_to_string(root.join("etc/passwd"))
        .is_ok_and(|passwd| passwd.lines().any(|line| line.starts_with("sigil:")))
    {
        return Err(AppError::Flash(
            "El instalador no creó el usuario de sistema sigil".into(),
        ));
    }
    let password = config.password.as_deref().ok_or_else(|| {
        AppError::Validation("La contraseña SSH es obligatoria cuando SSH está activo".into())
    })?;
    let credential = format!("sigil:{password}\n");
    let output = run_target_command(
        root,
        "/usr/sbin/chpasswd",
        &["-c", "YESCRYPT"],
        Some(credential.as_bytes()),
    )?;
    if !output.status.success() {
        let detail = summarize_command_failure(&output.stdout, &output.stderr);
        return Err(AppError::Flash(format!(
            "No se pudo establecer la contraseña del usuario sigil: {detail}"
        )));
    }

    let run_sshd = root.join("run/sshd");
    let created_run_sshd = !run_sshd.exists();
    std::fs::create_dir_all(&run_sshd)?;
    let validation = run_target_command(root, "/usr/sbin/sshd", &["-t"], None);
    if created_run_sshd {
        let _ = std::fs::remove_dir(&run_sshd);
    }
    let validation = validation?;
    if !validation.status.success() {
        let detail = summarize_command_failure(&validation.stdout, &validation.stderr);
        return Err(AppError::Flash(format!(
            "La configuración SSH generada no es válida: {detail}"
        )));
    }
    Ok(())
}

fn install_sigil_hardware(
    device: &str,
    offline_packages: &Path,
    config: &DeviceConfig,
) -> AppResult<()> {
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

        write_manufacturing_provision(&mount_dir, config)?;
        apply_hostname(&mount_dir, &config.hostname)?;
        apply_rpi_model_optimizations(
            &mount_dir.join("boot/firmware"),
            config.rpi_model.as_deref(),
        )?;

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
            provision_panel_credential(&mount_dir, config)?;
            provision_wifi_profile(&mount_dir, config)?;
            provision_ssh_access(&mount_dir, config)?;
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

    fn manufacturing_config() -> DeviceConfig {
        DeviceConfig {
            hostname: "sigil-lab-01".to_string(),
            username: "sigil".to_string(),
            password: Some("ssh-test-80427159".to_string()),
            wifi_ssid: None,
            wifi_password: None,
            ssh_enabled: true,
            rpi_model: Some("Raspberry Pi 4 (64-bit)".to_string()),
            serial_number: Some("SIGIL-TEST-0001".to_string()),
            panel_pin: Some("80427159".to_string()),
        }
    }

    fn isolated_lock_dir(test_name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("sigil-flash-{test_name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create isolated lock directory");
        path
    }

    #[test]
    fn manufacturing_contract_accepts_complete_configuration() {
        assert!(validate_device_config(&manufacturing_config()).is_ok());
    }

    #[test]
    fn manufacturing_contract_rejects_missing_panel_pin() {
        let mut config = manufacturing_config();
        config.panel_pin = None;

        let error = validate_device_config(&config).expect_err("missing PIN must fail");

        assert!(error.to_string().contains("PIN del panel"));
    }

    #[test]
    fn manufacturing_contract_rejects_wrong_system_user() {
        let mut config = manufacturing_config();
        config.username = "pi".to_string();

        let error = validate_device_config(&config).expect_err("wrong user must fail");

        assert!(error.to_string().contains("usuario del sistema"));
    }

    #[test]
    fn manufacturing_contract_rejects_ssh_without_password() {
        let mut config = manufacturing_config();
        config.password = None;

        let error = validate_device_config(&config).expect_err("missing password must fail");

        assert!(error.to_string().contains("contraseña SSH"));
    }

    #[cfg(unix)]
    #[test]
    fn private_manufacturing_config_uses_mode_0600_and_is_removed_on_drop() {
        use std::os::unix::fs::PermissionsExt;

        let private = PrivateConfigFile::create(&manufacturing_config())
            .expect("create private manufacturing config");
        let path = private.path().to_path_buf();

        assert_eq!(
            std::fs::metadata(&path)
                .expect("private config metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let parsed = read_private_device_config(&path).expect("read private config");
        assert_eq!(parsed.serial_number.as_deref(), Some("SIGIL-TEST-0001"));
        drop(private);
        assert!(!path.exists());
    }

    #[test]
    fn provision_contains_identity_but_never_login_secrets() {
        let root = isolated_lock_dir("provision-identity-only");
        write_manufacturing_provision(&root, &manufacturing_config())
            .expect("write manufacturing provision");

        let raw = std::fs::read_to_string(root.join("boot/firmware/sigil_provision.json"))
            .expect("read manufacturing provision");
        let provision: serde_json::Value =
            serde_json::from_str(&raw).expect("parse manufacturing provision");
        assert_eq!(provision["serial_number"], "SIGIL-TEST-0001");
        assert_eq!(provision["model"], "Sigil-Streamer");
        assert_eq!(provision["model_version"], "v1");
        assert!(provision["capabilities"]["i2s_dac"].is_boolean());
        assert!(!raw.contains("ssh-test-80427159"));
        assert!(!raw.contains("80427159"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn hostname_is_applied_to_hostname_and_hosts() {
        let root = isolated_lock_dir("hostname");
        std::fs::create_dir_all(root.join("etc")).expect("create etc");
        std::fs::write(
            root.join("etc/hosts"),
            "127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n",
        )
        .expect("write hosts fixture");

        apply_hostname(&root, "sigil-lab-01").expect("apply hostname");

        assert_eq!(
            std::fs::read_to_string(root.join("etc/hostname")).expect("read hostname"),
            "sigil-lab-01\n"
        );
        let hosts = std::fs::read_to_string(root.join("etc/hosts")).expect("read hosts");
        assert!(hosts.contains("127.0.1.1\tsigil-lab-01"));
        assert!(!hosts.contains("raspberrypi"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn wifi_profile_and_ssh_dropin_have_safe_contents_and_modes() {
        use std::os::unix::fs::PermissionsExt;

        let root = isolated_lock_dir("network-config");
        let mut config = manufacturing_config();
        config.wifi_ssid = Some("SIGIL Lab".to_string());
        config.wifi_password = Some("wifi-test-password".to_string());

        provision_wifi_profile(&root, &config).expect("write Wi-Fi profile");
        write_ssh_dropin(&root, true).expect("write SSH drop-in");

        let wifi =
            root.join("etc/NetworkManager/system-connections/sigil-manufacturing.nmconnection");
        assert_eq!(
            std::fs::metadata(&wifi)
                .expect("Wi-Fi metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let ssh = std::fs::read_to_string(root.join("etc/ssh/sshd_config.d/90-sigil-access.conf"))
            .expect("read SSH drop-in");
        assert!(ssh.contains("PasswordAuthentication yes"));
        assert!(ssh.contains("AllowUsers sigil"));
        assert!(!ssh.contains("ssh-test-80427159"));
        let _ = std::fs::remove_dir_all(root);
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
