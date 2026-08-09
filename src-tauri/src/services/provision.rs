use crate::errors::{Result, SigilError};
use crate::models::DeviceConfig;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tracing::{info, warn};

pub const BOOT_MARKER_BEGIN: &str = "# >>> SIGIL FLASH BOOT TUNING BEGIN >>>";
pub const BOOT_MARKER_END: &str = "# <<< SIGIL FLASH BOOT TUNING END <<<";

/// Escritura atómica y verificada de un secreto: temporal con el modo final ya
/// aplicado, fsync del archivo, rename, fsync del directorio y relectura.
/// El sistema de archivos puede mentir entre dos llamadas: por eso se relee.
pub fn write_secret_atomic(path: &Path, content: &str, mode: u32) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        SigilError::Flash(format!("Ruta de secreto sin directorio padre: '{}'", path.display()))
    })?;
    fs::create_dir_all(parent)?;

    let tmp_path = parent.join(format!(
        ".{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("secret")
    ));
    let _ = fs::remove_file(&tmp_path);

    {
        let mut tmp = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&tmp_path)?;
        tmp.write_all(content.as_bytes())?;
        tmp.sync_all()?;
    }

    fs::rename(&tmp_path, path)?;
    File::open(parent)?.sync_all()?;

    let mut verify = String::new();
    File::open(path)?.read_to_string(&mut verify)?;
    if verify != content {
        return Err(SigilError::Flash(format!(
            "La relectura de '{}' no coincide con lo escrito: el archivo no quedó íntegro",
            path.display()
        )));
    }

    Ok(())
}

/// Sobrescribe con ceros y borra. Se usa cuando una provisión de secreto falla
/// a mitad: dejar el texto plano en la imagen sería peor que abortar.
pub fn shred_file(path: &Path) {
    if let Ok(meta) = fs::metadata(path) {
        if let Ok(mut f) = OpenOptions::new().write(true).open(path) {
            let zeros = vec![0u8; meta.len() as usize];
            let _ = f.write_all(&zeros);
            let _ = f.sync_all();
        }
    }
    let _ = fs::remove_file(path);
}

/// Documento de identidad de fabricación que consume device_identity.py.
/// Lleva el número de serie; NUNCA lleva PIN, contraseña ni credencial.
pub fn build_identity_document(config: &DeviceConfig) -> Result<String> {
    let serial = config.serial_number.as_deref().ok_or_else(|| {
        SigilError::Config("El número de serie es OBLIGATORIO para la identidad de fábrica".to_string())
    })?;

    // El lote no es un dato que teclee el operario: lo fija la estación de
    // fabricación. La capacidad I2S la confirma el propio dispositivo en el
    // primer arranque leyendo su hardware real, así que aquí va en falso.
    let document = serde_json::json!({
        "_schema_version": "1.0",
        "serial_number": serial,
        "model": config.model_name.as_deref().unwrap_or("Sigil-Streamer"),
        "model_version": config.model_version.as_deref().unwrap_or("v2"),
        "batch": std::env::var("SIGIL_FACTORY_BATCH").unwrap_or_else(|_| "factory".to_string()),
        "capabilities": { "i2s_dac": false }
    });

    Ok(serde_json::to_string_pretty(&document)?)
}

/// Escribe la identidad en la partición de arranque montada.
pub fn write_identity_document(boot_mount: &Path, config: &DeviceConfig) -> Result<()> {
    let document = build_identity_document(config)?;
    let target = boot_mount.join("sigil_provision.json");
    write_secret_atomic(&target, &document, 0o644)?;
    info!("Identidad de fabricación escrita en {}", target.display());
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoardClass {
    Arm64Pcie,
    Arm64,
    Arm64LowEnd,
    Arm32,
}

pub fn classify_board(model: &str) -> Result<BoardClass> {
    match model {
        "raspberry-pi-5" => Ok(BoardClass::Arm64Pcie),
        "raspberry-pi-4b" => Ok(BoardClass::Arm64),
        "raspberry-pi-3b" | "raspberry-pi-3b-plus" | "raspberry-pi-zero-2-w" => {
            Ok(BoardClass::Arm64LowEnd)
        }
        "raspberry-pi-zero-w" | "raspberry-pi-1" => Ok(BoardClass::Arm32),
        other => Err(SigilError::Config(format!(
            "Modelo de placa sin perfil de arranque definido: '{}'",
            other
        ))),
    }
}

/// Arquitecturas de imagen que una placa puede arrancar.
///
/// No es lo mismo que la clase de arranque: una Pi 4 admite las dos, una Zero W
/// solo armhf porque su ARM1176 no ejecuta aarch64, y la Pi 5 solo arm64 porque
/// Raspberry Pi OS no publica kernel de 32 bits para BCM2712.
pub fn architectures_for_board(model: &str) -> Result<&'static [&'static str]> {
    match classify_board(model)? {
        // BCM2712: sin kernel de 32 bits publicado.
        BoardClass::Arm64Pcie => Ok(&["arm64"]),
        BoardClass::Arm64 | BoardClass::Arm64LowEnd => Ok(&["arm64", "armhf"]),
        // ARMv6 (ARM1176): no ejecuta aarch64 en absoluto.
        BoardClass::Arm32 => Ok(&["armhf"]),
    }
}

/// Rechaza combinaciones imposibles ANTES de escribir un solo byte.
///
/// Sin esto, elegir el modelo equivocado producía una tarjeta que no arranca y
/// el flasheo terminaba anunciando éxito: `arm_64bit` se derivaba del modelo sin
/// mirar la imagen, así que un rootfs arm64 podía salir con `arm_64bit=0` —o al
/// revés— y el fallo solo se descubría con la placa delante.
pub fn validate_model_supports_architecture(model: &str, architecture: &str) -> Result<()> {
    let permitidas = architectures_for_board(model)?;
    if permitidas.contains(&architecture) {
        return Ok(());
    }
    Err(SigilError::Validation(format!(
        "El modelo '{}' no puede arrancar una imagen '{}'. Arquitectura admitida: {}. \
         Seleccione la imagen que corresponde a esta placa, o cambie el modelo si se \
         equivocó al elegirlo.",
        model,
        architecture,
        permitidas.join(" o ")
    )))
}

/// Falla si la partición de arranque no trae el kernel que esta placa necesita.
pub fn require_kernel_for_board(boot_mount: &Path, model: &str, architecture: &str) -> Result<()> {
    let kernel = required_kernel_image(model, architecture)?;
    if boot_mount.join(kernel).is_file() {
        return Ok(());
    }
    Err(SigilError::Validation(format!(
        "La imagen '{}' no incluye '{}', que es el kernel que necesita el modelo '{}'. \
         El firmware no cargaría nada y la tarjeta saldría sin arrancar.\n\
         Use una imagen '{}' que lo traiga, o seleccione la variante arm64 para esta placa.",
        architecture, kernel, model, architecture
    )))
}

/// Deduce la arquitectura de una tarjeta ya escrita, sin montar su raíz.
///
/// La usa el modo `--configure-device`, que solo abre la partición de arranque.
/// Si la placa admite una sola arquitectura no hay nada que deducir. Si admite
/// las dos, manda el `arm_64bit` que la propia imagen dejó escrito; se lee el
/// último valor efectivo, no el primero, porque `config.txt` permite repetirlo.
pub fn architecture_from_boot_config(config_txt: &Path, model: &str) -> Result<String> {
    let permitidas = architectures_for_board(model)?;
    if permitidas.len() == 1 {
        return Ok(permitidas[0].to_string());
    }

    let texto = fs::read_to_string(config_txt).unwrap_or_default();
    let ultimo = texto
        .lines()
        .map(str::trim)
        .filter(|l| !l.starts_with('#'))
        .filter_map(|l| l.strip_prefix("arm_64bit="))
        .filter_map(|v| v.split_whitespace().next())
        .last();

    match ultimo {
        Some("1") => Ok("arm64".to_string()),
        Some("0") => Ok("armhf".to_string()),
        _ => Err(SigilError::Validation(format!(
            "No se puede deducir la arquitectura de la tarjeta: '{}' no declara \
             'arm_64bit' y el modelo '{}' admite {}. Vuelva a fabricar la tarjeta \
             en vez de reconfigurarla.",
            config_txt.display(),
            model,
            permitidas.join(" y ")
        ))),
    }
}

/// El kernel que el firmware necesita para esta placa y arquitectura.
///
/// Raspberry Pi OS reparte kernels por familia de SoC. El de 32 bits para
/// BCM2711 —Pi 4, 400 y CM4— es `kernel7l.img`, y algunas imágenes armhf no lo
/// incluyen: en esas placas el firmware no carga nada y la tarjeta sale muda
/// sin un solo mensaje de error.
pub fn required_kernel_image(model: &str, architecture: &str) -> Result<&'static str> {
    validate_model_supports_architecture(model, architecture)?;
    if architecture == "arm64" {
        return Ok("kernel8.img");
    }
    Ok(match classify_board(model)? {
        // BCM2711 en 32 bits usa el kernel LPAE.
        BoardClass::Arm64 => "kernel7l.img",
        // BCM2710/2837 (Pi 3, Zero 2 W) en 32 bits.
        BoardClass::Arm64LowEnd => "kernel7.img",
        // ARMv6.
        BoardClass::Arm32 => "kernel.img",
        // Sin 32 bits: validate_model_supports_architecture ya lo rechazó.
        BoardClass::Arm64Pcie => unreachable!("Pi 5 no admite armhf"),
    })
}

/// Ajustes de arranque para el par placa/imagen.
///
/// La bitness sale de la ARQUITECTURA DE LA IMAGEN, no del modelo: es la imagen
/// la que determina qué kernel debe cargar el firmware. Del modelo salen solo
/// los ajustes de memoria y periféricos, que sí son propios del hardware.
pub fn boot_tuning_block(model: &str, architecture: &str) -> Result<String> {
    validate_model_supports_architecture(model, architecture)?;
    let arm_64bit = if architecture == "arm64" { 1 } else { 0 };
    let hardware = match classify_board(model)? {
        BoardClass::Arm64Pcie => "gpu_mem=76\nusb_max_current_enable=1\ndtparam=pciex1_gen=3\n",
        BoardClass::Arm64 => "gpu_mem=64\nusb_max_current_enable=1\n",
        BoardClass::Arm64LowEnd => "gpu_mem=32\n",
        BoardClass::Arm32 => "gpu_mem=16\n",
    };
    Ok(format!(
        "{}\n# Modelo: {}\n# Arquitectura de la imagen: {}\narm_64bit={}\n{}{}\n",
        BOOT_MARKER_BEGIN, model, architecture, arm_64bit, hardware, BOOT_MARKER_END
    ))
}

/// Aplica el bloque de arranque entre marcadores propios, reemplazando el
/// bloque previo si ya existía: reflashear el mismo equipo no debe acumular.
pub fn apply_boot_tuning(config_txt: &Path, model: &str, architecture: &str) -> Result<()> {
    let block = boot_tuning_block(model, architecture)?;
    let existing = if config_txt.is_file() {
        fs::read_to_string(config_txt)?
    } else {
        String::new()
    };

    let stripped = strip_marked_block(&existing);
    let mut updated = stripped.trim_end().to_string();
    if !updated.is_empty() {
        updated.push('\n');
    }
    updated.push_str(&block);

    fs::write(config_txt, updated)?;
    Ok(())
}

pub fn strip_marked_block(text: &str) -> String {
    let mut out = Vec::new();
    let mut inside = false;
    for line in text.lines() {
        if line.trim() == BOOT_MARKER_BEGIN {
            inside = true;
            continue;
        }
        if line.trim() == BOOT_MARKER_END {
            inside = false;
            continue;
        }
        if !inside {
            out.push(line);
        }
    }
    let mut joined = out.join("\n");
    if !joined.is_empty() {
        joined.push('\n');
    }
    joined
}

/// UUID determinista: reflashear el mismo equipo con la misma red no debe
/// generar un perfil duplicado en NetworkManager.
pub fn deterministic_uuid(serial: &str, ssid: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(serial.as_bytes());
    hasher.update([0u8]);
    hasher.update(ssid.as_bytes());
    let digest = hasher.finalize();

    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

/// Escapado del formato keyfile de NetworkManager.
pub fn escape_keyfile_value(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('\t', "\\t");
    if escaped.starts_with(' ') {
        format!("\\s{}", &escaped[1..])
    } else if escaped.ends_with(' ') {
        format!("{}\\s", &escaped[..escaped.len() - 1])
    } else {
        escaped
    }
}

pub fn build_wifi_profile(serial: &str, ssid: &str, password: &str) -> String {
    let uuid = deterministic_uuid(serial, ssid);
    format!(
        "[connection]\nid={}\nuuid={}\ntype=wifi\nautoconnect=true\n\n\
         [wifi]\nmode=infrastructure\nssid={}\n\n\
         [wifi-security]\nkey-mgmt=wpa-psk\npsk={}\n\n\
         [ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n",
        escape_keyfile_value(ssid),
        uuid,
        escape_keyfile_value(ssid),
        escape_keyfile_value(password)
    )
}

pub fn write_wifi_profile(rootfs: &Path, config: &DeviceConfig) -> Result<()> {
    let (ssid, password) = match (&config.wifi_ssid, &config.wifi_password) {
        (Some(s), Some(p)) => (s, p),
        _ => return Ok(()),
    };
    let serial = config.serial_number.as_deref().unwrap_or("unknown");

    let profile = build_wifi_profile(serial, ssid, password);
    let target = rootfs
        .join("etc/NetworkManager/system-connections")
        .join(format!("{}.nmconnection", sanitize_file_component(ssid)));

    write_secret_atomic(&target, &profile, 0o600)?;
    info!("Perfil inalámbrico escrito en {}", target.display());
    Ok(())
}

fn sanitize_file_component(value: &str) -> String {
    value
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect()
}

pub fn build_sshd_dropin(username: &str, password_auth: bool) -> String {
    format!(
        "# Generado por SIGIL Flash durante la fabricación\n\
         PasswordAuthentication {}\n\
         PermitRootLogin no\n\
         AllowUsers {}\n\
         KbdInteractiveAuthentication no\n",
        if password_auth { "yes" } else { "no" },
        username
    )
}

/// Configura el acceso remoto dentro del rootfs montado. Valida la
/// configuración generada con el propio demonio usando una clave de host
/// efímera: una imagen limpia todavía no tiene claves persistentes.
pub fn provision_remote_access(rootfs: &Path, config: &DeviceConfig) -> Result<()> {
    if !config.ssh_enabled {
        return Ok(());
    }

    let sshd_binary = ["usr/sbin/sshd", "usr/bin/sshd", "sbin/sshd"]
        .iter()
        .map(|p| rootfs.join(p))
        .find(|p| p.is_file());

    if sshd_binary.is_none() {
        return Err(SigilError::Flash(
            "El acceso remoto está activo pero el bundle no instaló el servidor SSH. \
             Reconstruya el bundle exportando el perfil, para que la variable llegue \
             también al constructor del repositorio:\n  \
             export SIGIL_PACKAGE_PROFILES=factory-debug\n  \
             ./scripts/build-all-bundles.sh"
                .to_string(),
        ));
    }

    let dropin_dir = rootfs.join("etc/ssh/sshd_config.d");
    fs::create_dir_all(&dropin_dir)?;
    let dropin = dropin_dir.join("99-sigil.conf");
    write_secret_atomic(&dropin, &build_sshd_dropin(&config.username, true), 0o644)?;

    let password = config.password.as_deref().ok_or_else(|| {
        SigilError::Config("La contraseña es obligatoria cuando el acceso remoto está activo".to_string())
    })?;

    // La contraseña viaja por STDIN, nunca por argv: argv es visible en /proc.
    let mut child = Command::new("chroot")
        .arg(rootfs)
        .arg("chpasswd")
        .arg("-c")
        .arg("YESCRYPT")
        .stdin(Stdio::piped())
        .spawn()?;
    {
        let stdin = child.stdin.as_mut().ok_or_else(|| {
            SigilError::Flash("No se pudo abrir STDIN de chpasswd en el chroot".to_string())
        })?;
        stdin.write_all(format!("{}:{}\n", config.username, password).as_bytes())?;
    }
    let status = child.wait()?;
    if !status.success() {
        return Err(SigilError::Flash(
            "No se pudo establecer la contraseña de administración dentro de la imagen".to_string(),
        ));
    }

    let _ = Command::new("chroot")
        .arg(rootfs)
        .args(["usermod", "-aG", "sudo", &config.username])
        .status();

    validate_sshd_config(rootfs)?;
    info!("Acceso remoto provisionado y validado");
    Ok(())
}

fn validate_sshd_config(rootfs: &Path) -> Result<()> {
    let ephemeral_rel = "etc/ssh/ssh_host_ed25519_key.sigil-test";
    let ephemeral_abs = rootfs.join(ephemeral_rel);
    let _ = fs::remove_file(&ephemeral_abs);
    let _ = fs::remove_file(rootfs.join(format!("{}.pub", ephemeral_rel)));

    let keygen = Command::new("chroot")
        .arg(rootfs)
        .args([
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-f",
            &format!("/{}", ephemeral_rel),
        ])
        .status();

    if keygen.map(|s| !s.success()).unwrap_or(true) {
        warn!("No se pudo generar la clave de host efímera; se omite la validación de sshd");
        return Ok(());
    }

    let test = Command::new("chroot")
        .arg(rootfs)
        .args(["sshd", "-t", "-f", "/etc/ssh/sshd_config", "-h", &format!("/{}", ephemeral_rel)])
        .output()?;

    let _ = fs::remove_file(&ephemeral_abs);
    let _ = fs::remove_file(rootfs.join(format!("{}.pub", ephemeral_rel)));

    if !test.status.success() {
        return Err(SigilError::Flash(format!(
            "La configuración SSH generada no supera la validación del demonio: {}",
            String::from_utf8_lossy(&test.stderr).trim()
        )));
    }
    Ok(())
}

/// Reescribe la URL del servidor en TODOS los archivos donde aparece. Si la
/// clave no existe en ninguno, aborta: una imagen sin esa clave no es la
/// esperada, y añadirla en silencio ocultaría el problema.
pub fn rewrite_server_url(rootfs: &Path, server_url: &str) -> Result<()> {
    let candidates = [
        "etc/sigil/audio.conf",
        "opt/sigil/install-payload/conf/audio.conf",
    ];

    let mut rewritten = 0usize;
    let mut seen_key = false;

    for rel in candidates {
        let path = rootfs.join(rel);
        if !path.is_file() {
            continue;
        }
        let text = fs::read_to_string(&path)?;
        if !text.lines().any(|l| l.trim_start().starts_with("SERVER_URL=")) {
            continue;
        }
        seen_key = true;

        let updated: Vec<String> = text
            .lines()
            .map(|line| {
                if line.trim_start().starts_with("SERVER_URL=") {
                    format!("SERVER_URL=\"{}\"", server_url)
                } else {
                    line.to_string()
                }
            })
            .collect();

        fs::write(&path, format!("{}\n", updated.join("\n")))?;
        rewritten += 1;
    }

    if !seen_key || rewritten == 0 {
        return Err(SigilError::Flash(
            "No se encontró la clave SERVER_URL en ninguna configuración de la imagen. \
             La imagen no es la esperada: aborte y verifique el payload instalado."
                .to_string(),
        ));
    }

    info!("SERVER_URL individualizada en {} archivo(s) de la imagen", rewritten);
    Ok(())
}

/// Provisión del PIN del panel: el hash se deriva DENTRO del chroot para que
/// use las mismas bibliotecas que usará el dispositivo.
pub fn provision_panel_pin(rootfs: &Path, pin: &str) -> Result<()> {
    let mfg_dir = rootfs.join("etc/sigil/manufacturing");
    fs::create_dir_all(&mfg_dir)?;
    let mut perms = fs::metadata(&mfg_dir)?.permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o700);
    fs::set_permissions(&mfg_dir, perms)?;

    let secret_file = mfg_dir.join("sigil_secrets.json");
    let document = serde_json::json!({ "_schema_version": "1.0", "panel_pin": pin });
    write_secret_atomic(&secret_file, &document.to_string(), 0o600)?;

    let status = Command::new("chroot")
        .arg(rootfs)
        .args(["python3", "/opt/sigil/panel/panel_auth.py"])
        .status();

    let derived_ok = status.map(|s| s.success()).unwrap_or(false);

    if !derived_ok {
        shred_file(&secret_file);
        return Err(SigilError::Flash(
            "No se pudo derivar el hash del PIN del panel dentro de la imagen. \
             El texto plano fue sobrescrito y eliminado. Verifique que el bundle \
             instaló python3-argon2."
                .to_string(),
        ));
    }

    // Verificar que el texto plano quedó consumido y que existen hash y metadato.
    if secret_file.exists() {
        shred_file(&secret_file);
        return Err(SigilError::Flash(
            "El generador de hash no consumió el PIN en texto plano. \
             El archivo fue sobrescrito y eliminado por seguridad."
                .to_string(),
        ));
    }

    let hash_file = rootfs.join("etc/sigil/secrets/panel-pin.hash");
    let length_file = rootfs.join("etc/sigil/secrets/panel-pin.length");
    if !hash_file.is_file() || !length_file.is_file() {
        return Err(SigilError::Flash(
            "El hash del PIN del panel o su metadato de longitud no quedaron escritos en la imagen"
                .to_string(),
        ));
    }

    info!("PIN del panel provisionado y verificado dentro de la imagen");
    Ok(())
}

/// Credencial de enrolamiento de un solo uso, modo 0600, escritura atómica.
pub fn write_enrollment_key(rootfs: &Path, enrollment_key: &str) -> Result<()> {
    let target = rootfs.join("etc/sigil/secrets/enrollment-key");
    write_secret_atomic(&target, &format!("{}\n", enrollment_key), 0o600)?;
    info!("Credencial de enrolamiento inyectada con modo 0600");
    Ok(())
}

/// Localiza el intérprete qemu del destino en el host.
pub fn find_qemu_interpreter(architecture: &str) -> Result<PathBuf> {
    let binary = match architecture {
        "arm64" | "aarch64" => "qemu-aarch64-static",
        "armhf" | "arm" => "qemu-arm-static",
        other => {
            return Err(SigilError::Flash(format!(
                "No hay intérprete qemu conocido para la arquitectura '{}'",
                other
            )))
        }
    };

    for dir in ["/usr/bin", "/usr/local/bin", "/bin"] {
        let candidate = PathBuf::from(dir).join(binary);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    Err(SigilError::Flash(format!(
        "Falta el intérprete '{}' necesario para preparar una imagen {} desde este PC.\n\
         Instálelo según su distribución:\n  \
         Debian/Ubuntu : sudo apt-get install qemu-user-static\n  \
         Arch/Manjaro  : sudo pacman -S qemu-user-static-binfmt\n  \
         Fedora        : sudo dnf install qemu-user-static\n  \
         openSUSE      : sudo zypper install qemu-linux-user\n  \
         Alpine        : sudo apk add qemu-aarch64",
        binary, architecture
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn base_config() -> DeviceConfig {
        let mut cfg = DeviceConfig::default();
        cfg.serial_number = Some("SN-2026-0001".to_string());
        cfg
    }

    #[test]
    fn test_identity_document_carries_serial_but_no_secrets() {
        let mut cfg = base_config();
        cfg.panel_pin = Some("847392".to_string());
        cfg.password = Some("supersecreta".to_string());
        cfg.api_key = Some("enrollment-key-abcdef".to_string());
        cfg.wifi_password = Some("clave-wifi-secreta".to_string());

        let document = build_identity_document(&cfg).unwrap();

        assert!(document.contains("SN-2026-0001"));
        assert!(!document.contains("847392"));
        assert!(!document.contains("supersecreta"));
        assert!(!document.contains("enrollment-key-abcdef"));
        assert!(!document.contains("clave-wifi-secreta"));

        let parsed: serde_json::Value = serde_json::from_str(&document).unwrap();
        let keys: Vec<&String> = parsed.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 6, "el documento no debe llevar campos extra: {:?}", keys);

        // Se deja una muestra para que tests/test_identity_contract.sh la
        // valide con el device_identity.py real de sigil-hardware: el contrato
        // entre los dos lenguajes se comprueba, no se supone.
        let sample_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("target");
        let _ = fs::create_dir_all(&sample_dir);
        let _ = fs::write(sample_dir.join("identity-sample.json"), &document);
    }

    #[test]
    fn test_deterministic_wifi_uuid() {
        let a = deterministic_uuid("SN-1", "MiRed");
        let b = deterministic_uuid("SN-1", "MiRed");
        let c = deterministic_uuid("SN-2", "MiRed");
        let d = deterministic_uuid("SN-1", "OtraRed");

        assert_eq!(a, b, "el mismo par serial/ssid debe dar el mismo UUID");
        assert_ne!(a, c);
        assert_ne!(a, d);
        assert_eq!(a.len(), 36);
        assert_eq!(&a[14..15], "4");
    }

    #[test]
    fn test_keyfile_escaping() {
        assert_eq!(escape_keyfile_value("red\\casa"), "red\\\\casa");
        assert_eq!(escape_keyfile_value("red\tcasa"), "red\\tcasa");
        assert_eq!(escape_keyfile_value(" red"), "\\sred");
        assert_eq!(escape_keyfile_value("red "), "red\\s");
    }

    #[test]
    /// Una ARM1176 no ejecuta aarch64 y la Pi 5 no tiene kernel de 32 bits.
    /// Antes se aceptaban las dos y la tarjeta salía muda.
    #[test]
    fn test_impossible_board_and_image_pairs_are_rejected() {
        let err = validate_model_supports_architecture("raspberry-pi-zero-w", "arm64").unwrap_err();
        assert!(err.to_string().contains("armhf"), "{}", err);
        let err = validate_model_supports_architecture("raspberry-pi-1", "arm64").unwrap_err();
        assert!(err.to_string().contains("no puede arrancar"), "{}", err);
        let err = validate_model_supports_architecture("raspberry-pi-5", "armhf").unwrap_err();
        assert!(err.to_string().contains("arm64"), "{}", err);
    }

    #[test]
    fn test_every_supported_board_has_at_least_one_architecture() {
        for model in [
            "raspberry-pi-5",
            "raspberry-pi-4b",
            "raspberry-pi-3b",
            "raspberry-pi-3b-plus",
            "raspberry-pi-zero-2-w",
            "raspberry-pi-zero-w",
            "raspberry-pi-1",
        ] {
            let archs = architectures_for_board(model).unwrap();
            assert!(!archs.is_empty(), "{} se quedó sin arquitectura", model);
            for arch in archs {
                validate_model_supports_architecture(model, arch).unwrap();
                // Toda combinación admitida tiene que producir ajustes válidos.
                boot_tuning_block(model, arch).unwrap();
            }
        }
    }

    /// La bitness sale de la imagen, no del modelo. Una Pi 4 con imagen de 32
    /// bits tiene que recibir arm_64bit=0 aunque la placa sea de 64.
    #[test]
    fn test_bitness_follows_the_image_not_the_board() {
        let arm64 = boot_tuning_block("raspberry-pi-4b", "arm64").unwrap();
        assert!(arm64.contains("arm_64bit=1"), "{}", arm64);
        let armhf = boot_tuning_block("raspberry-pi-4b", "armhf").unwrap();
        assert!(armhf.contains("arm_64bit=0"), "{}", armhf);
        // Los ajustes de hardware sí dependen del modelo y no cambian.
        assert!(arm64.contains("gpu_mem=64") && armhf.contains("gpu_mem=64"));
    }

    #[test]
    fn test_each_board_and_architecture_names_its_kernel() {
        assert_eq!(required_kernel_image("raspberry-pi-5", "arm64").unwrap(), "kernel8.img");
        assert_eq!(required_kernel_image("raspberry-pi-4b", "arm64").unwrap(), "kernel8.img");
        // BCM2711 en 32 bits necesita el kernel LPAE, no el genérico ARMv7.
        assert_eq!(required_kernel_image("raspberry-pi-4b", "armhf").unwrap(), "kernel7l.img");
        assert_eq!(required_kernel_image("raspberry-pi-zero-2-w", "armhf").unwrap(), "kernel7.img");
        assert_eq!(required_kernel_image("raspberry-pi-zero-w", "armhf").unwrap(), "kernel.img");
    }

    /// El caso comprobado en una tarjeta real: la imagen armhf no trae
    /// kernel7l.img, así que una Pi 4 en 32 bits no arrancaría.
    #[test]
    fn test_a_missing_kernel_aborts_instead_of_shipping_a_dead_card() {
        let dir = tempdir().unwrap();
        for k in ["kernel.img", "kernel7.img", "kernel8.img"] {
            fs::write(dir.path().join(k), "x").unwrap();
        }
        let err = require_kernel_for_board(dir.path(), "raspberry-pi-4b", "armhf").unwrap_err();
        assert!(err.to_string().contains("kernel7l.img"), "{}", err);
        // Las que sí están, pasan.
        require_kernel_for_board(dir.path(), "raspberry-pi-zero-w", "armhf").unwrap();
        require_kernel_for_board(dir.path(), "raspberry-pi-4b", "arm64").unwrap();
    }

    #[test]
    fn test_single_architecture_boards_need_no_inference() {
        let dir = tempdir().unwrap();
        let cfg = dir.path().join("config.txt");
        fs::write(&cfg, "").unwrap();
        assert_eq!(
            architecture_from_boot_config(&cfg, "raspberry-pi-zero-w").unwrap(),
            "armhf"
        );
        assert_eq!(
            architecture_from_boot_config(&cfg, "raspberry-pi-5").unwrap(),
            "arm64"
        );
    }

    #[test]
    fn test_dual_architecture_boards_read_the_card() {
        let dir = tempdir().unwrap();
        let cfg = dir.path().join("config.txt");

        fs::write(&cfg, "# arm_64bit=1\narm_64bit=0\n").unwrap();
        assert_eq!(
            architecture_from_boot_config(&cfg, "raspberry-pi-4b").unwrap(),
            "armhf",
            "una línea comentada no debe contar"
        );

        // config.txt permite repetir la clave: manda la última.
        fs::write(&cfg, "arm_64bit=0\narm_64bit=1\n").unwrap();
        assert_eq!(
            architecture_from_boot_config(&cfg, "raspberry-pi-4b").unwrap(),
            "arm64"
        );

        fs::write(&cfg, "dtparam=audio=on\n").unwrap();
        let err = architecture_from_boot_config(&cfg, "raspberry-pi-4b").unwrap_err();
        assert!(err.to_string().contains("No se puede deducir"), "{}", err);
    }

    #[test]
    fn test_boot_tuning_is_idempotent_between_markers() {
        let dir = tempdir().unwrap();
        let config_txt = dir.path().join("config.txt");
        fs::write(&config_txt, "dtparam=audio=on\n").unwrap();

        apply_boot_tuning(&config_txt, "raspberry-pi-5", "arm64").unwrap();
        let first = fs::read_to_string(&config_txt).unwrap();

        apply_boot_tuning(&config_txt, "raspberry-pi-5", "arm64").unwrap();
        let second = fs::read_to_string(&config_txt).unwrap();

        assert_eq!(first, second, "reaplicar no debe acumular bloques");
        assert_eq!(second.matches(BOOT_MARKER_BEGIN).count(), 1);
        assert!(second.contains("dtparam=audio=on"));
        assert!(second.contains("dtparam=pciex1_gen=3"));

        apply_boot_tuning(&config_txt, "raspberry-pi-zero-w", "armhf").unwrap();
        let third = fs::read_to_string(&config_txt).unwrap();
        assert_eq!(third.matches(BOOT_MARKER_BEGIN).count(), 1);
        assert!(third.contains("arm_64bit=0"));
        assert!(!third.contains("pciex1_gen"));
    }

    #[test]
    fn test_board_classes_cover_all_supported_models() {
        assert_eq!(classify_board("raspberry-pi-5").unwrap(), BoardClass::Arm64Pcie);
        assert_eq!(classify_board("raspberry-pi-4b").unwrap(), BoardClass::Arm64);
        assert_eq!(classify_board("raspberry-pi-zero-2-w").unwrap(), BoardClass::Arm64LowEnd);
        assert_eq!(classify_board("raspberry-pi-zero-w").unwrap(), BoardClass::Arm32);
        assert!(classify_board("raspberry-pi-pico").is_err());
    }

    #[test]
    fn test_secret_write_is_atomic_and_verified() {
        let dir = tempdir().unwrap();
        let target = dir.path().join("secrets/enrollment-key");

        write_secret_atomic(&target, "clave-de-un-solo-uso\n", 0o600).unwrap();

        let mode = std::os::unix::fs::PermissionsExt::mode(&fs::metadata(&target).unwrap().permissions());
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(fs::read_to_string(&target).unwrap(), "clave-de-un-solo-uso\n");

        // No debe quedar ningún temporal tras la operación.
        let leftovers: Vec<_> = fs::read_dir(target.parent().unwrap())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
    }

    #[test]
    fn test_enrollment_key_lands_with_mode_0600() {
        let dir = tempdir().unwrap();
        let rootfs = dir.path();

        write_enrollment_key(rootfs, "credencial-de-un-solo-uso").unwrap();

        let target = rootfs.join("etc/sigil/secrets/enrollment-key");
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &fs::metadata(&target).unwrap().permissions(),
        );
        assert_eq!(mode & 0o777, 0o600, "la credencial debe quedar 0600 en la imagen");
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "credencial-de-un-solo-uso\n",
            "firstboot.sh lee la credencial con `read -r`: necesita el salto final"
        );
    }

    #[test]
    fn test_shred_removes_plaintext() {
        let dir = tempdir().unwrap();
        let secret = dir.path().join("sigil_secrets.json");
        fs::write(&secret, "{\"panel_pin\":\"847392\"}").unwrap();

        shred_file(&secret);
        assert!(!secret.exists());
    }

    #[test]
    fn test_server_url_rewrite_aborts_when_key_absent() {
        let dir = tempdir().unwrap();
        let rootfs = dir.path();
        fs::create_dir_all(rootfs.join("etc/sigil")).unwrap();
        fs::write(rootfs.join("etc/sigil/audio.conf"), "AUDIO_SINK=\"default\"\n").unwrap();

        let err = rewrite_server_url(rootfs, "https://nuevo.example").unwrap_err();
        assert!(err.to_string().contains("SERVER_URL"));
    }

    #[test]
    fn test_server_url_rewritten_in_every_location() {
        let dir = tempdir().unwrap();
        let rootfs = dir.path();
        fs::create_dir_all(rootfs.join("etc/sigil")).unwrap();
        fs::create_dir_all(rootfs.join("opt/sigil/install-payload/conf")).unwrap();
        fs::write(
            rootfs.join("etc/sigil/audio.conf"),
            "SERVER_URL=\"https://viejo.example\"\nAUDIO_SINK=\"default\"\n",
        )
        .unwrap();
        fs::write(
            rootfs.join("opt/sigil/install-payload/conf/audio.conf"),
            "SERVER_URL=\"https://viejo.example\"\n",
        )
        .unwrap();

        rewrite_server_url(rootfs, "https://nuevo.example").unwrap();

        for rel in ["etc/sigil/audio.conf", "opt/sigil/install-payload/conf/audio.conf"] {
            let text = fs::read_to_string(rootfs.join(rel)).unwrap();
            assert!(text.contains("https://nuevo.example"), "sin actualizar: {}", rel);
            assert!(!text.contains("viejo.example"), "quedó una URL vieja en {}", rel);
        }
    }

    #[test]
    fn test_sshd_dropin_restricts_access() {
        let dropin = build_sshd_dropin("sigil", true);
        assert!(dropin.contains("PasswordAuthentication yes"));
        assert!(dropin.contains("PermitRootLogin no"));
        assert!(dropin.contains("AllowUsers sigil"));

        let dropin = build_sshd_dropin("sigil", false);
        assert!(dropin.contains("PasswordAuthentication no"));
    }

    #[test]
    fn test_wifi_profile_contains_deterministic_uuid() {
        let profile = build_wifi_profile("SN-1", "MiRed", "clave-larga-1234");
        assert!(profile.contains(&deterministic_uuid("SN-1", "MiRed")));
        assert!(profile.contains("ssid=MiRed"));
        assert!(profile.contains("psk=clave-larga-1234"));
    }
}
