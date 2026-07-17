use crate::errors::{AppError, AppResult};
use crate::models::DeviceConfig;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct ConfigService;

impl ConfigService {
    pub fn new() -> Self {
        Self
    }

    /// Mounts the target partition on the block device, writes the custom config file and SSH triggers,
    /// and safely unmounts the volume.
    pub async fn write_config(&self, device_path: &str, config: &DeviceConfig) -> AppResult<()> {
        tracing::info!(
            "Iniciando inyección de configuración en la unidad: {}",
            device_path
        );

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
            Err(AppError::Config(
                "Plataforma no soportada para inyección de configuraciones".to_string(),
            ))
        }
    }

    // ============================================================
    // LINUX MOUNTING & WRITE
    // ============================================================
    #[cfg(target_os = "linux")]
    async fn write_config_linux(&self, device_path: &str, config: &DeviceConfig) -> AppResult<()> {
        let config_path = write_private_config_file(config)?;
        let current_exe = std::env::current_exe()?;

        let status_result = tokio::process::Command::new("pkexec")
            .arg(current_exe)
            .arg("--configure-device")
            .arg("--device")
            .arg(device_path)
            .arg("--config-file")
            .arg(&config_path)
            .status()
            .await;

        let _ = std::fs::remove_file(&config_path);
        let status = status_result.map_err(|error| {
            AppError::Config(format!(
                "No se pudo iniciar la configuración elevada: {error}"
            ))
        })?;

        if !status.success() {
            return Err(AppError::Config(
                "El proceso elevado no pudo inyectar la configuración en BOOT.".to_string(),
            ));
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

        tracing::info!(
            "Montando partición macOS {} en {}",
            partition,
            temp_mount.display()
        );

        let mount_status = Command::new("diskutil")
            .args([
                "mount",
                "readwrite",
                "-mountPoint",
                &temp_mount.to_string_lossy(),
                &partition,
            ])
            .status()
            .map_err(|e| AppError::Config(format!("Fallo al ejecutar diskutil mount: {}", e)))?;

        if !mount_status.success() {
            return Err(AppError::Config(format!(
                "Error al montar partición de arranque {}",
                partition
            )));
        }

        let config_file_path = temp_mount.join("device-config.json");
        let json_data = serde_json::to_string_pretty(config)?;
        std::fs::write(&config_file_path, json_data)?;

        // Inyectamos sigil_provision.json para la identidad requerida por el instalador
        let serial = config.serial_number.as_deref().unwrap_or("SS-UNKNOWN");
        let provision_json = serde_json::json!({
            "_schema_version": "1.0",
            "serial_number": serial,
            "model": "Sigil-Streamer",
            "model_version": "v1",
            "batch": "batch-01",
            "capabilities": {
                "i2s_dac": false
            }
        });
        let provision_file_path = temp_mount.join("sigil_provision.json");
        let provision_data = serde_json::to_string_pretty(&provision_json)?;
        let _ = std::fs::write(&provision_file_path, provision_data);

        if config.ssh_enabled {
            let ssh_file_path = temp_mount.join("ssh");
            std::fs::write(ssh_file_path, "")?;
        }

        // Apply hardware/model optimizations
        if let Err(e) = apply_model_optimizations(&temp_mount, config.rpi_model.as_deref()) {
            tracing::error!("Error al aplicar optimizaciones de modelo: {}", e);
        }

        let umount_status = Command::new("diskutil")
            .args(["unmount", &partition])
            .status()
            .map_err(|e| AppError::Config(format!("Fallo al desmontar partición: {}", e)))?;

        let _ = std::fs::remove_dir(&temp_mount);

        if !umount_status.success() {
            return Err(AppError::Config(
                "Fallo al desmontar partición de arranque".to_string(),
            ));
        }

        Ok(())
    }

    // ============================================================
    // WINDOWS VOLUMES RESOLUTION & WRITE
    // ============================================================
    #[cfg(target_os = "windows")]
    async fn write_config_windows(
        &self,
        device_path: &str,
        config: &DeviceConfig,
    ) -> AppResult<()> {
        let drive_number = device_path
            .trim_start_matches("\\\\.\\PhysicalDrive")
            .parse::<u32>()
            .map_err(|_| {
                AppError::Config(format!(
                    "Ruta de disco de Windows inválida: {}",
                    device_path
                ))
            })?;

        tracing::info!(
            "Resolviendo particiones de la unidad física número {}",
            drive_number
        );

        let json_escaped = serde_json::to_string(config)?.replace("\"", "`\"");

        let serial = config.serial_number.as_deref().unwrap_or("SS-UNKNOWN");
        let provision_json = serde_json::json!({
            "_schema_version": "1.0",
            "serial_number": serial,
            "model": "Sigil-Streamer",
            "model_version": "v1",
            "batch": "batch-01",
            "capabilities": {
                "i2s_dac": false
            }
        });
        let provision_escaped = serde_json::to_string(&provision_json)?.replace("\"", "`\"");

        let mut ps_script = format!(
            "$part = Get-Partition -DiskNumber {} -PartitionNumber 1; ",
            drive_number
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
             $prov = \"$($letter):\\sigil_provision.json\";
             \"{}\" | Out-File -FilePath $prov -Encoding utf8;
             ", drive_number, json_escaped, provision_escaped
        );

        if config.ssh_enabled {
            ps_script.push_str("New-Item -Path \"$($letter):\\ssh\" -ItemType File -Force; ");
        }

        // Apply hardware/model optimizations
        let config_txt_content = get_optimizations_string(config.rpi_model.as_deref());
        if !config_txt_content.is_empty() {
            let escaped_txt = config_txt_content.replace("\"", "`\"");
            ps_script.push_str(&format!(
                "$configPath = \"$($letter):\\config.txt\";
                 if (Test-Path $configPath) {{
                     \"{}\" | Out-File -FilePath $configPath -Append -Encoding utf8;
                 }} else {{
                     \"{}\" | Out-File -FilePath $configPath -Encoding utf8;
                 }}
                 ",
                escaped_txt, escaped_txt
            ));
        }

        let output = Command::new("powershell")
            .args(["-NoProfile", "-Command", &ps_script])
            .output()
            .map_err(|e| AppError::Config(format!("Fallo al ejecutar PowerShell: {}", e)))?;

        if !output.status.success() {
            let err_msg = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(AppError::Config(format!(
                "PowerShell devolvió error al inyectar: {}",
                err_msg
            )));
        }

        tracing::info!("Inyección completada exitosamente en Windows.");
        Ok(())
    }
}

/// Entry point used by the elevated helper process on Linux.
pub fn run_config_writer_cli(device_path: &str, config_file: &str) -> AppResult<()> {
    #[cfg(target_os = "linux")]
    {
        let json = std::fs::read_to_string(config_file).map_err(|error| {
            AppError::Config(format!(
                "No se pudo leer la configuración temporal: {error}"
            ))
        })?;
        let config: DeviceConfig = serde_json::from_str(&json)?;
        write_config_linux_privileged(device_path, &config)
    }

    #[cfg(not(target_os = "linux"))]
    {
        let _ = (device_path, config_file);
        Err(AppError::Config(
            "El escritor elevado de configuración solo está disponible en Linux.".to_string(),
        ))
    }
}

#[cfg(target_os = "linux")]
fn write_private_config_file(config: &DeviceConfig) -> AppResult<PathBuf> {
    use std::os::unix::fs::OpenOptionsExt;

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    let path = std::env::temp_dir().join(format!(
        "sigil-device-config-{}-{nonce}.json",
        std::process::id()
    ));
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)?;

    if let Err(error) = serde_json::to_writer_pretty(&file, config) {
        let _ = std::fs::remove_file(&path);
        return Err(error.into());
    }
    file.sync_all()?;
    Ok(path)
}

#[cfg(target_os = "linux")]
fn linux_boot_partition(device_path: &str) -> String {
    if device_path.contains("mmcblk")
        || device_path.contains("nvme")
        || device_path.contains("loop")
    {
        format!("{device_path}p1")
    } else {
        format!("{device_path}1")
    }
}

#[cfg(target_os = "linux")]
fn write_config_linux_privileged(device_path: &str, config: &DeviceConfig) -> AppResult<()> {
    let partition = linux_boot_partition(device_path);
    let temp_mount = std::env::temp_dir().join(format!("sigil-boot-mount-{}", std::process::id()));
    std::fs::create_dir_all(&temp_mount)?;

    tracing::info!(
        "Montando partición BOOT {} en {}",
        partition,
        temp_mount.display()
    );
    let mount_status = Command::new("mount")
        .arg(&partition)
        .arg(&temp_mount)
        .status()
        .map_err(|error| AppError::Config(format!("No se pudo ejecutar mount: {error}")))?;

    if !mount_status.success() {
        let _ = std::fs::remove_dir(&temp_mount);
        return Err(AppError::Config(format!(
            "No se pudo montar la partición de arranque {partition}."
        )));
    }

    let write_result = write_linux_boot_files(&temp_mount, config);
    let umount_result = Command::new("umount")
        .arg(&temp_mount)
        .status()
        .map_err(|error| AppError::Config(format!("No se pudo ejecutar umount: {error}")));
    let _ = std::fs::remove_dir(&temp_mount);

    write_result?;
    if !umount_result?.success() {
        return Err(AppError::Config(
            "Fallo al desmontar volumen BOOT de forma limpia.".to_string(),
        ));
    }

    Ok(())
}

#[cfg(target_os = "linux")]
fn write_linux_boot_files(boot_path: &Path, config: &DeviceConfig) -> AppResult<()> {
    let json_data = serde_json::to_string_pretty(config)?;
    std::fs::write(boot_path.join("device-config.json"), json_data)?;

    let serial = config.serial_number.as_deref().unwrap_or("SS-UNKNOWN");
    let provision_json = serde_json::json!({
        "_schema_version": "1.0",
        "serial_number": serial,
        "model": "Sigil-Streamer",
        "model_version": "v1",
        "batch": "batch-01",
        "capabilities": {
            "i2s_dac": false
        }
    });
    std::fs::write(
        boot_path.join("sigil_provision.json"),
        serde_json::to_string_pretty(&provision_json)?,
    )?;

    if config.ssh_enabled {
        std::fs::write(boot_path.join("ssh"), "")?;
    }

    apply_model_optimizations(boot_path, config.rpi_model.as_deref())?;
    Ok(())
}

// ============================================================
// HELPERS FOR MODEL OPTIMIZATIONS
// ============================================================
fn get_optimizations_string(rpi_model: Option<&str>) -> String {
    let Some(model) = rpi_model else {
        return String::new();
    };
    let mut opts = String::new();
    opts.push_str("\n\n# --- Sigil Flash Auto-Optimizations ---\n");
    match model {
        "Raspberry Pi 5 (64-bit)" => {
            opts.push_str("arm_64bit=1\n");
            opts.push_str("dtparam=pciex1_gen=3\n");
            opts.push_str("gpu_mem=64\n");
        }
        "Raspberry Pi 4 (64-bit)" => {
            opts.push_str("arm_64bit=1\n");
            opts.push_str("gpu_mem=64\n");
        }
        "Raspberry Pi 4 (32-bit)" => {
            opts.push_str("arm_64bit=0\n");
            opts.push_str("gpu_mem=64\n");
        }
        "Raspberry Pi 3 (64-bit)" | "Raspberry Pi Zero 2 W (64-bit)" => {
            opts.push_str("arm_64bit=1\n");
            opts.push_str("gpu_mem=32\n");
            opts.push_str("max_usb_current=1\n");
        }
        "Raspberry Pi 3 (32-bit)"
        | "Raspberry Pi Zero 2 W (32-bit)"
        | "Raspberry Pi Zero W (32-bit)"
        | "Raspberry Pi Zero (32-bit)"
        | "Raspberry Pi 2"
        | "Raspberry Pi 1" => {
            opts.push_str("arm_64bit=0\n");
            opts.push_str("gpu_mem=16\n");
            opts.push_str("max_usb_current=1\n");
        }
        _ => {}
    }
    opts.push_str("# --- End Sigil Flash Auto-Optimizations ---\n");
    opts
}

fn apply_model_optimizations(
    boot_path: &std::path::Path,
    rpi_model: Option<&str>,
) -> std::io::Result<()> {
    let opts = get_optimizations_string(rpi_model);
    if opts.is_empty() {
        return Ok(());
    }

    let config_txt_path = boot_path.join("config.txt");
    if config_txt_path.exists() {
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&config_txt_path)?;
        use std::io::Write;
        file.write_all(opts.as_bytes())?;
    } else {
        std::fs::write(&config_txt_path, opts)?;
    }

    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    fn sample_config() -> DeviceConfig {
        DeviceConfig {
            hostname: "sigil-test".to_string(),
            username: "sigil".to_string(),
            password: None,
            wifi_ssid: Some("Test WiFi".to_string()),
            wifi_password: Some("test-password".to_string()),
            ssh_enabled: true,
            rpi_model: Some("Raspberry Pi 4 (64-bit)".to_string()),
            serial_number: Some("SS-TEST-001".to_string()),
            panel_pin: Some("80427159".to_string()),
            api_key: None,
        }
    }

    fn isolated_boot_dir(test_name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("sigil-config-{test_name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create isolated boot directory");
        path
    }

    #[test]
    fn linux_boot_partition_should_use_numeric_suffix_for_sd_device() {
        assert_eq!(linux_boot_partition("/dev/sdc"), "/dev/sdc1");
    }

    #[test]
    fn linux_boot_partition_should_use_p_suffix_for_mmc_device() {
        assert_eq!(linux_boot_partition("/dev/mmcblk0"), "/dev/mmcblk0p1");
    }

    #[test]
    fn linux_boot_partition_should_use_p_suffix_for_nvme_device() {
        assert_eq!(linux_boot_partition("/dev/nvme1n1"), "/dev/nvme1n1p1");
    }

    #[test]
    fn write_linux_boot_files_should_serialize_device_config() {
        let boot_dir = isolated_boot_dir("device-config");

        write_linux_boot_files(&boot_dir, &sample_config()).expect("write boot files");
        let written: DeviceConfig = serde_json::from_str(
            &std::fs::read_to_string(boot_dir.join("device-config.json"))
                .expect("read device config"),
        )
        .expect("parse device config");

        assert_eq!(written.hostname, "sigil-test");
        let _ = std::fs::remove_dir_all(boot_dir);
    }

    #[test]
    fn write_linux_boot_files_should_create_ssh_trigger_when_enabled() {
        let boot_dir = isolated_boot_dir("ssh-trigger");

        write_linux_boot_files(&boot_dir, &sample_config()).expect("write boot files");

        assert!(boot_dir.join("ssh").is_file());
        let _ = std::fs::remove_dir_all(boot_dir);
    }

    #[test]
    fn write_linux_boot_files_should_include_provision_serial_number() {
        let boot_dir = isolated_boot_dir("provision-serial");

        write_linux_boot_files(&boot_dir, &sample_config()).expect("write boot files");
        let provision = std::fs::read_to_string(boot_dir.join("sigil_provision.json"))
            .expect("read provision file");

        assert!(provision.contains("SS-TEST-001"));
        let _ = std::fs::remove_dir_all(boot_dir);
    }
}
