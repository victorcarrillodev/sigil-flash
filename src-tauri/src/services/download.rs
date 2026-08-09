use crate::errors::{Result, SigilError};
use crate::services::verification::calculate_sha256;
use futures_util::StreamExt;
use reqwest::Client;
use std::fs::File;
use std::io::Write;
use std::path::Path;
use tracing::info;

pub async fn download_file_with_progress<F>(
    url: &str,
    output_path: &Path,
    expected_sha256: Option<&str>,
    mut progress_callback: F,
) -> Result<()>
where
    F: FnMut(u64, u64),
{
    let client = Client::new();
    let resp = client.get(url).send().await.map_err(|e| {
        SigilError::Download(format!("No se pudo conectar a URL {}: {}", url, e))
    })?;

    if !resp.status().is_success() {
        return Err(SigilError::Download(format!(
            "Descarga falló con estado HTTP {}",
            resp.status()
        )));
    }

    let total_size = resp.content_length().unwrap_or(0);
    let mut file = File::create(output_path)?;
    let mut stream = resp.bytes_stream();
    let mut downloaded: u64 = 0;

    while let Some(chunk_result) = stream.next().await {
        let chunk = chunk_result.map_err(|e| {
            SigilError::Download(format!("Error de lectura durante la descarga: {}", e))
        })?;

        file.write_all(&chunk)?;
        downloaded += chunk.len() as u64;
        progress_callback(downloaded, total_size);
    }

    file.flush()?;
    info!("Descarga completada: {} ({} bytes)", output_path.display(), downloaded);

    if let Some(expected_hash) = expected_sha256 {
        let actual_hash = calculate_sha256(output_path)?;
        if actual_hash != expected_hash {
            return Err(SigilError::Download(format!(
                "Verificación SHA-256 de descarga falló: esperado {}, obtenido {}",
                expected_hash, actual_hash
            )));
        }
        info!("Verificación SHA-256 exitosa para archivo descargado");
    }

    Ok(())
}
