use crate::errors::{AppError, AppResult};
use crate::models::FlashProgress;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;

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
            return Err(AppError::Validation(
                "La ruta del archivo de imagen no existe".to_string(),
            ));
        }

        // 1. Establish progress monitoring file in temp directory
        let progress_file = std::env::temp_dir().join("sigil-flash-progress.json");
        if progress_file.exists() {
            let _ = std::fs::remove_file(&progress_file);
        }

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

                        let _ = app.emit(
                            "flash-progress",
                            FlashProgress {
                                bytes_written: current_bytes,
                                total_bytes: image_size,
                                speed_mbps: speed,
                                eta_seconds: eta,
                                status: progress.status,
                                message: progress.message,
                            },
                        );
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
            let _ = app.emit(
                "flash-progress",
                FlashProgress {
                    bytes_written: image_size,
                    total_bytes: image_size,
                    speed_mbps: 0.0,
                    eta_seconds: 0.0,
                    status: "done".to_string(),
                    message: "Flasheo completado y sincronizado exitosamente.".to_string(),
                },
            );
            Ok(())
        } else {
            let _ = app.emit(
                "flash-progress",
                FlashProgress {
                    bytes_written: last_bytes,
                    total_bytes: image_size,
                    speed_mbps: 0.0,
                    eta_seconds: 0.0,
                    status: "error".to_string(),
                    message: "Error de ejecución: proceso de escritura cancelado o fallido"
                        .to_string(),
                },
            );
            Err(AppError::Flash(
                "El proceso de flasheo terminó con fallos".to_string(),
            ))
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

/// Raw block-by-block image copier executing under administrative rights.
/// Periodically saves status to the progress file.
pub async fn run_raw_flash_cli(src: &str, dest: &str, progress_file: &str) -> AppResult<()> {
    // Safety verification check: Block writing to critical mountpoints on Linux/macOS
    #[cfg(unix)]
    {
        let system_disks = ["/dev/sda", "/dev/nvme0n1"]; // Example primary drives
        if system_disks.contains(&dest) {
            return Err(AppError::Flash(format!(
                "RECHAZADO: Se detectó intento de flashear disco del sistema principal: {}",
                dest
            )));
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

    if let Some(mut child) = xz_child {
        let _ = child.wait().await;
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
    if let Err(e) = install_sigil_hardware(dest) {
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
    } else if path.starts_with("/dev/sd") || path.starts_with("/dev/hd") || path.starts_with("/dev/vd") {
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
        return Err(AppError::Flash(String::from_utf8_lossy(&output.stderr).to_string()));
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

    Err(AppError::Flash("No se pudo obtener el tamaño descomprimido del archivo xz.".to_string()))
}

fn install_sigil_hardware(device: &str) -> AppResult<()> {
    let part2 = if device.contains("mmcblk") || device.contains("nvme") || device.contains("loop") {
        format!("{}p2", device)
    } else {
        format!("{}2", device)
    };

    println!("Recargando tabla de particiones en {}...", device);
    let _ = std::process::Command::new("partprobe").arg(device).status();
    std::thread::sleep(std::time::Duration::from_millis(1000));

    let mount_dir = "/tmp/sigil-rootfs";
    let _ = std::fs::create_dir_all(mount_dir);

    // Intentar desmontar por si acaso quedó colgado de una ejecución anterior
    let _ = std::process::Command::new("umount").arg(mount_dir).status();

    println!("Montando partición raíz {} en {}...", part2, mount_dir);
    let mut mount_status = std::process::Command::new("mount")
        .args(&[&part2, mount_dir])
        .status();

    // Reintentar hasta 3 veces por si el kernel tarda en registrar las particiones tras el flasheo de bloques raw
    for i in 1..=3 {
        if mount_status.is_ok() && mount_status.as_ref().unwrap().success() {
            break;
        }
        println!("Intento {} de montaje falló o demoró. Esperando y reintentando...", i);
        std::thread::sleep(std::time::Duration::from_millis(2000));
        let _ = std::process::Command::new("partprobe").arg(device).status();
        mount_status = std::process::Command::new("mount")
            .args(&[&part2, mount_dir])
            .status();
    }

    if mount_status.is_err() || !mount_status.unwrap().success() {
        return Err(AppError::Flash(format!(
            "No se pudo montar la partición raíz {}. Verifica que la imagen se haya grabado correctamente y contenga particiones ext4.",
            part2
        )));
    }

    println!("Copiando repositorio sigil-hardware a la microSD...");
    let opt_dir = format!("{}/opt", mount_dir);
    let _ = std::fs::create_dir_all(&opt_dir);

    let copy_status = std::process::Command::new("cp")
        .args(&["-r", "/home/dev-pro/Escritorio/sigil-flash/sigil-hardware", &opt_dir])
        .status();

    if copy_status.is_err() || !copy_status.unwrap().success() {
        let _ = std::process::Command::new("umount").arg(mount_dir).status();
        return Err(AppError::Flash("Error al copiar los archivos de sigil-hardware a la partición raíz.".to_string()));
    }

    println!("Configurando el script de primer arranque (firstboot.sh)...");
    let firstboot_path = format!("{}/usr/local/bin/sigil-firstboot.sh", mount_dir);
    let firstboot_content = r#"#!/bin/bash
exec > /var/log/sigil-firstboot.log 2>&1
echo "=== Iniciando instalación de Sigil-Hardware en primer arranque ==="

cd /opt/sigil-hardware

chmod +x install.sh

# Ejecutar el instalador de Sigil-Hardware
bash install.sh

# Habilitar lingering e inicio en arranque
loginctl enable-linger sigil || true

# Restaurar rc.local original
if [ -f /etc/rc.local.orig ]; then
    mv /etc/rc.local.orig /etc/rc.local
else
    echo '#!/bin/sh -e' > /etc/rc.local
    echo 'exit 0' >> /etc/rc.local
    chmod +x /etc/rc.local
fi

echo "=== Instalación completada con éxito. Reiniciando... ==="
reboot
"#;

    if let Err(e) = std::fs::write(&firstboot_path, firstboot_content) {
        let _ = std::process::Command::new("umount").arg(mount_dir).status();
        return Err(AppError::Flash(format!("No se pudo escribir el script de primer arranque: {}", e)));
    }

    let _ = std::process::Command::new("chmod")
        .args(&["+x", &firstboot_path])
        .status();

    println!("Configurando rc.local para la ejecución en el primer encendido...");
    let rc_local_path = format!("{}/etc/rc.local", mount_dir);
    let rc_local_orig = format!("{}/etc/rc.local.orig", mount_dir);

    if std::path::Path::new(&rc_local_path).exists() {
        let _ = std::fs::copy(&rc_local_path, &rc_local_orig);
    }

    let rc_local_content = r#"#!/bin/bash
/usr/local/bin/sigil-firstboot.sh &
exit 0
"#;

    if let Err(e) = std::fs::write(&rc_local_path, rc_local_content) {
        let _ = std::process::Command::new("umount").arg(mount_dir).status();
        return Err(AppError::Flash(format!("No se pudo configurar /etc/rc.local: {}", e)));
    }

    let _ = std::process::Command::new("chmod")
        .args(&["+x", &rc_local_path])
        .status();

    println!("Desmontando partición raíz...");
    let umount_status = std::process::Command::new("umount")
        .arg(mount_dir)
        .status();

    if umount_status.is_err() || !umount_status.unwrap().success() {
        return Err(AppError::Flash("Fallo al desmontar la partición de la microSD de manera segura.".to_string()));
    }

    let _ = std::fs::remove_dir(mount_dir);
    println!("Instalación de sigil-hardware en la microSD preparada con éxito.");
    Ok(())
}
