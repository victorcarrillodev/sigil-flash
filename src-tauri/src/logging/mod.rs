use crate::errors::AppResult;
use directories::ProjectDirs;
use std::path::PathBuf;
use tracing_appender::rolling::{RollingFileAppender, Rotation};
use tracing_subscriber::{fmt, prelude::*, EnvFilter, Registry};

/// Initializes the tracing logging framework.
/// Configures a multi-layered subscriber:
/// 1. A formatted stdout layer for console logging.
/// 2. A daily rotating file layer saved under the user's local app data directory.
///
/// Returns a `WorkerGuard` which must be kept alive in `main` to ensure logs
/// are flushed asynchronously before application exit.
pub fn init_logging() -> AppResult<tracing_appender::non_blocking::WorkerGuard> {
    // Establish standard cross-platform local application directory for logs
    let log_dir = if let Some(proj_dirs) = ProjectDirs::from("com", "sigilflash", "sigil-flash") {
        proj_dirs.data_local_dir().join("logs")
    } else {
        PathBuf::from("./logs")
    };

    // Ensure the log directory exists
    std::fs::create_dir_all(&log_dir)?;

    // Set up a daily rolling file appender
    let file_appender = RollingFileAppender::new(Rotation::DAILY, &log_dir, "sigil-flash.log");

    let (non_blocking_writer, guard) = tracing_appender::non_blocking(file_appender);

    // File layer does not use ANSI colors for cleaner parsing
    let file_layer = fmt::layer()
        .with_writer(non_blocking_writer)
        .with_ansi(false)
        .with_target(true)
        .with_thread_ids(true);

    // Console stdout layer
    let stdout_layer = fmt::layer().with_ansi(true).with_target(true);

    // Env filter defaults to 'info' if RUST_LOG environment variable is not defined
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    // Register all log layers
    Registry::default()
        .with(filter)
        .with(stdout_layer)
        .with(file_layer)
        .init();

    tracing::info!(
        "Logs del sistema inicializados. Archivos guardados en: {}",
        log_dir.display()
    );

    Ok(guard)
}
