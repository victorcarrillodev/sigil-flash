use serde::Serialize;
use thiserror::Error;

/// Core error hierarchy for the Sigil Flash application.
/// Integrates with `thiserror` for clean formatting, and implements `Serialize`
/// to allow direct propagation across Tauri IPC boundaries to React.
#[derive(Debug, Error)]
pub enum AppError {
    #[error("Fallo de E/S del sistema: {0}")]
    Io(#[from] std::io::Error),

    #[error("Error interno del framework Tauri: {0}")]
    Tauri(#[from] tauri::Error),

    #[error("Error de formato/serialización de datos: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Error en servicio de discos: {0}")]
    Disk(String),

    #[error("Fallo en la descarga de imagen: {0}")]
    Download(String),

    #[error("Fallo durante el flasheo de la unidad: {0}")]
    Flash(String),

    #[error("Error de configuración del sistema operativo: {0}")]
    Config(String),

    #[error("Error de validación: {0}")]
    Validation(String),

    #[error("Error interno inesperado: {0}")]
    Internal(String),
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        // Serialize the error using its Display representation
        serializer.serialize_str(&self.to_string())
    }
}

/// Type alias for simpler result propagation throughout the backend.
pub type AppResult<T> = Result<T, AppError>;
