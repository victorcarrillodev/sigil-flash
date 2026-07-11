use crate::models::Device;
use crate::errors::{AppResult, AppError};
use std::process::Command;

pub struct DiskService;

impl DiskService {
    pub fn new() -> Self {
        Self
    }

    /// List physical block devices (USB / SD / MMC) across platforms.
    /// Excludes primary internal system disks for safety.
    pub async fn list_devices(&self) -> AppResult<Vec<Device>> {
        #[cfg(target_os = "linux")]
        {
            self.list_devices_linux().await
        }

        #[cfg(target_os = "macos")]
        {
            self.list_devices_macos().await
        }

        #[cfg(target_os = "windows")]
        {
            self.list_devices_windows().await
        }

        #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
        {
            Err(AppError::Disk("Plataforma no soportada para detección de discos".to_string()))
        }
    }

    // ============================================================
    // LINUX IMPLEMENTATION
    // ============================================================
    #[cfg(target_os = "linux")]
    async fn list_devices_linux(&self) -> AppResult<Vec<Device>> {
        use serde::Deserialize;

        #[derive(Debug, Deserialize)]
        struct LsblkOutput {
            blockdevices: Vec<LsblkDevice>,
        }

        #[derive(Debug, Deserialize)]
        struct LsblkDevice {
            name: String,
            size: Option<u64>,
            #[serde(rename = "type")]
            dev_type: Option<String>,
            tran: Option<String>,
            model: Option<String>,
            rm: Option<bool>, // removable
            ro: Option<bool>, // read-only
        }

        tracing::info!("Ejecutando lsblk para detectar dispositivos de almacenamiento...");

        let output = Command::new("lsblk")
            .args([
                "--json",
                "--bytes",
                "--output",
                "NAME,SIZE,TYPE,TRAN,MODEL,RM,RO",
                "--nodeps",
            ])
            .output()
            .map_err(|e| AppError::Disk(format!("No se pudo ejecutar lsblk: {}", e)))?;

        if !output.status.success() {
            let err_msg = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(AppError::Disk(format!("Error de lsblk: {}", err_msg)));
        }

        let json_str = String::from_utf8_lossy(&output.stdout);
        let lsblk: LsblkOutput = serde_json::from_str(&json_str)
            .map_err(|e| AppError::Disk(format!("Error parseando JSON de lsblk: {}", e)))?;

        let devices = lsblk
            .blockdevices
            .into_iter()
            .filter(|d| {
                let is_disk = d.dev_type.as_deref() == Some("disk");
                let is_removable = d.rm.unwrap_or(false);
                let tran = d.tran.as_deref().unwrap_or("");
                let is_usb_or_sd = tran == "usb" || tran == "mmc" || tran == "sd" || tran == "sdcard";
                let is_read_only = d.ro.unwrap_or(false);

                // Safe filter: must be a disk, must be writeable, and must be either marked removable
                // or connected via USB/MMC/SD card interface.
                is_disk && !is_read_only && (is_removable || is_usb_or_sd)
            })
            .map(|d| {
                let bytes = d.size.unwrap_or(0);
                let transport = d.tran.clone().unwrap_or_else(|| "unknown".to_string());
                Device {
                    path: format!("/dev/{}", d.name),
                    name: d.name.clone(),
                    size: format_bytes(bytes),
                    model: d.model.unwrap_or_else(|| "Dispositivo Genérico".to_string()).trim().to_string(),
                    device_type: "disk".to_string(),
                    removable: d.rm.unwrap_or(false),
                    transport,
                }
            })
            .collect();

        Ok(devices)
    }

    // ============================================================
    // MACOS IMPLEMENTATION
    // ============================================================
    #[cfg(target_os = "macos")]
    async fn list_devices_macos(&self) -> AppResult<Vec<Device>> {
        tracing::info!("Ejecutando diskutil para buscar unidades externas...");

        // Run 'diskutil list' to find external, physical disks
        let list_output = Command::new("diskutil")
            .arg("list")
            .output()
            .map_err(|e| AppError::Disk(format!("No se pudo ejecutar diskutil list: {}", e)))?;

        if !list_output.status.success() {
            let err_msg = String::from_utf8_lossy(&list_output.stderr).to_string();
            return Err(AppError::Disk(format!("Error de diskutil list: {}", err_msg)));
        }

        let list_str = String::from_utf8_lossy(&list_output.stdout);
        let mut target_disks = Vec::new();

        // Parse line-by-line looking for external physical disks
        // Example: "/dev/disk2 (external, physical):"
        for line in list_str.lines() {
            if line.contains("(external, physical)") && line.starts_with("/dev/") {
                if let Some(disk_path) = line.split_whitespace().next() {
                    target_disks.push(disk_path.to_string());
                }
            }
        }

        let mut devices = Vec::new();

        // For each physical disk found, query 'diskutil info' to fetch properties
        for disk_path in target_disks {
            let info_output = Command::new("diskutil")
                .args(["info", &disk_path])
                .output()
                .map_err(|e| AppError::Disk(format!("No se pudo consultar diskutil info para {}: {}", disk_path, e)))?;

            if !info_output.status.success() {
                continue;
            }

            let info_str = String::from_utf8_lossy(&info_output.stdout);
            let mut model = "Dispositivo Externo".to_string();
            let mut size_str = "0 B".to_string();
            let mut transport = "usb".to_string();
            let mut removable = true;

            for line in info_str.lines() {
                let parts: Vec<&str> = line.split(':').collect();
                if parts.len() < 2 {
                    continue;
                }
                let key = parts[0].trim();
                let val = parts[1..].join(":").trim().to_string();

                match key {
                    "Device / Media Name" | "Media Name" => {
                        model = val;
                    }
                    "Total Size" => {
                        // Total Size: 16.0 GB (16001269760 Bytes)
                        if let Some(pos) = val.find('(') {
                            size_str = val[..pos].trim().to_string();
                        } else {
                            size_str = val;
                        }
                    }
                    "Protocol" => {
                        transport = val.to_lowercase();
                    }
                    "Removable Media" => {
                        removable = val.to_lowercase().contains("removable");
                    }
                    _ => {}
                }
            }

            // Exclude read-only media or protocol system disks if any
            devices.push(Device {
                name: disk_path.trim_start_matches("/dev/").to_string(),
                path: disk_path,
                size: size_str,
                model,
                device_type: "disk".to_string(),
                removable,
                transport,
            });
        }

        Ok(devices)
    }

    // ============================================================
    // WINDOWS IMPLEMENTATION
    // ============================================================
    #[cfg(target_os = "windows")]
    async fn list_devices_windows(&self) -> AppResult<Vec<Device>> {
        use serde::Deserialize;

        #[derive(Debug, Deserialize)]
        struct WinDisk {
            FriendlyName: Option<String>,
            Number: u32,
            Size: u64,
            BusType: Option<String>,
            Model: Option<String>,
            Removable: Option<bool>,
        }

        tracing::info!("Ejecutando PowerShell Get-Disk para buscar unidades USB/SD...");

        // Invoke powershell command converting the output to json
        let ps_cmd = "Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.BusType -eq 'SD' -or $_.Removable } | Select-Object FriendlyName, Number, Size, BusType, Model, Removable | ConvertTo-Json";
        let output = Command::new("powershell")
            .args(["-NoProfile", "-Command", ps_cmd])
            .output()
            .map_err(|e| AppError::Disk(format!("No se pudo ejecutar PowerShell: {}", e)))?;

        if !output.status.success() {
            let err_msg = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(AppError::Disk(format!("PowerShell falló con: {}", err_msg)));
        }

        let json_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if json_str.is_empty() {
            return Ok(vec![]);
        }

        // ConvertTo-Json returns either a single object or an array. We handle both.
        let win_disks: Vec<WinDisk> = if json_str.starts_with('[') {
            serde_json::from_str(&json_str)
                .map_err(|e| AppError::Disk(format!("Error parseando array JSON de PowerShell: {}", e)))?
        } else {
            let single: WinDisk = serde_json::from_str(&json_str)
                .map_err(|e| AppError::Disk(format!("Error parseando objeto JSON de PowerShell: {}", e)))?;
            vec![single]
        };

        let devices = win_disks
            .into_iter()
            .map(|d| {
                let name = format!("PhysicalDrive{}", d.Number);
                let path = format!("\\\\.\\{}", name);
                let size_str = format_bytes(d.Size);
                let model = d.Model
                    .or(d.FriendlyName)
                    .unwrap_or_else(|| "Dispositivo USB/SD".to_string())
                    .trim()
                    .to_string();
                let transport = d.BusType.unwrap_or_else(|| "usb".to_string()).to_lowercase();
                Device {
                    name,
                    path,
                    size: size_str,
                    model,
                    device_type: "disk".to_string(),
                    removable: d.Removable.unwrap_or(true),
                    transport,
                }
            })
            .collect();

        Ok(devices)
    }
}

/// Helper function to format sizes in u64 bytes to human-readable strings.
fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;
    const TB: u64 = GB * 1024;

    if bytes >= TB {
        format!("{:.1} TB", bytes as f64 / TB as f64)
    } else if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
