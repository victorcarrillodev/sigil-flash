use crate::errors::{Result, SigilError};
use crate::models::{DeviceConfig, FlashProgress};
use crate::services::provision::validate_model_supports_architecture;
use crate::services::bundle::{
    default_artifacts_root, resolve_bundle_payload, validate_ssh_profile_available, BundlePair,
};
use crate::services::config::{validate_device_config, PrivateConfigGuard};
use crate::services::progress::{read_progress_file, resolve_final_progress};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tracing::info;

static CANCEL_FLAG: AtomicBool = AtomicBool::new(false);

pub const PROGRESS_EVENT: &str = "flash-progress";

fn progress_file_path() -> PathBuf {
    std::env::temp_dir().join("sigil-flash-progress.json")
}

/// El escritor privilegiado imprime su error real por stderr y corre como root,
/// así que su `tracing` va al home de root: si no se recoge aquí, el operario se
/// queda con un mensaje genérico. Va a un archivo y no a una tubería a
/// propósito: el lanzador sondea con `try_wait` sin drenar el descriptor, y una
/// tubería llena bloquearía al escritor a mitad de la fabricación.
struct ElevatedStderr {
    path: PathBuf,
}

impl ElevatedStderr {
    fn create() -> std::io::Result<Self> {
        let path = std::env::temp_dir().join(format!("sigil-flash-elevated-{}.err", std::process::id()));
        let _ = std::fs::remove_file(&path);
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        Ok(Self { path })
    }

    fn as_stdio(&self) -> std::io::Result<std::process::Stdio> {
        Ok(std::process::Stdio::from(
            std::fs::OpenOptions::new().append(true).open(&self.path)?,
        ))
    }

    fn read(&self) -> String {
        std::fs::read_to_string(&self.path).unwrap_or_default()
    }
}

impl Drop for ElevatedStderr {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Relanza el propio binario elevado. El flujo real de fabricación solo se
/// soporta en Linux; en macOS y Windows la elevación queda declarada pero el
/// resto del flujo no está validado (documentado en el README).
fn elevated_command(exe: &Path, args: &[String]) -> Command {
    #[cfg(target_os = "linux")]
    {
        let mut cmd = Command::new("pkexec");
        cmd.arg(exe);
        cmd.args(args);
        cmd
    }
    #[cfg(target_os = "macos")]
    {
        let joined = std::iter::once(exe.display().to_string())
            .chain(args.iter().cloned())
            .collect::<Vec<_>>()
            .join(" ");
        let mut cmd = Command::new("osascript");
        cmd.arg("-e").arg(format!(
            "do shell script \"{}\" with administrator privileges",
            joined
        ));
        cmd
    }
    #[cfg(target_os = "windows")]
    {
        let joined = args.join("','");
        let mut cmd = Command::new("powershell");
        cmd.arg("-Command").arg(format!(
            "Start-Process -FilePath '{}' -ArgumentList '{}' -Verb RunAs -Wait",
            exe.display(),
            joined
        ));
        cmd
    }
}

#[tauri::command]
pub fn resolve_bundle(image_name: String, variant: Option<String>) -> Result<BundlePair> {
    resolve_bundle_payload(&default_artifacts_root(), &image_name, variant.as_deref())
}

#[tauri::command]
pub async fn start_flash(
    app: AppHandle,
    src_image: String,
    dest_device: String,
    config: DeviceConfig,
    variant: Option<String>,
) -> Result<FlashProgress> {
    validate_device_config(&config)?;
    CANCEL_FLAG.store(false, Ordering::SeqCst);

    let image_path = PathBuf::from(&src_image);
    let image_name = image_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| SigilError::Validation("Ruta de imagen sin nombre de archivo".to_string()))?;

    // La resolución del par ocurre ANTES de escribir un solo byte: un payload
    // sin su repositorio nunca llega al proceso elevado.
    let pair = resolve_bundle_payload(&default_artifacts_root(), image_name, variant.as_deref())?;

    // Antes de pedir la elevación: si el bundle no puede satisfacer el perfil
    // que la configuración activa, el fallo llegaría dentro del chroot con la
    // tarjeta ya escrita.
    validate_ssh_profile_available(&pair, config.ssh_enabled)?;

    // Modelo contra arquitectura de la imagen: una Zero W no arranca arm64 y
    // una Pi 5 no arranca armhf. Sin esta comprobación la fabricación terminaba
    // anunciando éxito y entregaba una tarjeta que no arranca.
    if let Some(model) = &config.rpi_model {
        validate_model_supports_architecture(model, &pair.architecture)?;
    }

    info!(
        "Fabricando con el contrato '{}' ({}) para la imagen '{}'",
        pair.contract_name, pair.architecture, image_name
    );

    let progress_file = progress_file_path();
    let _ = std::fs::remove_file(&progress_file);

    // La configuración privada nace 0600 y se destruye con la guarda aunque
    // el flasheo falle: no se dejan secretos en el directorio temporal.
    let config_guard = PrivateConfigGuard::create(&std::env::temp_dir(), &config)?;

    let exe_path = std::env::current_exe()?;
    let args: Vec<String> = vec![
        "--flash-raw".to_string(),
        "--src".to_string(),
        src_image.clone(),
        "--dest".to_string(),
        dest_device.clone(),
        "--progress-file".to_string(),
        progress_file.display().to_string(),
        "--offline-packages".to_string(),
        pair.repo.display().to_string(),
        "--payload".to_string(),
        pair.payload.display().to_string(),
        "--config-file".to_string(),
        config_guard.path().display().to_string(),
    ];

    let stderr_sink = ElevatedStderr::create().map_err(|e| {
        SigilError::Flash(format!(
            "No se pudo preparar la recogida de errores del proceso elevado: {}",
            e
        ))
    })?;

    let mut command = elevated_command(&exe_path, &args);
    if let Ok(sink) = stderr_sink.as_stdio() {
        command.stderr(sink);
    }

    let mut child = command.spawn().map_err(|e| {
        SigilError::Flash(format!(
            "Error al elevar privilegios: {}. Verifique que pkexec (policykit-1) esté instalado.",
            e
        ))
    })?;

    let start_time = Instant::now();
    let timeout = Duration::from_secs(45 * 60);
    let mut last_emitted: Option<FlashProgress> = None;

    loop {
        if CANCEL_FLAG.load(Ordering::SeqCst) {
            let _ = child.kill();
            let cancelled = FlashProgress {
                bytes_written: 0,
                total_bytes: 0,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status: "cancelled".to_string(),
                message: "Proceso cancelado por el operador".to_string(),
            };
            let _ = app.emit(PROGRESS_EVENT, &cancelled);
            return Ok(cancelled);
        }

        if start_time.elapsed() > timeout {
            let _ = child.kill();
            return Err(SigilError::Flash(
                "Tiempo de espera agotado: la fabricación superó los 45 minutos".to_string(),
            ));
        }

        // Se relee el archivo del escritor y se reemite como evento Tauri.
        if let Ok(Some(progress)) = read_progress_file(&progress_file) {
            if last_emitted.as_ref() != Some(&progress) {
                let _ = app.emit(PROGRESS_EVENT, &progress);
                last_emitted = Some(progress);
            }
        }

        match child.try_wait() {
            Ok(Some(status)) => {
                let exit_duration = start_time.elapsed();
                // Margen de gracia: el escritor puede publicar su estado final
                // justo después de que el lanzador salga.
                tokio::time::sleep(Duration::from_secs(2)).await;
                let last_prog = read_progress_file(&progress_file).ok().flatten();
                let stderr = stderr_sink.read();
                if !status.success() && !stderr.trim().is_empty() {
                    // El escritor corre como root y registra en el home de root:
                    // este es el único sitio donde su error queda en los logs
                    // del operario.
                    tracing::error!("El proceso elevado falló. stderr: {}", stderr.trim());
                }
                let final_state =
                    resolve_final_progress(last_prog, status.code(), &stderr, exit_duration);
                let _ = app.emit(PROGRESS_EVENT, &final_state);
                return Ok(final_state);
            }
            Ok(None) => {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Err(e) => {
                return Err(SigilError::Flash(format!(
                    "Error monitoreando el proceso elevado: {}",
                    e
                )));
            }
        }
    }
}

#[tauri::command]
pub fn cancel_flash() -> Result<bool> {
    CANCEL_FLAG.store(true, Ordering::SeqCst);
    info!("Cancelación de flasheo solicitada por el operador");
    Ok(true)
}

#[tauri::command]
pub fn get_flash_progress() -> Result<Option<FlashProgress>> {
    read_progress_file(&progress_file_path())
}
