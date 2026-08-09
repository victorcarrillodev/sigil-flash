use crate::errors::{Result, SigilError};
use crate::models::Device;
use std::process::Command;
use tracing::{info, warn};

/// Lista únicamente unidades de almacenamiento extraíbles.
pub fn list_removable_devices() -> Result<Vec<Device>> {
    #[cfg(target_os = "linux")]
    {
        list_removable_devices_linux()
    }
    #[cfg(target_os = "macos")]
    {
        list_removable_devices_macos()
    }
    #[cfg(target_os = "windows")]
    {
        list_removable_devices_windows()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        Err(SigilError::Disk("Plataforma no soportada para detección de discos".to_string()))
    }
}

#[cfg(target_os = "linux")]
fn list_removable_devices_linux() -> Result<Vec<Device>> {
    let output = Command::new("lsblk")
        .args([
            "--json",
            "--bytes",
            "--nodeps",
            "--output",
            "NAME,SIZE,TYPE,TRAN,MODEL,RM,RO",
        ])
        .output()?;

    if !output.status.success() {
        return Err(SigilError::Disk(format!(
            "lsblk falló: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }

    let json_str = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&json_str)?;

    let mut devices = Vec::new();
    if let Some(blockdevices) = parsed.get("blockdevices").and_then(|b| b.as_array()) {
        for dev in blockdevices {
            let name = dev.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let size_bytes = dev.get("size").and_then(|s| s.as_u64()).unwrap_or(0);
            let dev_type = dev.get("type").and_then(|t| t.as_str()).unwrap_or("");
            let tran = dev.get("tran").and_then(|t| t.as_str()).unwrap_or("").to_lowercase();
            let model = dev.get("model").and_then(|m| m.as_str()).unwrap_or("").trim().to_string();
            let rm = dev.get("rm").and_then(|r| r.as_bool()).unwrap_or(false);
            let ro = dev.get("ro").and_then(|r| r.as_bool()).unwrap_or(false);

            // Filtrar: type == "disk" && !ro && (rm || tran ∈ {usb, mmc, sd})
            let is_removable_transport = matches!(tran.as_str(), "usb" | "mmc" | "sd");
            if dev_type == "disk" && !ro && (rm || is_removable_transport) {
                let dev_path = format!("/dev/{}", name);
                let formatted_size = format_size(size_bytes);
                devices.push(Device {
                    name: name.to_string(),
                    path: dev_path,
                    size: formatted_size,
                    model: if model.is_empty() { "Unidad Extraíble".to_string() } else { model },
                    device_type: dev_type.to_string(),
                    removable: rm,
                    transport: tran,
                });
            }
        }
    }

    info!("Dispositivos extraíbles detectados: {} unidades", devices.len());
    Ok(devices)
}

#[cfg(target_os = "macos")]
fn list_removable_devices_macos() -> Result<Vec<Device>> {
    // macOS fallback basico
    Ok(vec![])
}

#[cfg(target_os = "windows")]
fn list_removable_devices_windows() -> Result<Vec<Device>> {
    // Windows fallback basico
    Ok(vec![])
}

fn format_size(bytes: u64) -> String {
    const GB: u64 = 1_073_741_824;
    const MB: u64 = 1_048_576;
    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    }
}

/// Determina el disco padre del sistema de archivos raíz ("/") leyendo /proc/mounts
pub fn get_root_parent_device() -> Result<String> {
    let mounts = std::fs::read_to_string("/proc/mounts")?;
    for line in mounts.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 && parts[1] == "/" {
            let root_dev = parts[0];
            return Ok(normalize_parent_device(root_dev));
        }
    }
    warn!("No se pudo determinar el dispositivo raíz en /proc/mounts; asumiendo salvaguarda conservadora");
    Ok("/dev/sda".to_string())
}

/// Normaliza un nombre de partición/dispositivo a su disco padre:
/// sdaN -> sda, nvme0n1pN -> nvme0n1, mmcblk0pN -> mmcblk0
pub fn normalize_parent_device(dev_path: &str) -> String {
    let path_str = dev_path.trim_start_matches("/dev/");

    if path_str.starts_with("nvme") || path_str.starts_with("mmcblk") || path_str.starts_with("loop") {
        if let Some(pos) = path_str.rfind('p') {
            if path_str[pos + 1..].chars().all(|c| c.is_ascii_digit()) {
                return format!("/dev/{}", &path_str[..pos]);
            }
        }
    } else {
        let parent: String = path_str.chars().take_while(|c| !c.is_ascii_digit()).collect();
        if !parent.is_empty() {
            return format!("/dev/{}", parent);
        }
    }
    dev_path.to_string()
}

/// Genera la ruta de una partición dada el disco y el número de partición.
/// mmcblk0, nvme0n1, loop0 -> <dev>p<N>
/// sda, sdb -> <dev><N>
pub fn get_partition_path(dev_path: &str, part_num: u32) -> String {
    let dev = dev_path.trim_end_matches('/');
    if dev.contains("mmcblk") || dev.contains("nvme") || dev.contains("loop") {
        format!("{}p{}", dev, part_num)
    } else {
        format!("{}{}", dev, part_num)
    }
}

/// Salvaguarda independiente en el proceso elevado
pub fn validate_target_not_system_disk(target_dev: &str) -> Result<()> {
    let target_parent = normalize_parent_device(target_dev);
    let root_parent = get_root_parent_device()?;

    if target_parent == root_parent {
        return Err(SigilError::Disk(format!(
            "OPERACIÓN RECHAZADA: El dispositivo destino '{}' coincide con el disco del sistema actual '{}'",
            target_dev, root_parent
        )));
    }
    Ok(())
}

/// Tolerancia de la verificación de expansión: 16 MiB.
pub const EXPANSION_TOLERANCE_BYTES: u64 = 16 * 1024 * 1024;

/// growpart devuelve un código distinto de cero cuando la partición ya ocupaba
/// todo el espacio. Ese resultado es idempotente, no un fallo.
pub fn is_growpart_result_acceptable(exit_code: i32, stdout: &str, stderr: &str) -> bool {
    if exit_code == 0 {
        return true;
    }
    let combined = format!("{} {}", stdout, stderr).to_uppercase();
    combined.contains("NOCHANGE")
}

/// e2fsck devuelve 1 cuando corrigió errores por sí mismo: es un resultado
/// aceptable. Cualquier otro código distinto de cero no lo es.
pub fn is_e2fsck_exit_acceptable(exit_code: i32) -> bool {
    exit_code == 0 || exit_code == 1
}

/// La expansión se verifica, no se asume: la partición no puede dejar espacio
/// sin asignar al final del dispositivo, y el sistema de archivos no puede ni
/// quedarse corto respecto de su partición ni desbordarla.
pub fn validate_expansion_within_tolerance(
    device_size: u64,
    partition_start_bytes: u64,
    partition_size: u64,
    filesystem_bytes: u64,
) -> Result<()> {
    let partition_end = partition_start_bytes.saturating_add(partition_size);
    let unallocated = device_size.saturating_sub(partition_end);

    if unallocated > EXPANSION_TOLERANCE_BYTES {
        return Err(SigilError::Disk(format!(
            "La partición raíz no se expandió: quedan {} MiB sin asignar al final del dispositivo (tolerancia {} MiB)",
            unallocated / (1024 * 1024),
            EXPANSION_TOLERANCE_BYTES / (1024 * 1024)
        )));
    }

    // Desbordamiento: sin tolerancia. Un solo bloque de más y el kernel se
    // niega a montar —«bad geometry: block count N exceeds size of device»— y
    // la tarjeta sale de fábrica sin arrancar. Va antes que la comprobación de
    // holgura porque `saturating_sub` colapsa este caso a cero y lo escondía.
    if filesystem_bytes > partition_size {
        let overflow = filesystem_bytes - partition_size;
        return Err(SigilError::Disk(format!(
            "El sistema de archivos DESBORDA su partición en {} bytes ({} > {}). \
             El kernel no podrá montarlo y el equipo no arrancará. Suele significar \
             que resize2fs dimensionó contra un tamaño de partición ya obsoleto.",
            overflow, filesystem_bytes, partition_size
        )));
    }

    let filesystem_gap = partition_size - filesystem_bytes;
    if filesystem_gap > EXPANSION_TOLERANCE_BYTES {
        return Err(SigilError::Disk(format!(
            "El sistema de archivos no ocupa su partición: faltan {} MiB (tolerancia {} MiB)",
            filesystem_gap / (1024 * 1024),
            EXPANSION_TOLERANCE_BYTES / (1024 * 1024)
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_partition_naming_rules() {
        assert_eq!(get_partition_path("/dev/sda", 1), "/dev/sda1");
        assert_eq!(get_partition_path("/dev/sdb", 2), "/dev/sdb2");
        assert_eq!(get_partition_path("/dev/mmcblk0", 1), "/dev/mmcblk0p1");
        assert_eq!(get_partition_path("/dev/mmcblk0", 2), "/dev/mmcblk0p2");
        assert_eq!(get_partition_path("/dev/nvme0n1", 1), "/dev/nvme0n1p1");
        assert_eq!(get_partition_path("/dev/loop0", 2), "/dev/loop0p2");
    }

    #[test]
    fn test_normalize_parent_device() {
        assert_eq!(normalize_parent_device("/dev/sda1"), "/dev/sda");
        assert_eq!(normalize_parent_device("/dev/sda2"), "/dev/sda");
        assert_eq!(normalize_parent_device("/dev/mmcblk0p1"), "/dev/mmcblk0");
        assert_eq!(normalize_parent_device("/dev/mmcblk0p2"), "/dev/mmcblk0");
        assert_eq!(normalize_parent_device("/dev/nvme0n1p1"), "/dev/nvme0n1");
        assert_eq!(normalize_parent_device("/dev/loop0p2"), "/dev/loop0");
    }

    #[test]
    fn test_partition_expansion_is_idempotent() {
        // growpart sobre una partición ya expandida informa NOCHANGE y sale
        // con código 1: repetir la expansión no puede ser un error.
        assert!(is_growpart_result_acceptable(0, "CHANGED: partition=2 start=8192", ""));
        assert!(is_growpart_result_acceptable(
            1,
            "NOCHANGE: partition 2 is size 30777344. it cannot be grown",
            ""
        ));
        assert!(is_growpart_result_acceptable(1, "", "NOCHANGE: nothing to do"));
        assert!(!is_growpart_result_acceptable(2, "", "failed to read partition table"));
    }

    #[test]
    fn test_e2fsck_exit_code_tolerance() {
        assert!(is_e2fsck_exit_acceptable(0)); // sin errores
        assert!(is_e2fsck_exit_acceptable(1)); // errores corregidos
        assert!(!is_e2fsck_exit_acceptable(2)); // requiere reinicio
        assert!(!is_e2fsck_exit_acceptable(4)); // errores sin corregir
        assert!(!is_e2fsck_exit_acceptable(8));
        assert!(!is_e2fsck_exit_acceptable(-1)); // terminado por señal
    }

    #[test]
    fn test_expansion_verification_tolerance() {
        let gib: u64 = 1024 * 1024 * 1024;

        // Partición que ocupa el disco y sistema de archivos que ocupa la
        // partición, ambos dentro de la tolerancia de 16 MiB.
        assert!(validate_expansion_within_tolerance(
            32 * gib,
            512 * 1024 * 1024,
            32 * gib - 512 * 1024 * 1024,
            32 * gib - 512 * 1024 * 1024 - 1024 * 1024,
        )
        .is_ok());

        // Partición sin expandir: 24 GiB del dispositivo quedan libres.
        let err = validate_expansion_within_tolerance(32 * gib, 512 * 1024 * 1024, 8 * gib, 8 * gib)
            .unwrap_err();
        assert!(err.to_string().contains("sin asignar"), "{}", err);

        // Partición expandida pero resize2fs no corrió.
        let err = validate_expansion_within_tolerance(
            32 * gib,
            512 * 1024 * 1024,
            32 * gib - 512 * 1024 * 1024,
            4 * gib,
        )
        .unwrap_err();
        assert!(err.to_string().contains("no ocupa su partición"), "{}", err);
    }

    /// La geometría exacta que salió de fábrica sin arrancar: partición de
    /// 29470687 sectores y sistema de archivos de 3683840 bloques de 4 KiB.
    /// El kernel respondió «bad geometry: block count 3683840 exceeds size of
    /// device (3683835 blocks)» y la raíz quedó inmontable. El validador de
    /// entonces lo daba por bueno porque `saturating_sub` colapsa a cero.
    #[test]
    fn test_a_filesystem_overflowing_its_partition_is_rejected() {
        let sector = 512u64;
        let partition_bytes = 29_470_687 * sector;
        let filesystem_bytes = 3_683_840 * 4096;
        assert!(filesystem_bytes > partition_bytes, "premisa del caso real");

        let err = validate_expansion_within_tolerance(
            30_535_680 * sector,
            1_064_960 * sector,
            partition_bytes,
            filesystem_bytes,
        )
        .unwrap_err();
        assert!(err.to_string().contains("DESBORDA"), "{}", err);
    }

    /// Un solo bloque de más ya impide montar: aquí no hay tolerancia que valga.
    #[test]
    fn test_overflow_has_no_tolerance_margin() {
        let gib: u64 = 1024 * 1024 * 1024;
        let partition = 32 * gib - 512 * 1024 * 1024;
        let err = validate_expansion_within_tolerance(
            32 * gib,
            512 * 1024 * 1024,
            partition,
            partition + 4096,
        )
        .unwrap_err();
        assert!(err.to_string().contains("DESBORDA"), "{}", err);
    }

    /// Un sistema de archivos que llena su partición exactamente es correcto.
    #[test]
    fn test_a_filesystem_exactly_filling_its_partition_passes() {
        let gib: u64 = 1024 * 1024 * 1024;
        let partition = 32 * gib - 512 * 1024 * 1024;
        assert!(
            validate_expansion_within_tolerance(32 * gib, 512 * 1024 * 1024, partition, partition)
                .is_ok()
        );
    }
}
