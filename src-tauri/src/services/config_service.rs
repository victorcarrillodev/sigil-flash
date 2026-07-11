use crate::models::DeviceConfig;
use crate::errors::{AppResult, AppError};
use std::process::Command;

pub struct ConfigService;

impl ConfigService {
    pub fn new() -> Self {
        Self
    }

    /// Mounts the target partition on the block device, writes the custom config file and SSH triggers,
    /// and safely unmounts the volume.
    pub async fn write_config(&self, device_path: &str, config: &DeviceConfig) -> AppResult<()> {
        tracing::info!("Iniciando inyección de configuración en la unidad: {}", device_path);
        
        #[cfg(target_os = "linux")]
        {
            self.write_config_linux(device_path, config).await
        }

        #[cfg(target_os = "macos")]
        {
            self.write_config_macos(device_path, config).await
        }

        #[cfg(target_os = "windows")]
        {
            self.write_config_windows(device_path, config).await
        }

        #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
        {
            Err(AppError::Config("Plataforma no soportada para inyección de configuraciones".to_string()))
        }
    }

    // ============================================================
    // LINUX MOUNTING & WRITE
    // ============================================================
    #[cfg(target_os = "linux")]
    async fn write_config_linux(&self, device_path: &str, config: &DeviceConfig) -> AppResult<()> {
        // Boot is normally the first partition
        let partition = if device_path.contains("mmcblk") || device_path.contains("loop") {
            format!("{}p1", device_path)
        } else {
            format!("{}1", device_path)
        };

        let temp_mount = std::env::temp_dir().join("sigil-boot-mount");
        std::fs::create_dir_all(&temp_mount)?;

        tracing::info!("Ejecutando mount para la partición: {} en {}", partition, temp_mount.display());

        // Perform mount with elevated root permissions
        let mount_status = Command::new("pkexec")
            .args(["mount", &partition, &temp_mount.to_string_lossy()])
            .status()
            .map_err(|e| AppError::Config(format!("Fallo al ejecutar pkexec mount: {}", e)))?;

        if !mount_status.success() {
            return Err(AppError::Config(format!("Error montando la partición de arranque {}", partition)));
        }

        // Write configuration structure
        let config_file_path = temp_mount.join("device-config.json");
        let json_data = serde_json::to_string_pretty(config)?;
        std::fs::write(&config_file_path, json_data)?;
        tracing::info!("Archivo device-config.json inyectado exitosamente.");

        // If SSH is enabled, create empty trigger file
        if config.ssh_enabled {
            let ssh_file_path = temp_mount.join("ssh");
            std::fs::write(ssh_file_path, "")?;
            tracing::info!("Habilitador de SSH inyectado.");
        }

        // Safely unmount volume
        let umount_status = Command::new("pkexec")
            .args(["umount", &temp_mount.to_string_lossy()])
            .status()
            .map_err(|e| AppError::Config(format!("Fallo al ejecutar pkexec umount: {}", e)))?;

        let _ = std::fs::remove_dir(&temp_mount);

        if !umount_status.success() {
            return Err(AppError::Config("Fallo al desmontar volumen BOOT de forma limpia".to_string()));
        }

        Ok(())
    }

    // ============================================================
    // MACOS MOUNTING & WRITE
    // ============================================================
    #[cfg(target_os = "macos")]
    async fn write_config_macos(&self, device_path: &str, config: &DeviceConfig) -> AppResult<()> {
        let partition = format!("{}s1", device_path);
        let temp_mount = std::env::temp_dir().join("sigil-boot-mount");
        std::fs::create_dir_all(&temp_mount)?;

        tracing::info!("Montando partición macOS {} en {}", partition, temp_mount.display());

        let mount_status = Command::new("diskutil")
            .args(["mount", "readwrite", "-mountPoint", &temp_mount.to_string_lossy(), &partition])
            .status()
            .map_err(|e| AppError::Config(format!("Fallo al ejecutar diskutil mount: {}", e)))?;

        if !mount_status.success() {
            return Err(AppError::Config(format!("Error al montar partición de arranque {}", partition)));
        }

        let config_file_path = temp_mount.join("device-config.json");
        let json_data = serde_json::to_string_pretty(config)?;
        std::fs::write(&config_file_path, json_data)?;

        if config.ssh_enabled {
            let ssh_file_path = temp_mount.join("ssh");
            std::fs::write(ssh_file_path, "")?;
        }

        let umount_status = Command::new("diskutil")
            .args(["unmount", &partition])
            .status()
            .map_err(|e| AppError::Config(format!("Fallo al desmontar partición: {}", e)))?;

        let _ = std::fs::remove_dir(&temp_mount);

        if !umount_status.success() {
            return Err(AppError::Config("Fallo al desmontar partición de arranque".to_string()));
        }

        Ok(())
    }

    // ============================================================
    // WINDOWS VOLUMES RESOLUTION & WRITE
    // ============================================================
    #[cfg(target_os = "windows")]
    async fn write_config_windows(&self, device_path: &str, config: &DeviceConfig) -> AppResult<()> {
        let drive_number = device_path
            .trim_start_matches("\\\\.\\PhysicalDrive")
            .parse::<u32>()
            .map_err(|_| AppError::Config(format!("Ruta de disco de Windows inválida: {}", device_path)))?;

        tracing::info!("Resolviendo particiones de la unidad física número {}", drive_number);

        let json_escaped = serde_json::to_string(config)?.replace("\"", "`\"");
        
        let mut ps_script = format!(
            "$part = Get-Partition -DiskNumber {} -PartitionNumber 1; ", drive_number
        );
        ps_script.push_str(
            "$volume = $part | Get-Volume;
             $letter = $volume.DriveLetter;
             if (-not $letter) {
                 # Resolving available drive letters
                 $letter = (Get-Volume | Where-Object { $_.DriveLetter -match '^[D-Z]$' } | Select-Object -ExpandProperty DriveLetter | Compare-Object (44..90 | ForEach-Object { [char]$_ }) -PassThru | Select-Object -First 1);
                 Set-Partition -DiskNumber {} -PartitionNumber 1 -NewDriveLetter $letter;
                 Start-Sleep -Seconds 1;
             }
             $dest = \"$($letter):\\device-config.json\";
             \"{}\" | Out-File -FilePath $dest -Encoding utf8;
             ", drive_number, json_escaped
        );

        if config.ssh_enabled {
            ps_script.push_str("New-Item -Path \"$($letter):\\ssh\" -ItemType File -Force; ");
        }

        let output = Command::new("powershell")
            .args(["-NoProfile", "-Command", &ps_script])
            .output()
            .map_err(|e| AppError::Config(format!("Fallo al ejecutar PowerShell: {}", e)))?;

        if !output.status.success() {
            let err_msg = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(AppError::Config(format!("PowerShell devolvió error al inyectar: {}", err_msg)));
        }

        tracing::info!("Inyección completada exitosamente en Windows.");
        Ok(())
    }
}
