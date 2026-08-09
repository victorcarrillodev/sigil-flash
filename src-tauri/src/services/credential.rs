use crate::errors::{Result, SigilError};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::process::Command;
use tracing::info;

#[derive(Serialize)]
struct LoginRequest<'a> {
    username: &'a str,
    password: &'a str,
}

#[derive(Deserialize)]
struct LoginResponse {
    token: String,
}

#[derive(Serialize)]
struct EnrollmentKeyRequest<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    device_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    serial_number: Option<&'a str>,
}

#[derive(Deserialize)]
struct EnrollmentKeyItem {
    enrollment_key: String,
}

#[derive(Deserialize)]
struct EnrollmentKeyResponse {
    keys: Vec<EnrollmentKeyItem>,
}

/// Obtiene la contraseña de la cuenta de fábrica desde el keyring del sistema.
/// Si falla o libsecret no está disponible, aborta con un error explícito.
/// Por qué no se pudo sacar la contraseña del keyring. Son tres problemas
/// distintos con tres arreglos distintos: colapsarlos en un mensaje único deja
/// al operario mirando una pared.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyringProblem {
    /// No está `secret-tool` en el PC de fabricación.
    ToolMissing,
    /// La herramienta funciona pero no hay entrada para esa cuenta.
    EntryMissing,
    /// La herramienta falló al consultar (sesión sin desbloquear, D-Bus, etc.).
    LookupFailed(String),
}

/// La orden exacta que guarda la contraseña de una cuenta de fábrica.
pub fn store_command(username: &str) -> String {
    format!(
        "secret-tool store --label='SIGIL Factory' service sigil-factory username {}",
        username
    )
}

/// `known` son las cuentas que sí tienen contraseña en este PC. Nombrarlas
/// convierte el callejón sin salida —«no hay nada guardado para 'fabrica'»— en
/// una corrección de un vistazo cuando lo guardado es 'fabrica@sigil.local'.
pub fn keyring_problem_message(
    problem: &KeyringProblem,
    username: &str,
    known: &[String],
) -> String {
    match problem {
        KeyringProblem::ToolMissing => "Falta 'secret-tool' en este PC de fabricación. \
             Instale el paquete libsecret-tools (Debian/Ubuntu), libsecret (Arch) o \
             libsecret-tools equivalente de su distribución y vuelva a intentarlo."
            .to_string(),
        KeyringProblem::EntryMissing => {
            let alternatives = match known {
                [] => String::new(),
                [only] => format!(
                    "\nLa única cuenta guardada en este PC es '{}'. Si es esa, escríbala \
                     en el campo 'Cuenta de fábrica'.",
                    only
                ),
                many => format!(
                    "\nEn este PC hay contraseña guardada para: {}. Si es alguna de ellas, \
                     escríbala en el campo 'Cuenta de fábrica'.",
                    many.join(", ")
                ),
            };
            format!(
                "No hay ninguna contraseña guardada para la cuenta de fábrica '{}'.{}\n\
                 Si de verdad es una cuenta nueva, guárdela en el keyring del sistema con:\n  {}",
                username,
                alternatives,
                store_command(username)
            )
        }
        KeyringProblem::LookupFailed(detail) => format!(
            "El keyring del sistema no respondió: {}\n\
             Compruebe que hay una sesión de escritorio con el keyring desbloqueado.",
            detail.trim()
        ),
    }
}

/// Traduce el rechazo del servidor a algo que el operario pueda accionar. Solo
/// un 401 se arregla reescribiendo la contraseña; el resto no.
pub fn login_rejection_message(status: u16, username: &str) -> String {
    match status {
        401 => format!(
            "El servidor rechazó la cuenta de fábrica '{}' (código 401). Un 401 no \
             distingue el nombre equivocado de la contraseña equivocada, así que \
             compruebe primero el nombre: (1) '{}' tiene que ser la cuenta del \
             servidor con rol de fábrica —su alias o su correo—, nunca el usuario \
             del dispositivo; si es otra, escríbala en el campo 'Cuenta de fábrica' \
             y guarde la contraseña bajo ese mismo nombre. (2) Si el nombre ya es \
             correcto, entonces la contraseña guardada no es la de esa cuenta; \
             reescríbala con:\n  {}",
            username,
            username,
            store_command(username)
        ),
        403 => format!(
            "La cuenta '{}' existe pero no tiene permiso para emitir credenciales de \
             enrolamiento (código 403). Pida al administrador el rol de fábrica.",
            username
        ),
        429 => "Demasiados intentos de autenticación seguidos (código 429). Espere unos \
             momentos antes de reintentar."
            .to_string(),
        status if status >= 500 => format!(
            "El servidor de fabricación falló al autenticar (código {}). El problema está \
             en el servidor, no en este PC: reintente en unos minutos.",
            status
        ),
        other => format!(
            "El servidor rechazó la autenticación con el código {}. Revise que la URL del \
             servidor sea la correcta.",
            other
        ),
    }
}

/// Extrae los nombres de cuenta de la salida de `secret-tool search`. Esa
/// salida incluye una línea `secret = ...` con la contraseña en claro: aquí
/// solo se leen los atributos, nunca el secreto, y el resto se descarta sin
/// mirarlo. Por eso el parseo vive aparte y se prueba aparte.
///
/// Recibe los dos flujos juntos a propósito: `secret-tool search` reparte su
/// salida entre stdout y stderr —los `attribute.*` salen por stderr— y qué va
/// por dónde no es contrato estable entre versiones de libsecret.
pub fn parse_factory_accounts(stdout: &str) -> Vec<String> {
    let mut accounts: Vec<String> = stdout
        .lines()
        .filter_map(|line| line.trim().strip_prefix("attribute.username = "))
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .collect();
    accounts.sort();
    accounts.dedup();
    accounts
}

/// Qué cuentas de fábrica tienen contraseña guardada en este PC. Sirve para que
/// la interfaz no proponga un nombre inventado: el campo y el keyring son dos
/// fuentes de verdad y separarse en silencio produce un 401 que el operario no
/// puede diagnosticar. Es una comodidad, no un requisito: si el keyring no
/// responde se devuelve la lista vacía y el operario escribe el nombre a mano.
pub fn list_keyring_factory_accounts() -> Vec<String> {
    match Command::new("secret-tool")
        .args(["search", "service", "sigil-factory"])
        .output()
    {
        Ok(out) if out.status.success() => {
            let combined = format!(
                "{}\n{}",
                String::from_utf8_lossy(&out.stderr),
                String::from_utf8_lossy(&out.stdout)
            );
            parse_factory_accounts(&combined)
        }
        _ => Vec::new(),
    }
}

/// Obtiene la contraseña de la cuenta de fábrica desde el keyring del sistema.
/// Nunca cae a un archivo en texto plano ni a una variable de entorno.
pub fn get_factory_password_from_keyring(username: &str) -> Result<String> {
    let output = Command::new("secret-tool")
        .args(["lookup", "service", "sigil-factory", "username", username])
        .output();

    let problem = match output {
        Ok(out) if out.status.success() => {
            let secret = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !secret.is_empty() {
                return Ok(secret);
            }
            KeyringProblem::EntryMissing
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
            // secret-tool sale con código 1 y sin stderr cuando simplemente no
            // encuentra la entrada; con stderr cuando el keyring falló.
            if stderr.is_empty() {
                KeyringProblem::EntryMissing
            } else {
                KeyringProblem::LookupFailed(stderr)
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => KeyringProblem::ToolMissing,
        Err(e) => KeyringProblem::LookupFailed(e.to_string()),
    };

    let known = if matches!(problem, KeyringProblem::EntryMissing) {
        list_keyring_factory_accounts()
    } else {
        Vec::new()
    };
    Err(SigilError::Config(keyring_problem_message(
        &problem, username, &known,
    )))
}

/// Inicia sesión contra el servidor del backend y obtiene un token de sesión de vida corta
pub async fn login_factory_account(server_url: &str, username: &str, password: &str) -> Result<String> {
    let client = Client::new();
    let url = format!("{}/api/login", server_url.trim_end_matches('/'));

    let req = LoginRequest { username, password };
    let resp = client.post(&url).json(&req).send().await.map_err(|e| {
        SigilError::Download(format!("Error de conexión al servidor ({}) para autenticación: {}", url, e))
    })?;

    if !resp.status().is_success() {
        return Err(SigilError::Config(login_rejection_message(
            resp.status().as_u16(),
            username,
        )));
    }

    let body: LoginResponse = resp.json().await.map_err(|e| {
        SigilError::Serialization(format!("Respuesta de login inválida del servidor: {}", e))
    })?;

    info!("Autenticación exitosa para usuario de fábrica '{}'", username);
    Ok(body.token)
}

/// Solicita una credencial de enrolamiento (enrollment-key) de un solo uso
pub async fn request_enrollment_key(
    server_url: &str,
    session_token: &str,
    device_id: Option<&str>,
    serial_number: Option<&str>,
) -> Result<String> {
    let client = Client::new();
    let url = format!("{}/api/admin/enrollment-keys", server_url.trim_end_matches('/'));

    let req = EnrollmentKeyRequest {
        device_id,
        serial_number,
    };

    let resp = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", session_token))
        .json(&req)
        .send()
        .await
        .map_err(|e| {
            SigilError::Download(format!("Error de red solicitando credencial de enrolamiento: {}", e))
        })?;

    let status = resp.status().as_u16();
    if !resp.status().is_success() {
        match status {
            409 => {
                return Err(SigilError::Config(
                    "Este equipo ya tiene una credencial activa registrada en el servidor".to_string(),
                ));
            }
            400 => {
                return Err(SigilError::Config(
                    "El servidor exige la dirección MAC (deviceId) del equipo y no fue enviada".to_string(),
                ));
            }
            429 => {
                return Err(SigilError::Config(
                    "Demasiadas solicitudes seguidas al servidor. Por favor espere unos momentos.".to_string(),
                ));
            }
            other => {
                return Err(SigilError::Config(format!(
                    "Error del servidor al generar credencial de enrolamiento (código {})",
                    other
                )));
            }
        }
    }

    let body: EnrollmentKeyResponse = resp.json().await.map_err(|e| {
        SigilError::Serialization(format!("Respuesta de credencial inválida del servidor: {}", e))
    })?;

    let key = body
        .keys
        .first()
        .ok_or_else(|| SigilError::Config("El servidor no devolvió ninguna credencial de enrolamiento".to_string()))?
        .enrollment_key
        .clone();

    info!("Credencial de enrolamiento obtenida exitosamente");
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_command_names_the_account_in_use() {
        let command = store_command("operario-fabrica");
        assert!(command.starts_with("secret-tool store"));
        assert!(command.contains("service sigil-factory"));
        assert!(command.contains("username operario-fabrica"));
    }

    #[test]
    fn test_missing_tool_does_not_blame_the_stored_entry() {
        let message = keyring_problem_message(&KeyringProblem::ToolMissing, "sigil", &[]);
        assert!(message.contains("libsecret-tools"), "{}", message);
        assert!(!message.contains("secret-tool store"), "no pidas guardar algo sin la herramienta");
    }

    #[test]
    fn test_missing_entry_does_not_tell_you_to_install_what_ya_tienes() {
        let message = keyring_problem_message(&KeyringProblem::EntryMissing, "sigil", &[]);
        assert!(message.contains("secret-tool store"), "{}", message);
        assert!(message.contains("username sigil"));
        assert!(!message.contains("instalar 'libsecret-tools'"), "la herramienta ya está: {}", message);
    }

    /// El caso que cuesta una hora: el nombre tecleado no existe pero el
    /// correcto está guardado ahí mismo. Si el mensaje no lo nombra, el
    /// operario guarda la contraseña otra vez bajo el nombre equivocado.
    #[test]
    fn test_missing_entry_names_the_account_that_does_exist() {
        let known = vec!["fabrica@sigil.local".to_string()];
        let message = keyring_problem_message(&KeyringProblem::EntryMissing, "fabrica", &known);
        assert!(message.contains("fabrica@sigil.local"), "{}", message);
        let alternative = message.find("fabrica@sigil.local").unwrap();
        let store = message.find("secret-tool store").unwrap();
        assert!(alternative < store, "la cuenta que existe va primero: {}", message);
    }

    #[test]
    fn test_missing_entry_lists_every_stored_account() {
        let known = vec!["fabrica@sigil.local".to_string(), "operario".to_string()];
        let message = keyring_problem_message(&KeyringProblem::EntryMissing, "fabrica", &known);
        assert!(message.contains("fabrica@sigil.local"), "{}", message);
        assert!(message.contains("operario"), "{}", message);
    }

    #[test]
    fn test_lookup_failure_reports_the_real_cause() {
        let message = keyring_problem_message(
            &KeyringProblem::LookupFailed("Cannot autolaunch D-Bus without X11".to_string()),
            "sigil",
            &[],
        );
        assert!(message.contains("Cannot autolaunch D-Bus"), "{}", message);
        assert!(message.to_lowercase().contains("sesión") || message.to_lowercase().contains("keyring"));
    }

    /// `secret-tool search` imprime la contraseña en claro en una línea
    /// `secret = ...`. El parseo tiene que ignorarla: si se colara en la lista
    /// de cuentas acabaría en la interfaz y en los logs.
    #[test]
    fn test_account_parsing_never_picks_up_the_secret() {
        let stdout = "[/19]\n\
                      label = SIGIL Factory\n\
                      secret = constrasena-en-claro\n\
                      created = 2026-08-06 14:22:21\n\
                      schema = org.freedesktop.Secret.Generic\n\
                      attribute.service = sigil-factory\n\
                      attribute.username = fabrica@sigil.local\n";
        let accounts = parse_factory_accounts(stdout);
        assert_eq!(accounts, vec!["fabrica@sigil.local".to_string()]);
        assert!(!accounts.iter().any(|a| a.contains("constrasena")));
    }

    #[test]
    fn test_account_parsing_handles_several_entries_without_duplicates() {
        let stdout = "attribute.username = fabrica@sigil.local\n\
                      secret = x\n\
                      attribute.username = operario\n\
                      attribute.username = fabrica@sigil.local\n\
                      attribute.service = sigil-factory\n";
        assert_eq!(
            parse_factory_accounts(stdout),
            vec!["fabrica@sigil.local".to_string(), "operario".to_string()]
        );
    }

    #[test]
    fn test_account_parsing_of_an_empty_keyring_is_empty() {
        assert!(parse_factory_accounts("").is_empty());
        assert!(parse_factory_accounts("No results found\n").is_empty());
    }

    /// `secret-tool search` reparte su salida: el secreto y las etiquetas por
    /// stdout, los `attribute.*` por stderr. Leer un solo flujo devuelve cero
    /// cuentas con el keyring lleno, que es justo el fallo que esto evita.
    #[test]
    fn test_account_parsing_reads_the_stream_that_carries_the_attributes() {
        let stdout = "[/19]\nlabel = SIGIL Factory\nsecret = en-claro\nschema = org.freedesktop.Secret.Generic\n";
        let stderr = "attribute.service = sigil-factory\nattribute.username = fabrica@sigil.local\n";
        assert!(
            parse_factory_accounts(stdout).is_empty(),
            "los atributos no viajan por stdout"
        );
        let combined = format!("{}\n{}", stderr, stdout);
        assert_eq!(
            parse_factory_accounts(&combined),
            vec!["fabrica@sigil.local".to_string()]
        );
    }

    #[test]
    fn test_rejected_login_gives_a_way_out() {
        // El operario no puede teclear la contraseña en la interfaz por diseño:
        // el mensaje tiene que decirle exactamente cómo corregirla.
        let message = login_rejection_message(401, "sigil");
        assert!(message.contains("401"), "{}", message);
        assert!(message.contains("secret-tool store"), "sin salida: {}", message);
        assert!(message.contains("username sigil"));
    }

    /// Un 401 se produce igual con el nombre equivocado que con la contraseña
    /// equivocada. Si el mensaje empieza por «reescriba la contraseña», el
    /// operario la guarda otra vez bajo el nombre que ya estaba mal y vuelve a
    /// caer en el mismo 401.
    #[test]
    fn test_rejected_login_checks_the_account_name_before_the_password() {
        let message = login_rejection_message(401, "sigil");
        let name_hint = message.find("Cuenta de fábrica").expect("sin pista de nombre");
        let password_hint = message.find("secret-tool store").expect("sin salida");
        assert!(
            name_hint < password_hint,
            "el nombre se comprueba primero: {}",
            message
        );
    }

    #[test]
    fn test_other_server_errors_do_not_suggest_rewriting_the_password() {
        for status in [403u16, 500, 502] {
            let message = login_rejection_message(status, "sigil");
            assert!(message.contains(&status.to_string()));
            assert!(
                !message.contains("secret-tool store"),
                "un {} no se arregla reescribiendo la contraseña: {}",
                status,
                message
            );
        }
    }

    #[test]
    fn test_messages_never_carry_a_password() {
        // Los constructores no reciben la contraseña: no pueden filtrarla.
        let message = login_rejection_message(401, "sigil");
        assert!(!message.to_lowercase().contains("contraseña:"));
    }
}
