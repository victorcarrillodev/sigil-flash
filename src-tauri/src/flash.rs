use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

// ============================================================
// Types
// ============================================================

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Device {
    pub name: String,
    pub path: String,
    pub size: String,
    pub model: String,
    pub transport: String,
    pub removable: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ImageInfo {
    pub path: String,
    pub name: String,
    pub size: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FlashProgress {
    pub bytes_written: u64,
    pub total_bytes: u64,
    pub speed_mbps: f64,
    pub eta_seconds: f64,
    pub status: String, // "running" | "done" | "error" | "cancelled"
    pub message: String,
}

// Global flash process handle for cancellation
pub struct FlashState {
    pub pid: Option<u32>,
}

pub type FlashStateMutex = Arc<Mutex<FlashState>>;

// ============================================================
// lsblk JSON types
// ============================================================

#[derive(Debug, Deserialize)]
struct LsblkOutput {
    blockdevices: Vec<LsblkDevice>,
}

#[derive(Debug, Deserialize)]
struct LsblkDevice {
    name: String,
    size: Option<String>,
    #[serde(rename = "type")]
    dev_type: Option<String>,
    tran: Option<String>,
    model: Option<String>,
    rm: Option<bool>, // removable
}

// ============================================================
// Commands
// ============================================================

/// List removable block devices (USB / SD / MMC)
#[tauri::command]
pub async fn list_devices() -> Result<Vec<Device>, String> {
    let output = Command::new("lsblk")
        .args([
            "--json",
            "--output",
            "NAME,SIZE,TYPE,TRAN,MODEL,RM",
            "--nodeps", // no partitions, only whole disks
        ])
        .output()
        .map_err(|e| format!("No se pudo ejecutar lsblk: {e}"))?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }

    let json_str = String::from_utf8_lossy(&output.stdout);
    let lsblk: LsblkOutput =
        serde_json::from_str(&json_str).map_err(|e| format!("Error parseando lsblk: {e}"))?;

    let devices = lsblk
        .blockdevices
        .into_iter()
        .filter(|d| {
            // Only show: disk type AND (removable OR transport is usb/mmc/sd)
            let is_disk = d.dev_type.as_deref() == Some("disk");
            let is_removable = d.rm.unwrap_or(false);
            let tran = d.tran.as_deref().unwrap_or("");
            let is_removable_transport =
                tran == "usb" || tran == "mmc" || tran == "sd" || tran == "sdcard";
            is_disk && (is_removable || is_removable_transport)
        })
        .map(|d| {
            let tran = d.tran.clone().unwrap_or_default();
            Device {
                path: format!("/dev/{}", d.name),
                name: d.name.clone(),
                size: d.size.unwrap_or_else(|| "?".to_string()),
                model: d
                    .model
                    .unwrap_or_default()
                    .trim()
                    .to_string(),
                transport: tran,
                removable: d.rm.unwrap_or(false),
            }
        })
        .collect();

    Ok(devices)
}

/// Get basic info about an image file
#[tauri::command]
pub async fn get_image_info(path: String) -> Result<ImageInfo, String> {
    let metadata =
        std::fs::metadata(&path).map_err(|e| format!("No se pudo leer el archivo: {e}"))?;

    if !metadata.is_file() {
        return Err("La ruta no es un archivo válido.".to_string());
    }

    let name = std::path::Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let mut size = metadata.len();
    if path.to_lowercase().ends_with(".xz") {
        if let Ok(uncompressed) = get_xz_uncompressed_size(&path) {
            size = uncompressed;
        }
    }

    Ok(ImageInfo {
        path,
        name,
        size,
    })
}

/// Start flashing an image to a device using dd via pkexec
#[tauri::command]
pub async fn start_flash(
    image_path: String,
    device_path: String,
    app: AppHandle,
    state: tauri::State<'_, FlashStateMutex>,
) -> Result<(), String> {
    // Validate paths
    if !std::path::Path::new(&image_path).exists() {
        return Err("El archivo de imagen no existe.".to_string());
    }

    if !device_path.starts_with("/dev/") {
        return Err("Ruta de dispositivo inválida.".to_string());
    }

    // Safety check: never allow writing to likely system disks
    let safe_transports = ["usb", "mmc", "sd", "sdcard"];
    let lsblk_output = Command::new("lsblk")
        .args([
            "--json", "--output", "NAME,TRAN,RM", "--nodeps",
            device_path.trim_start_matches("/dev/"),
        ])
        .output();

    if let Ok(out) = lsblk_output {
        let json = String::from_utf8_lossy(&out.stdout);
        if let Ok(parsed) = serde_json::from_str::<LsblkOutput>(&json) {
            if let Some(dev) = parsed.blockdevices.first() {
                let tran = dev.tran.as_deref().unwrap_or("");
                let removable = dev.rm.unwrap_or(false);
                if !removable && !safe_transports.contains(&tran) {
                    return Err(format!(
                        "⛔ Dispositivo {} rechazado: no parece ser extraíble (transport: '{}'). Por seguridad, solo se permiten dispositivos USB/SD.",
                        device_path, tran
                    ));
                }
            }
        }
    }

    let is_xz = image_path.to_lowercase().ends_with(".xz");

    // Get image size for progress tracking
    let image_size = if is_xz {
        get_xz_uncompressed_size(&image_path).unwrap_or_else(|_| {
            std::fs::metadata(&image_path)
                .map(|m| m.len())
                .unwrap_or(0)
        })
    } else {
        std::fs::metadata(&image_path)
            .map(|m| m.len())
            .unwrap_or(0)
    };

    // Emit initial progress
    let _ = app.emit(
        "flash-progress",
        FlashProgress {
            bytes_written: 0,
            total_bytes: image_size,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: format!("Iniciando dd: {} → {}", image_path, device_path),
        },
    );

    // Build dd command via pkexec for privilege escalation
    // If it's a .xz file, decompress on the fly using xzcat
    let dd_cmd = if is_xz {
        format!(
            "xzcat {} | dd bs=4M of={} status=progress oflag=sync 2>&1",
            shell_escape(&image_path),
            shell_escape(&device_path)
        )
    } else {
        format!(
            "dd bs=4M if={} of={} status=progress oflag=sync 2>&1",
            shell_escape(&image_path),
            shell_escape(&device_path)
        )
    };

    let mut child = Command::new("pkexec")
        .args(["sh", "-c", &dd_cmd])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("No se pudo iniciar pkexec: {e}. ¿Está polkit instalado?"))?;

    // Store PID for cancellation
    let pid = child.id();
    {
        let mut guard = state.lock().unwrap();
        guard.pid = Some(pid);
    }

    let _ = app.emit(
        "flash-progress",
        FlashProgress {
            bytes_written: 0,
            total_bytes: image_size,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: "Proceso dd iniciado, esperando datos...".to_string(),
        },
    );

    // Read dd's progress output (stderr in real dd, combined here)
    let stderr = child.stderr.take().unwrap();
    let stdout = child.stdout.take().unwrap();

    // dd writes progress to stderr; we capture stdout for normal output
    // Using combined 2>&1, all goes to stdout
    let reader = BufReader::new(stdout);
    let app_clone = app.clone();
    let state_clone = state.inner().clone();
    let _ = state_clone; // just to avoid warnings

    let mut last_bytes: u64 = 0;
    let mut last_time = std::time::Instant::now();

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        let trimmed = line.trim().to_string();
        if trimmed.is_empty() {
            continue;
        }

        // Parse dd progress line: "102400000 bytes (102 MB, 98 MiB) copied, 5 s, 20.5 MB/s"
        let (bytes_written, speed_mbps) = parse_dd_progress(&trimmed)
            .unwrap_or((last_bytes, 0.0));

        let now = std::time::Instant::now();
        let elapsed = now.duration_since(last_time).as_secs_f64();
        let actual_speed = if elapsed > 0.5 && bytes_written > last_bytes {
            ((bytes_written - last_bytes) as f64 / elapsed) / (1024.0 * 1024.0)
        } else {
            speed_mbps
        };

        let eta = if actual_speed > 0.1 && image_size > bytes_written {
            ((image_size - bytes_written) as f64) / (actual_speed * 1024.0 * 1024.0)
        } else {
            0.0
        };

        last_bytes = bytes_written;
        last_time = now;

        let is_progress_line = trimmed.contains("bytes") && trimmed.contains("copied");
        let msg_type = if is_progress_line {
            format!("📝 {} bytes escritos", format_bytes(bytes_written))
        } else {
            trimmed.clone()
        };

        let _ = app_clone.emit(
            "flash-progress",
            FlashProgress {
                bytes_written,
                total_bytes: image_size,
                speed_mbps: actual_speed,
                eta_seconds: eta,
                status: "running".to_string(),
                message: msg_type,
            },
        );
    }

    // Drop stderr reader (not used in combined mode)
    drop(stderr);

    // Wait for process to finish
    let exit_status = child.wait().map_err(|e| format!("Error esperando proceso: {e}"))?;

    // Clear PID
    {
        let mut guard = state.lock().unwrap();
        guard.pid = None;
    }

    if exit_status.success() {
        // Sync to ensure data is flushed
        let _ = Command::new("sync").status();

        let _ = app.emit(
            "flash-progress",
            FlashProgress {
                bytes_written: image_size,
                total_bytes: image_size,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status: "done".to_string(),
                message: "✅ Flasheo completado exitosamente. Puedes retirar el dispositivo.".to_string(),
            },
        );
        Ok(())
    } else {
        let code = exit_status.code().unwrap_or(-1);
        let (status, msg) = if code == 126 || code == 127 {
            ("cancelled".to_string(), "Operación cancelada o permisos denegados.".to_string())
        } else {
            ("error".to_string(), format!("dd terminó con código de error: {}", code))
        };

        let _ = app.emit(
            "flash-progress",
            FlashProgress {
                bytes_written: last_bytes,
                total_bytes: image_size,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status,
                message: msg.clone(),
            },
        );
        Err(msg)
    }
}

/// Cancel an ongoing flash operation
#[tauri::command]
pub async fn cancel_flash(state: tauri::State<'_, FlashStateMutex>) -> Result<(), String> {
    let pid = {
        let guard = state.lock().unwrap();
        guard.pid
    };

    if let Some(pid) = pid {
        // Send SIGTERM to the pkexec process group
        let _ = Command::new("pkexec")
            .args(["kill", "-TERM", &pid.to_string()])
            .status();

        // Also try direct kill
        let _ = Command::new("kill")
            .args(["-TERM", &pid.to_string()])
            .status();

        Ok(())
    } else {
        Err("No hay ningún proceso de flasheo activo.".to_string())
    }
}

// ============================================================
// Helpers
// ============================================================

/// Parse dd progress line like:
/// "102400000 bytes (102 MB, 97.7 MiB) copied, 5.23 s, 19.6 MB/s"
fn parse_dd_progress(line: &str) -> Option<(u64, f64)> {
    // Check for the pattern
    if !line.contains("bytes") || !line.contains("copied") {
        return None;
    }

    // Parse bytes at start
    let bytes: u64 = line
        .split_whitespace()
        .next()?
        .parse()
        .ok()?;

    // Parse speed at end: "19.6 MB/s"
    let speed = if let Some(pos) = line.rfind(',') {
        let speed_str = line[pos + 1..].trim();
        // Remove " MB/s"
        speed_str
            .replace("MB/s", "")
            .trim()
            .parse::<f64>()
            .unwrap_or(0.0)
    } else {
        0.0
    };

    Some((bytes, speed))
}

/// Get uncompressed size of a .xz file using xz --robot -l
fn get_xz_uncompressed_size(path: &str) -> Result<u64, String> {
    let output = Command::new("xz")
        .args(["--robot", "-l", path])
        .output()
        .map_err(|e| format!("No se pudo ejecutar xz: {e}"))?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
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

    Err("No se pudo obtener el tamaño descomprimido del archivo xz.".to_string())
}

/// Basic shell escaping for paths (wraps in single quotes)
fn shell_escape(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Format bytes to human readable
fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
