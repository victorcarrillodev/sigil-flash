use crate::errors::{AppResult, AppError};
use crate::models::FlashProgress;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::task::AbortHandle;
use tauri::{AppHandle, Emitter};
use futures_util::StreamExt;
use std::time::Instant;
use tokio::fs::File;
use tokio::io::AsyncWriteExt;

pub struct DownloadService {
    abort_handle: Arc<Mutex<Option<AbortHandle>>>,
}

impl DownloadService {
    pub fn new() -> Self {
        Self {
            abort_handle: Arc::new(Mutex::new(None)),
        }
    }

    /// Starts downloading a file from a URL and saves it asynchronously to the destination path.
    /// Manages cancellation by tracking the task's AbortHandle.
    pub async fn start_download(
        &self,
        url: &str,
        destination: PathBuf,
        app: AppHandle,
    ) -> AppResult<PathBuf> {
        // Stop any active download prior to beginning a new one
        self.cancel_download().await?;

        let url_str = url.to_string();
        let dest = destination.clone();
        let app_handle = app.clone();

        let task = tokio::spawn(async move {
            Self::download_task(&url_str, &dest, app_handle).await
        });

        // Register the new abort handle
        {
            let mut guard = self.abort_handle.lock().await;
            *guard = Some(task.abort_handle());
        }

        // Wait for task completion
        match task.await {
            Ok(result) => {
                let mut guard = self.abort_handle.lock().await;
                *guard = None;
                result.map(|_| destination)
            }
            Err(join_err) => {
                let mut guard = self.abort_handle.lock().await;
                *guard = None;
                if join_err.is_cancelled() {
                    let _ = app.emit("download-progress", FlashProgress {
                        bytes_written: 0,
                        total_bytes: 0,
                        speed_mbps: 0.0,
                        eta_seconds: 0.0,
                        status: "cancelled".to_string(),
                        message: "Descarga cancelada por el usuario".to_string(),
                    });
                    Err(AppError::Download("Descarga cancelada".to_string()))
                } else {
                    Err(AppError::Internal(format!("Error en el hilo de descarga: {}", join_err)))
                }
            }
        }
    }

    /// Aborts the active download task if one is running.
    pub async fn cancel_download(&self) -> AppResult<()> {
        let mut guard = self.abort_handle.lock().await;
        if let Some(handle) = guard.take() {
            tracing::info!("Abortando descarga activa por petición de cancelación...");
            handle.abort();
        }
        Ok(())
    }

    /// The asynchronous task running in the background executing the request stream.
    async fn download_task(
        url: &str,
        destination: &PathBuf,
        app: AppHandle,
    ) -> AppResult<()> {
        tracing::info!("Iniciando flujo de descarga hacia: {}", destination.display());

        let client = reqwest::Client::new();
        let response = client
            .get(url)
            .send()
            .await
            .map_err(|e| AppError::Download(format!("Fallo al contactar el servidor remoto: {}", e)))?;

        if !response.status().is_success() {
            return Err(AppError::Download(format!(
                "El servidor devolvió un código de error de respuesta: {}",
                response.status()
            )));
        }

        let total_size = response
            .content_length()
            .ok_or_else(|| AppError::Download("No se pudo obtener el tamaño del archivo desde el servidor (Falta Content-Length)".to_string()))?;

        // Create directories if missing
        if let Some(parent) = destination.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        // Open target file asynchronously
        let mut file = File::create(destination)
            .await
            .map_err(|e| AppError::Download(format!("No se pudo inicializar archivo en disco: {}", e)))?;

        let mut stream = response.bytes_stream();
        let mut bytes_written = 0u64;
        let start_time = Instant::now();
        let mut last_emit = Instant::now();

        // Emit initial connection event
        let _ = app.emit("download-progress", FlashProgress {
            bytes_written: 0,
            total_bytes: total_size,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "running".to_string(),
            message: "Enlace establecido. Transmitiendo...".to_string(),
        });

        while let Some(chunk_res) = stream.next().await {
            let chunk = chunk_res.map_err(|e| AppError::Download(format!("Error en el stream de red: {}", e)))?;
            
            // Non-blocking async file write
            file.write_all(&chunk)
                .await
                .map_err(|e| AppError::Io(e))?;

            bytes_written += chunk.len() as u64;

            let now = Instant::now();
            let elapsed = now.duration_since(start_time).as_secs_f64();

            // Throttle UI events to 250ms to keep interface highly responsive
            if now.duration_since(last_emit).as_millis() >= 250 || bytes_written == total_size {
                let speed = if elapsed > 0.0 {
                    (bytes_written as f64 / elapsed) / (1024.0 * 1024.0)
                } else {
                    0.0
                };

                let eta = if speed > 0.0 {
                    ((total_size - bytes_written) as f64) / (speed * 1024.0 * 1024.0)
                } else {
                    0.0
                };

                let pct = (bytes_written as f64 / total_size as f64) * 100.0;
                let _ = app.emit("download-progress", FlashProgress {
                    bytes_written,
                    total_bytes: total_size,
                    speed_mbps: speed,
                    eta_seconds: eta,
                    status: "running".to_string(),
                    message: format!("Descargando imagen... ({:.1}%)", pct),
                });
                last_emit = now;
            }
        }

        // Async sync file buffers
        file.sync_all().await?;

        let _ = app.emit("download-progress", FlashProgress {
            bytes_written: total_size,
            total_bytes: total_size,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "done".to_string(),
            message: "Descarga completada y verificada en almacenamiento local.".to_string(),
        });

        tracing::info!("Descarga completada con éxito: {}", destination.display());
        Ok(())
    }
}
