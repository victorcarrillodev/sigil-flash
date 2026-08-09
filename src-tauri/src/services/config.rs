use crate::errors::{Result, SigilError};
use crate::models::DeviceConfig;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

/// Archivo de configuración privada de un solo uso. Se crea con el modo final
/// ya aplicado —nunca 0644 seguido de chmod— y se borra al destruirse la
/// guarda, incluso si el flasheo aborta a mitad.
pub struct PrivateConfigGuard {
    path: PathBuf,
}

impl PrivateConfigGuard {
    pub fn create(directory: &Path, config: &DeviceConfig) -> Result<Self> {
        fs::create_dir_all(directory)?;

        // Nombre impredecible: el directorio temporal es de escritura pública.
        let mut suffix = [0u8; 12];
        getrandom::fill(&mut suffix)
            .map_err(|e| SigilError::Internal(format!("No hay fuente de aleatoriedad: {}", e)))?;
        let name: String = suffix.iter().map(|b| format!("{:02x}", b)).collect();
        let path = directory.join(format!("sigil-flash-config-{}.json", name));

        let payload = serde_json::to_string(config)?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        file.write_all(payload.as_bytes())?;
        file.sync_all()?;

        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PrivateConfigGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub fn validate_device_config(config: &DeviceConfig) -> Result<()> {
    // 1. Hostname: 1–63 caracteres, alfanuméricos y guiones, sin empezar ni terminar en guion
    let h = &config.hostname;
    if h.is_empty() || h.len() > 63 {
        return Err(SigilError::Config("El hostname debe tener entre 1 y 63 caracteres".to_string()));
    }
    if h.starts_with('-') || h.ends_with('-') {
        return Err(SigilError::Config("El hostname no puede comenzar ni terminar con guion".to_string()));
    }
    if !h.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(SigilError::Config("El hostname solo permite caracteres alfanuméricos y guiones".to_string()));
    }

    // 2. Username: debe ser "sigil" (system-config.json)
    if config.username != "sigil" {
        return Err(SigilError::Config("El nombre de usuario de fabricación debe ser estrictamente 'sigil'".to_string()));
    }

    // 3. Password: 6–128 caracteres, sin \r \n \0. OBLIGATORIA si SSH está activo
    if config.ssh_enabled {
        match &config.password {
            Some(pwd) => {
                validate_password_str(pwd)?;
            }
            None => {
                return Err(SigilError::Config("La contraseña de administración es OBLIGATORIA si el acceso SSH está activo".to_string()));
            }
        }
    } else if let Some(pwd) = &config.password {
        validate_password_str(pwd)?;
    }

    // 4. panelPin: 6–12 dígitos; RECHAZAR repetidos, ascendentes y descendentes
    if let Some(pin) = &config.panel_pin {
        validate_panel_pin(pin)?;
    }

    // 5. serialNumber: 1–64 caracteres [A-Za-z0-9._-]; OBLIGATORIO
    match &config.serial_number {
        Some(sn) => {
            if sn.is_empty() || sn.len() > 64 {
                return Err(SigilError::Config("El número de serie debe tener entre 1 y 64 caracteres".to_string()));
            }
            if !sn.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-') {
                return Err(SigilError::Config("El número de serie contiene caracteres no permitidos".to_string()));
            }
        }
        None => {
            return Err(SigilError::Config("El número de serie es OBLIGATORIO".to_string()));
        }
    }

    // 6. deviceId: MAC de 17 caracteres; normaliza a minúsculas con ':'
    if let Some(mac) = &config.device_id {
        normalize_mac(mac)?;
    }

    // 7. rpiModel: lista cerrada de modelos soportados
    if let Some(model) = &config.rpi_model {
        let valid_models = [
            "raspberry-pi-5",
            "raspberry-pi-4b",
            "raspberry-pi-3b-plus",
            "raspberry-pi-3b",
            "raspberry-pi-zero-2-w",
            "raspberry-pi-zero-w",
            "raspberry-pi-1",
        ];
        if !valid_models.contains(&model.as_str()) {
            return Err(SigilError::Config(format!(
                "Modelo de Raspberry Pi no soportado: {}. Lista permitida: {:?}",
                model, valid_models
            )));
        }
    }

    // 8. WiFi: SSID 1–32 y clave 8–63; AMBOS o NINGUNO, nunca uno solo
    match (&config.wifi_ssid, &config.wifi_password) {
        (Some(ssid), Some(pass)) => {
            let ssid_trim = ssid.trim();
            if ssid_trim.is_empty() || ssid_trim.len() > 32 {
                return Err(SigilError::Config("El SSID WiFi debe tener entre 1 y 32 caracteres".to_string()));
            }
            if pass.len() < 8 || pass.len() > 63 {
                return Err(SigilError::Config("La clave WiFi debe tener entre 8 y 63 caracteres".to_string()));
            }
        }
        (None, None) => {}
        (Some(_), None) => {
            return Err(SigilError::Config("Se proporcionó SSID WiFi pero falta la contraseña".to_string()));
        }
        (None, Some(_)) => {
            return Err(SigilError::Config("Se proporcionó contraseña WiFi pero falta el SSID".to_string()));
        }
    }

    // 9. apiKey: 8–256 caracteres ASCII gráficos, sin espacios
    if let Some(key) = &config.api_key {
        if key.len() < 8 || key.len() > 256 {
            return Err(SigilError::Config("La API Key debe tener entre 8 y 256 caracteres".to_string()));
        }
        if !key.chars().all(|c| c.is_ascii_graphic()) {
            return Err(SigilError::Config("La API Key debe contener únicamente caracteres ASCII gráficos sin espacios".to_string()));
        }
    }

    // 10. serverUrl: https:// obligatorio; http:// SOLO con override explícito
    if let Some(url) = &config.server_url {
        if !url.starts_with("https://") {
            let allow_insecure = env::var("SIGIL_ALLOW_INSECURE_URL").unwrap_or_default() == "1";
            if url.starts_with("http://") && allow_insecure {
                // Permitido solo en laboratorio
            } else {
                return Err(SigilError::Config(
                    "SERVER_URL debe usar HTTPS obligatorio (http:// requiere SIGIL_ALLOW_INSECURE_URL=1)".to_string(),
                ));
            }
        }
    }

    Ok(())
}

fn validate_password_str(pwd: &str) -> Result<()> {
    if pwd.len() < 6 || pwd.len() > 128 {
        return Err(SigilError::Config("La contraseña debe tener entre 6 y 128 caracteres".to_string()));
    }
    if pwd.contains('\r') || pwd.contains('\n') || pwd.contains('\0') {
        return Err(SigilError::Config("La contraseña no puede contener salto de línea ni terminadores nulos".to_string()));
    }
    Ok(())
}

pub fn validate_panel_pin(pin: &str) -> Result<()> {
    // No se recorta: un PIN tecleado con un espacio de más es un PIN distinto
    // del que el operario cree haber puesto, y el panel lo rechazaría después.
    if pin.chars().any(|c| c.is_whitespace()) {
        return Err(SigilError::Config(
            "El PIN del panel no puede contener espacios".to_string(),
        ));
    }
    if pin.len() < 6 || pin.len() > 12 {
        return Err(SigilError::Config("El PIN del panel debe tener entre 6 y 12 dígitos".to_string()));
    }
    if !pin.chars().all(|c| c.is_ascii_digit()) {
        return Err(SigilError::Config("El PIN del panel debe contener únicamente dígitos numéricos".to_string()));
    }

    let digits: Vec<u8> = pin.chars().map(|c| c.to_digit(10).unwrap() as u8).collect();

    // Rechazar todos iguales (repetidos)
    if digits.iter().all(|&d| d == digits[0]) {
        return Err(SigilError::Config("El PIN no puede ser una serie de dígitos repetidos".to_string()));
    }

    // Rechazar estrictamente ascendente (ej: 123456)
    let is_ascending = digits.windows(2).all(|w| w[1] == (w[0] + 1) % 10);
    if is_ascending {
        return Err(SigilError::Config("El PIN no puede ser una secuencia ascendente continua".to_string()));
    }

    // Rechazar estrictamente descendente (ej: 654321)
    let is_descending = digits.windows(2).all(|w| w[0] == (w[1] + 1) % 10);
    if is_descending {
        return Err(SigilError::Config("El PIN no puede ser una secuencia descendente continua".to_string()));
    }

    Ok(())
}

/// Normaliza una dirección MAC a 17 caracteres en minúsculas separados por ':'
pub fn normalize_mac(mac: &str) -> Result<String> {
    let cleaned = mac.trim().replace('-', ":").to_lowercase();
    let parts: Vec<&str> = cleaned.split(':').collect();
    if parts.len() != 6 {
        return Err(SigilError::Config(format!("Dirección MAC inválida: '{}'", mac)));
    }

    for part in &parts {
        if part.len() != 2 || !part.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(SigilError::Config(format!("Octeto de dirección MAC inválido: '{}'", part)));
        }
    }

    Ok(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mac_normalization() {
        assert_eq!(normalize_mac("AA-BB-CC-DD-EE-FF").unwrap(), "aa:bb:cc:dd:ee:ff");
        assert_eq!(normalize_mac("00:11:22:33:44:55").unwrap(), "00:11:22:33:44:55");
        assert!(normalize_mac("invalid-mac").is_err());
        assert!(normalize_mac("00:11:22:33:44").is_err());
        assert!(normalize_mac("00:11:22:33:44:ZZ").is_err());
    }

    #[test]
    fn test_panel_pin_validation() {
        assert!(validate_panel_pin("847392").is_ok());
        assert!(validate_panel_pin("12345").is_err()); // demasiado corto
        assert!(validate_panel_pin("111111").is_err()); // repetido
        assert!(validate_panel_pin("123456").is_err()); // ascendente
        assert!(validate_panel_pin("654321").is_err()); // descendente
        assert!(validate_panel_pin("abcdef").is_err()); // no numérico
    }

    #[test]
    fn test_private_config_guard_uses_0600_and_deletes_itself() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = DeviceConfig::default();
        cfg.serial_number = Some("SN123456".to_string());
        cfg.panel_pin = Some("847392".to_string());

        let path = {
            let guard = PrivateConfigGuard::create(dir.path(), &cfg).unwrap();
            let path = guard.path().to_path_buf();

            let mode = fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "la configuración privada debe nacer 0600");

            let written: DeviceConfig =
                serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
            assert_eq!(written, cfg);

            path
        };

        assert!(!path.exists(), "la guarda debe borrar el archivo al destruirse");
    }

    #[test]
    fn test_password_validation_at_limits() {
        assert!(validate_password_str(&"a".repeat(5)).is_err());
        assert!(validate_password_str(&"a".repeat(6)).is_ok());
        assert!(validate_password_str(&"a".repeat(128)).is_ok());
        assert!(validate_password_str(&"a".repeat(129)).is_err());
        assert!(validate_password_str("con\nsalto").is_err());
        assert!(validate_password_str("con\rretorno").is_err());
        assert!(validate_password_str("con\0nulo").is_err());

        // La contraseña es obligatoria cuando el acceso remoto está activo.
        let mut cfg = DeviceConfig::default();
        cfg.serial_number = Some("SN123456".to_string());
        cfg.ssh_enabled = true;
        assert!(validate_device_config(&cfg).is_err());
        cfg.password = Some("valida123".to_string());
        assert!(validate_device_config(&cfg).is_ok());
    }

    #[test]
    fn test_panel_pin_rejects_outer_whitespace() {
        // Un PIN con espacios accidentales no debe colarse tras el recorte:
        // el dispositivo recibiría un secreto distinto al tecleado.
        assert!(validate_panel_pin(" 847392").is_err());
        assert!(validate_panel_pin("847392 ").is_err());
        assert!(validate_panel_pin("847 392").is_err());
    }

    #[test]
    fn test_hostname_validation() {
        let mut cfg = DeviceConfig::default();
        cfg.serial_number = Some("SN123456".to_string());
        cfg.hostname = "sigil-box".to_string();
        assert!(validate_device_config(&cfg).is_ok());

        cfg.hostname = "-badname".to_string();
        assert!(validate_device_config(&cfg).is_err());

        cfg.hostname = "badname-".to_string();
        assert!(validate_device_config(&cfg).is_err());

        cfg.hostname = "invalid_name".to_string();
        assert!(validate_device_config(&cfg).is_err());
    }
}
