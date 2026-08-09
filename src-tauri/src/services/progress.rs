use crate::errors::Result;
use crate::models::FlashProgress;
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

pub struct ProgressTracker {
    start_time: Instant,
    last_bytes: u64,
    last_time: Instant,
}

impl ProgressTracker {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            start_time: now,
            last_bytes: 0,
            last_time: now,
        }
    }

    pub fn update(&mut self, current_bytes: u64, total_bytes: u64, status: &str, message: &str) -> FlashProgress {
        let now = Instant::now();
        let elapsed_total = now.duration_since(self.start_time).as_secs_f64();
        let elapsed_chunk = now.duration_since(self.last_time).as_secs_f64();

        let speed_mbps = if elapsed_chunk > 0.001 {
            let bytes_diff = current_bytes.saturating_sub(self.last_bytes);
            (bytes_diff as f64 / 1_048_576.0) / elapsed_chunk
        } else {
            0.0
        };

        let eta_seconds = if speed_mbps > 0.01 && total_bytes > current_bytes {
            let remaining_mb = (total_bytes - current_bytes) as f64 / 1_048_576.0;
            remaining_mb / speed_mbps
        } else if current_bytes >= total_bytes && total_bytes > 0 {
            0.0
        } else if elapsed_total > 0.0 {
            let avg_speed = (current_bytes as f64 / 1_048_576.0) / elapsed_total;
            if avg_speed > 0.01 && total_bytes > current_bytes {
                ((total_bytes - current_bytes) as f64 / 1_048_576.0) / avg_speed
            } else {
                0.0
            }
        } else {
            0.0
        };

        self.last_bytes = current_bytes;
        self.last_time = now;

        FlashProgress {
            bytes_written: current_bytes,
            total_bytes,
            speed_mbps,
            eta_seconds,
            status: status.to_string(),
            message: message.to_string(),
        }
    }
}

/// Escribe el progreso a un archivo JSON de forma atómica
pub fn write_progress_file(path: &Path, progress: &FlashProgress) -> Result<()> {
    let content = serde_json::to_string_pretty(progress)?;
    let tmp_path = path.with_extension("tmp");
    fs::write(&tmp_path, content)?;
    fs::rename(&tmp_path, path)?;
    Ok(())
}

/// Lee el progreso publicado desde un archivo JSON
pub fn read_progress_file(path: &Path) -> Result<Option<FlashProgress>> {
    if !path.exists() {
        return Ok(None);
    }
    match fs::read_to_string(path) {
        Ok(content) => match serde_json::from_str::<FlashProgress>(&content) {
            Ok(progress) => Ok(Some(progress)),
            Err(_) => Ok(None),
        },
        Err(_) => Ok(None),
    }
}

/// Recorta el stderr del proceso elevado a algo que quepa en la interfaz. Se
/// queda con el final porque el error real es lo último que se imprime.
fn stderr_tail(stderr: &str) -> String {
    const LIMITE: usize = 400;
    let utiles: Vec<&str> = stderr
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    let cola = utiles
        .iter()
        .rev()
        .take(3)
        .rev()
        .copied()
        .collect::<Vec<_>>()
        .join(" ");
    let total = cola.chars().count();
    if total <= LIMITE {
        return cola;
    }
    match cola.char_indices().nth(total - LIMITE) {
        Some((corte, _)) => format!("…{}", &cola[corte..]),
        None => cola,
    }
}

/// Por qué murió el proceso elevado. `pkexec` reserva 126 y 127 para sus
/// propios fallos de autorización; cualquier otro código viene del escritor y
/// culparlo a polkit manda al operario a arreglar lo que no está roto.
pub fn elevation_failure_message(exit_code: Option<i32>, stderr: &str) -> String {
    let detalle = stderr_tail(stderr);
    match exit_code {
        Some(126) => "La autorización administrativa fue cancelada: se cerró el diálogo de \
             pkexec sin autenticar."
            .to_string(),
        Some(127) => "pkexec no concedió la autorización. Compruebe que hay un agente de \
             polkit corriendo en la sesión y que su usuario puede ejecutar la acción."
            .to_string(),
        Some(code) if !detalle.is_empty() => format!(
            "El escritor privilegiado falló (código {}): {}",
            code, detalle
        ),
        Some(code) => format!(
            "El escritor privilegiado falló (código {}) sin publicar el motivo. Corre como \
             root, así que su registro está en /root/.local/share/sigil-flash/logs.",
            code
        ),
        None if !detalle.is_empty() => format!(
            "El proceso elevado terminó por una señal: {}",
            detalle
        ),
        None => "El proceso elevado terminó por una señal antes de publicar su estado".to_string(),
    }
}

/// Resuelve el estado final del progreso según las reglas de precedencia:
/// 1. El escritor es AUTORITATIVO: "done" gana sobre código de error del proceso.
/// 2. Proceso sale sin progreso: fallo solo tras 2s de gracia.
/// 3. Timeout a los 45 minutos.
/// 4. Se conserva el mensaje original de error/cancelación.
///
/// `exit_code` es `None` cuando una señal mató al proceso. `stderr` es lo que
/// el escritor imprimió: es la única vía por la que su error real llega a la
/// interfaz, porque su `tracing` escribe en el home de root.
pub fn resolve_final_progress(
    file_progress: Option<FlashProgress>,
    exit_code: Option<i32>,
    stderr: &str,
    process_exit_duration: Duration,
) -> FlashProgress {
    let process_exited_successfully = exit_code == Some(0);
    // Se conservan los contadores antes de consumir el progreso: si el escritor
    // muere, siguen siendo la única pista de hasta dónde llegó.
    let (bytes_written, total_bytes) = file_progress
        .as_ref()
        .map(|p| (p.bytes_written, p.total_bytes))
        .unwrap_or((0, 0));

    if let Some(prog) = file_progress {
        // Regla 1: "done" gana siempre
        if prog.status == "done" {
            return prog;
        }

        // Si ya tiene un estado explícito de error o cancelación, conservar su mensaje original
        if prog.status == "error" || prog.status == "cancelled" {
            return prog;
        }

        // Si el proceso terminó correctamente y el progreso está en verifying/running con total == escrito
        if process_exited_successfully && prog.bytes_written >= prog.total_bytes && prog.total_bytes > 0 {
            return FlashProgress {
                status: "done".to_string(),
                message: "Flasheo e instalación completados exitosamente".to_string(),
                ..prog
            };
        }
    }

    // Regla 2: el proceso terminó mal. Se conserva lo escrito hasta ahora —un
    // fallo tras 2,6 GB escritos no es lo mismo que uno antes del primer byte,
    // y poner el contador a cero borra justo el dato que sitúa la avería.
    if process_exit_duration >= Duration::from_secs(2) && !process_exited_successfully {
        return FlashProgress {
            bytes_written,
            total_bytes,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "error".to_string(),
            message: elevation_failure_message(exit_code, stderr),
        };
    }

    FlashProgress::idle()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_authoritative_done_state() {
        let prog = FlashProgress {
            bytes_written: 100,
            total_bytes: 100,
            speed_mbps: 10.0,
            eta_seconds: 0.0,
            status: "done".to_string(),
            message: "Operación exitosa".to_string(),
        };

        let resolved = resolve_final_progress(Some(prog.clone()), Some(1), "", Duration::from_secs(3));
        assert_eq!(resolved.status, "done");
        assert_eq!(resolved.message, "Operación exitosa");
    }

    #[test]
    fn test_error_message_retention() {
        let prog = FlashProgress {
            bytes_written: 50,
            total_bytes: 100,
            speed_mbps: 5.0,
            eta_seconds: 10.0,
            status: "error".to_string(),
            message: "Fallo específico en el chroot".to_string(),
        };

        let resolved = resolve_final_progress(Some(prog), Some(1), "", Duration::from_secs(1));
        assert_eq!(resolved.status, "error");
        assert_eq!(resolved.message, "Fallo específico en el chroot");
    }

    #[test]
    fn test_process_failed_without_progress() {
        let resolved = resolve_final_progress(None, Some(126), "", Duration::from_secs(3));
        assert_eq!(resolved.status, "error");
        assert!(resolved.message.contains("cancelada"), "{}", resolved.message);
    }

    /// El fallo que costó el diagnóstico: pkexec autorizó, el escritor volcó
    /// 2,6 GB y murió en el chroot, y la interfaz culpó a la autorización.
    /// Solo 126 y 127 son de pkexec; el resto es del escritor.
    #[test]
    fn test_writer_failure_is_not_blamed_on_polkit() {
        let stderr = "Error en --flash-raw: No se pudo montar la partición rootfs\n";
        let resolved = resolve_final_progress(None, Some(1), stderr, Duration::from_secs(3));
        assert_eq!(resolved.status, "error");
        assert!(
            !resolved.message.to_lowercase().contains("autorización"),
            "un código 1 no es un fallo de polkit: {}",
            resolved.message
        );
        assert!(
            resolved.message.contains("No se pudo montar la partición rootfs"),
            "el motivo real tiene que llegar a la interfaz: {}",
            resolved.message
        );
    }

    #[test]
    fn test_polkit_codes_keep_their_own_diagnosis() {
        let dismissed = elevation_failure_message(Some(126), "");
        assert!(dismissed.contains("cancelada"), "{}", dismissed);
        let denied = elevation_failure_message(Some(127), "");
        assert!(denied.to_lowercase().contains("polkit"), "{}", denied);
        // Ni siquiera con stderr del escritor: 126/127 los emite pkexec mismo.
        let still_polkit = elevation_failure_message(Some(126), "ruido irrelevante");
        assert!(!still_polkit.contains("ruido irrelevante"), "{}", still_polkit);
    }

    #[test]
    fn test_silent_writer_failure_points_at_the_root_log() {
        let message = elevation_failure_message(Some(3), "   \n  \n");
        assert!(message.contains("código 3"), "{}", message);
        assert!(message.contains("/root/.local/share/sigil-flash/logs"), "{}", message);
    }

    #[test]
    fn test_signal_death_is_not_an_exit_code() {
        let message = elevation_failure_message(None, "");
        assert!(message.to_lowercase().contains("señal"), "{}", message);
    }

    /// Un fallo tras escribir 2,6 GB no es lo mismo que uno antes del primer
    /// byte. Poner el contador a cero borra el dato que sitúa la avería.
    #[test]
    fn test_failure_keeps_what_was_already_written() {
        let prog = FlashProgress {
            bytes_written: 2_675_965_952,
            total_bytes: 2_675_965_952,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "verifying".to_string(),
            message: "Instalando paquetes y personalizando el sistema (chroot)...".to_string(),
        };

        let resolved = resolve_final_progress(Some(prog), Some(1), "fallo en el chroot", Duration::from_secs(3));
        assert_eq!(resolved.status, "error");
        assert_eq!(resolved.bytes_written, 2_675_965_952);
        assert_eq!(resolved.total_bytes, 2_675_965_952);
    }

    #[test]
    fn test_stderr_tail_keeps_the_last_lines_and_bounds_the_size() {
        let ruidoso = format!("linea vieja\n{}\nEl motivo real\n", "x".repeat(2000));
        let message = elevation_failure_message(Some(1), &ruidoso);
        assert!(message.contains("El motivo real"), "se conserva el final");
        assert!(!message.contains("linea vieja"), "se descarta la cabecera");
        assert!(message.len() < 600, "cabe en la interfaz: {} bytes", message.len());
    }
}
