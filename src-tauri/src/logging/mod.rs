use std::path::PathBuf;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init_logging() -> Result<WorkerGuard, String> {
    let proj_dirs = directories::ProjectDirs::from("com", "sigil", "sigil-flash")
        .ok_or_else(|| "No se pudo determinar el directorio de datos local del usuario".to_string())?;

    let log_dir: PathBuf = proj_dirs.data_local_dir().join("logs");
    if let Err(e) = std::fs::create_dir_all(&log_dir) {
        return Err(format!("No se pudo crear el directorio de logs {}: {}", log_dir.display(), e));
    }

    let file_appender = tracing_appender::rolling::daily(&log_dir, "sigil-flash.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    let env_filter = EnvFilter::try_from_env("SIGIL_LOG")
        .unwrap_or_else(|_| EnvFilter::new("info"));

    let stdout_layer = fmt::layer()
        .with_ansi(true)
        .with_target(false);

    let file_layer = fmt::layer()
        .with_ansi(false)
        .with_target(true)
        .with_writer(non_blocking);

    if let Err(e) = tracing_subscriber::registry()
        .with(env_filter)
        .with(stdout_layer)
        .with(file_layer)
        .try_init()
    {
        return Err(format!("Error inicializando el sistema de logging: {}", e));
    }

    tracing::info!("Sistema de logging inicializado. Logs guardados en: {}", log_dir.display());

    Ok(guard)
}
