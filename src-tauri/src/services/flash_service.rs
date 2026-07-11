use crate::errors::{AppResult, AppError};
use crate::models::FlashProgress;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;
use tauri::{AppHandle, Emitter};
use std::time::{Instant, Duration};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub struct FlashService {
    // Stores the active child process spawn handle for cancellation
    active_process: Arc<Mutex<Option<tokio::process::Child>>>,
}

impl FlashService {
    pub fn new() -> Self {
        Self {
            active_process: Arc::new(Mutex::new(None)),
        }
    }

    /// Spawns the elevated writer child process and polls its progress file.
    pub async fn start_flash(
        &self,
        image_path: &str,
        device_path: &str,
        app: AppHandle,
    ) -> AppResult<()> {
        let image_p = PathBuf::from(image_path);
        let device_p = PathBuf::from(device_path);

        if !image_p.exists() {
            return Err(AppError::Validation("La ruta del archivo de imagen no existe".to_string()));
        }

        // 1. Establish progress monitoring file in temp directory
        let progress_file = std::env::temp_dir().join("sigil-flash-progress.json");
        if progress_file.exists() {
            let _ = std::fs::remove_file(&progress_file);
        }

        // Initialize progress state
        let image_size = std::fs::metadata(&image_p)?.len();
        let _ = app.emit("flash-progress", FlashProgress {
            bytes_written: 0,
            total_bytes: image_size,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: "Iniciando proceso de elevación de privilegios...".to_string(),
        });

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
        let mut success = false;

        loop {
            // Check if process finished
            {
                let mut guard = self.active_process.lock().await;
                if let Some(ref mut c) = *guard {
                    if let Ok(Some(status)) = c.try_wait() {
                        success = status.success();
                        *guard = None;
                        break;
                    }
                } else {
                    break;
                }
            }

            // Read progress file
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
                        
                        let _ = app.emit("flash-progress", FlashProgress {
                            bytes_written: current_bytes,
                            total_bytes: image_size,
                            speed_mbps: speed,
                            eta_seconds: eta,
                            status: progress.status,
                            message: progress.message,
                        });
                    }
                }
            }

            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        // Cleanup progress file
        if progress_file.exists() {
            let _ = std::fs::remove_file(&progress_file);
        }

        if success {
            let _ = app.emit("flash-progress", FlashProgress {
                bytes_written: image_size,
                total_bytes: image_size,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status: "done".to_string(),
                message: "Flasheo completado y sincronizado exitosamente.".to_string(),
            });
            Ok(())
        } else {
            let _ = app.emit("flash-progress", FlashProgress {
                bytes_written: last_bytes,
                total_bytes: image_size,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status: "error".to_string(),
                message: "Error de ejecución: proceso de escritura cancelado o fallido".to_string(),
            });
            Err(AppError::Flash("El proceso de flasheo terminó con fallos".to_string()))
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
        cmd.spawn().map_err(|e| AppError::Flash(format!("Error iniciando pkexec: {}", e)))
    }

    #[cfg(target_os = "macos")]
    {
        tracing::info!("Elevando privilegios en macOS usando osascript...");
        let cmd_str = format!("'{}' {}", _exe_str, args.join(" "));
        let script = format!("do shell script \"{}\" with administrator privileges", cmd_str);
        
        let mut cmd = tokio::process::Command::new("osascript");
        cmd.args(["-e", &script]);
        cmd.spawn().map_err(|e| AppError::Flash(format!("Error iniciando osascript: {}", e)))
    }

    #[cfg(target_os = "windows")]
    {
        tracing::info!("Elevando privilegios en Windows usando PowerShell RunAs...");
        let escaped_args = args.iter()
            .map(|a| format!("'{}'", a))
            .collect::<Vec<String>>()
            .join(", ");
        
        let ps_cmd = format!(
            "Start-Process -FilePath '{}' -ArgumentList {} -Verb RunAs -WindowStyle Hidden -PassThru",
            _exe_str, escaped_args
        );

        let mut cmd = tokio::process::Command::new("powershell");
        cmd.args(["-NoProfile", "-Command", &ps_cmd]);
        cmd.spawn().map_err(|e| AppError::Flash(format!("Error iniciando PowerShell elevated: {}", e)))
    }
}

/// Raw block-by-block image copier executing under administrative rights.
/// Periodically saves status to the progress file.
pub async fn run_raw_flash_cli(
    src: &str,
    dest: &str,
    progress_file: &str,
) -> AppResult<()> {
    // Safety verification check: Block writing to critical mountpoints on Linux/macOS
    #[cfg(unix)]
    {
        let system_disks = ["/dev/sda", "/dev/nvme0n1"]; // Example primary drives
        if system_disks.contains(&dest) {
            return Err(AppError::Flash(format!("RECHAZADO: Se detectó intento de flashear disco del sistema principal: {}", dest)));
        }
    }

    let src_path = PathBuf::from(src);
    let dest_path = PathBuf::from(dest);
    let prog_path = PathBuf::from(progress_file);

    let mut src_file = File::open(&src_path)
        .await
        .map_err(|e| AppError::Flash(format!("No se pudo abrir imagen: {}", e)))?;

    let total_bytes = src_file.metadata().await?.len();
    
    // Open physical drive for writing (Direct Sync Mode if possible depending on OS)
    let mut dest_file = File::create(&dest_path)
        .await
        .map_err(|e| AppError::Flash(format!("No se pudo abrir unidad física para escritura: {}", e)))?;

    let mut buffer = vec![0; 4 * 1024 * 1024]; // 4MB buffer
    let mut bytes_written = 0u64;

    while bytes_written < total_bytes {
        let read_len = src_file.read(&mut buffer)
            .await
            .map_err(|e| AppError::Io(e))?;

        if read_len == 0 {
            break;
        }

        dest_file.write_all(&buffer[..read_len])
            .await
            .map_err(|e| AppError::Io(e))?;

        bytes_written += read_len as u64;

        // Write progress state
        let progress = FlashProgress {
            bytes_written,
            total_bytes,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: format!("Escribiendo bloques a la unidad... {:.1}%", (bytes_written as f64 / total_bytes as f64) * 100.0),
        };

        if let Ok(json) = serde_json::to_string(&progress) {
            let _ = std::fs::write(&prog_path, json);
        }
    }

    // Force synchronization of buffers to physical platter
    dest_file.sync_all().await?;

    let final_progress = FlashProgress {
        bytes_written: total_bytes,
        total_bytes,
        speed_mbps: 0.0,
        eta_seconds: 0.0,
        status: "done".to_string(),
        message: "Escritura de imagen completada exitosamente".to_string(),
    };
    if let Ok(json) = serde_json::to_string(&final_progress) {
        let _ = std::fs::write(&prog_path, json);
    }

    Ok(())
}
