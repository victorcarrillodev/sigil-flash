use serde::{Serializer, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SigilError {
    #[error("Error I/O: {0}")]
    Io(#[from] std::io::Error),

    #[error("Error de Tauri: {0}")]
    Tauri(String),

    #[error("Error de Serialización: {0}")]
    Serialization(String),

    #[error("Error de Disco: {0}")]
    Disk(String),

    #[error("Error de Descarga: {0}")]
    Download(String),

    #[error("Error de Escritura/Flasheo: {0}")]
    Flash(String),

    #[error("Error de Configuración: {0}")]
    Config(String),

    #[error("Error de Validación: {0}")]
    Validation(String),

    #[error("Error Interno: {0}")]
    Internal(String),
}

impl From<serde_json::Error> for SigilError {
    fn from(err: serde_json::Error) -> Self {
        SigilError::Serialization(err.to_string())
    }
}

impl Serialize for SigilError {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

pub type Result<T> = std::result::Result<T, SigilError>;
