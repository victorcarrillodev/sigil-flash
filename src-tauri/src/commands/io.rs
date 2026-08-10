use crate::errors::{Result, SigilError};
use calamine::{open_workbook_auto, Reader};
use rust_xlsxwriter::Workbook;
use std::fs;

/// Escribe texto en una ruta que el operario eligió con el diálogo nativo de
/// guardar. El webview no tiene acceso directo al sistema de archivos, así
/// que la exportación de historial en CSV pasa por aquí.
#[tauri::command]
pub fn write_text_file(path: String, contents: String) -> Result<()> {
    fs::write(path, contents)?;
    Ok(())
}

/// Lee texto de una ruta que el operario eligió con el diálogo nativo de
/// abrir. Usado por la importación de historial en CSV.
#[tauri::command]
pub fn read_text_file(path: String) -> Result<String> {
    Ok(fs::read_to_string(path)?)
}

/// Escribe una única hoja como archivo .xlsx real. `rows` ya incluye la fila
/// de cabecera: qué campo va en qué columna lo decide el frontend, este
/// comando solo vuelca celdas de texto a un libro Excel. Se evalúa en Rust y
/// no con una librería JS de por medio: las versiones de `xlsx` (SheetJS)
/// publicadas en npm no tienen parche disponible ahí para su vulnerabilidad
/// de contaminación de prototipos ni la de ReDoS.
#[tauri::command]
pub fn export_xlsx(path: String, rows: Vec<Vec<String>>) -> Result<()> {
    let mut workbook = Workbook::new();
    let worksheet = workbook.add_worksheet();
    worksheet
        .set_name("Historial")
        .map_err(|e| SigilError::Internal(format!("No se pudo nombrar la hoja: {}", e)))?;

    for (row_idx, row) in rows.iter().enumerate() {
        for (col_idx, value) in row.iter().enumerate() {
            worksheet
                .write(row_idx as u32, col_idx as u16, value.as_str())
                .map_err(|e| SigilError::Internal(format!("No se pudo escribir la celda: {}", e)))?;
        }
    }

    workbook
        .save(&path)
        .map_err(|e| SigilError::Internal(format!("No se pudo guardar el archivo Excel: {}", e)))?;
    Ok(())
}

/// Lee la primera hoja de un .xlsx y la devuelve como texto, fila a fila, sin
/// interpretar tipos: el frontend aplica sobre estas filas la misma lectura
/// tolerante que usa para CSV, en vez de duplicar esa lógica aquí.
#[tauri::command]
pub fn import_xlsx(path: String) -> Result<Vec<Vec<String>>> {
    let mut workbook = open_workbook_auto(&path)
        .map_err(|e| SigilError::Validation(format!("No se pudo abrir el archivo Excel: {}", e)))?;

    let sheet_name = workbook
        .sheet_names()
        .first()
        .cloned()
        .ok_or_else(|| SigilError::Validation("El archivo Excel no tiene hojas".to_string()))?;

    let range = workbook
        .worksheet_range(&sheet_name)
        .map_err(|e| SigilError::Validation(format!("No se pudo leer la hoja '{}': {}", sheet_name, e)))?;

    Ok(range
        .rows()
        .map(|row| row.iter().map(|cell| cell.to_string()).collect())
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_text_file_round_trip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("historial.csv");
        let contenido = "hostname;estado\nsigil-device-01;done\n".to_string();

        write_text_file(path.to_str().unwrap().to_string(), contenido.clone()).unwrap();
        let leido = read_text_file(path.to_str().unwrap().to_string()).unwrap();

        assert_eq!(leido, contenido);
    }

    #[test]
    fn test_read_text_file_missing_path_fails() {
        let err = read_text_file("/ruta/que/no/existe/historial.csv".to_string()).unwrap_err();
        assert!(matches!(err, SigilError::Io(_)));
    }

    #[test]
    fn test_xlsx_round_trip_preserves_cells_as_text() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("historial.xlsx");
        let filas = vec![
            vec!["hostname".to_string(), "estado".to_string()],
            vec!["sigil-device-01".to_string(), "done".to_string()],
            vec!["sigil-device-02".to_string(), "error".to_string()],
        ];

        export_xlsx(path.to_str().unwrap().to_string(), filas.clone()).unwrap();
        let leidas = import_xlsx(path.to_str().unwrap().to_string()).unwrap();

        assert_eq!(leidas, filas);
    }

    #[test]
    fn test_import_xlsx_missing_path_fails() {
        let err = import_xlsx("/ruta/que/no/existe/historial.xlsx".to_string()).unwrap_err();
        assert!(matches!(err, SigilError::Validation(_)));
    }

    #[test]
    fn test_export_xlsx_tolerates_empty_history() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vacio.xlsx");

        export_xlsx(path.to_str().unwrap().to_string(), vec![]).unwrap();
        let leidas = import_xlsx(path.to_str().unwrap().to_string()).unwrap();

        assert!(leidas.is_empty());
    }
}
