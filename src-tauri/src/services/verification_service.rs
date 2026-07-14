use crate::errors::{AppError, AppResult};
use crate::models::FlashProgress;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Instant;
use tauri::{AppHandle, Emitter};
use tokio::fs::File;
use tokio::io::AsyncReadExt;

pub struct VerificationService;

impl VerificationService {
    pub fn new() -> Self {
        Self
    }

    /// Verifies the integrity of a file against a given SHA-256 hash or calculates and returns it.
    /// Emits periodic verification progress events to the frontend.
    pub async fn verify_sha256(
        &self,
        file_path: &Path,
        expected_hash: Option<&str>,
        app: AppHandle,
    ) -> AppResult<String> {
        tracing::info!(
            "Iniciando verificación SHA-256 para el archivo: {}",
            file_path.display()
        );

        let mut file = File::open(file_path).await.map_err(AppError::Io)?;

        let metadata = file.metadata().await?;
        let total_bytes = metadata.len();

        let mut hasher = Sha256::new();
        let mut buffer = vec![0; 1024 * 1024]; // 1MB buffer
        let mut bytes_read = 0u64;

        let start_time = Instant::now();
        let mut last_emit = Instant::now();

        // Emit initial verification event
        let _ = app.emit(
            "download-progress",
            FlashProgress {
                bytes_written: 0,
                total_bytes,
                speed_mbps: 0.0,
                eta_seconds: 0.0,
                status: "verifying".to_string(),
                message: "Iniciando cálculo de integridad SHA-256...".to_string(),
            },
        );

        loop {
            let len = file.read(&mut buffer).await.map_err(AppError::Io)?;

            if len == 0 {
                break;
            }

            hasher.update(&buffer[..len]);
            bytes_read += len as u64;

            let now = Instant::now();
            let elapsed = now.duration_since(start_time).as_secs_f64();

            if now.duration_since(last_emit).as_millis() >= 250 || bytes_read == total_bytes {
                let speed = if elapsed > 0.0 {
                    (bytes_read as f64 / elapsed) / (1024.0 * 1024.0)
                } else {
                    0.0
                };

                let eta = if speed > 0.0 {
                    ((total_bytes - bytes_read) as f64) / (speed * 1024.0 * 1024.0)
                } else {
                    0.0
                };

                let pct = (bytes_read as f64 / total_bytes as f64) * 100.0;
                let _ = app.emit(
                    "download-progress",
                    FlashProgress {
                        bytes_written: bytes_read,
                        total_bytes,
                        speed_mbps: speed,
                        eta_seconds: eta,
                        status: "verifying".to_string(),
                        message: format!("Verificando integridad... ({:.1}%)", pct),
                    },
                );
                last_emit = now;
            }
        }

        let hash_result = format!("{:x}", hasher.finalize());
        tracing::info!("Cálculo SHA-256 finalizado: {}", hash_result);

        if let Some(expected) = expected_hash {
            if hash_result.eq_ignore_ascii_case(expected.trim()) {
                let _ = app.emit(
                    "download-progress",
                    FlashProgress {
                        bytes_written: total_bytes,
                        total_bytes,
                        speed_mbps: 0.0,
                        eta_seconds: 0.0,
                        status: "done".to_string(),
                        message: "Verificación de firma SHA-256 exitosa.".to_string(),
                    },
                );
                Ok(hash_result)
            } else {
                let _ = app.emit(
                    "download-progress",
                    FlashProgress {
                        bytes_written: bytes_read,
                        total_bytes,
                        speed_mbps: 0.0,
                        eta_seconds: 0.0,
                        status: "error".to_string(),
                        message: format!(
                            "La firma SHA-256 no coincide. Esperada: {}, Calculada: {}",
                            expected, hash_result
                        ),
                    },
                );
                Err(AppError::Validation(format!(
                    "Integridad comprometida: la firma calculada {} no coincide con la esperada {}",
                    hash_result, expected
                )))
            }
        } else {
            let _ = app.emit(
                "download-progress",
                FlashProgress {
                    bytes_written: total_bytes,
                    total_bytes,
                    speed_mbps: 0.0,
                    eta_seconds: 0.0,
                    status: "done".to_string(),
                    message: format!("Firma calculada: {}", hash_result),
                },
            );
            Ok(hash_result)
        }
    }
}
