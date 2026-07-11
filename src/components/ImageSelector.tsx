import { useState, useCallback } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { invoke } from "@tauri-apps/api/core";
import { ImageInfo } from "../App";

interface Props {
  image: ImageInfo | null;
  onImageSelected: (info: ImageInfo) => void;
  onClear: () => void;
}

const ACCEPTED_EXTENSIONS = ["img", "iso", "bin"];

export default function ImageSelector({ image, onImageSelected, onClear }: Props) {
  const [dragging, setDragging] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadImage = useCallback(async (path: string) => {
    setLoading(true);
    setError(null);
    try {
      const info = await invoke<ImageInfo>("get_image_info", { path });
      onImageSelected(info);
    } catch (err) {
      setError(`No se pudo cargar la imagen: ${err}`);
    } finally {
      setLoading(false);
    }
  }, [onImageSelected]);

  const handleOpenDialog = async () => {
    try {
      const selected = await open({
        multiple: false,
        filters: [{
          name: "Imágenes de disco",
          extensions: ACCEPTED_EXTENSIONS,
        }],
      });
      if (selected && typeof selected === "string") {
        await loadImage(selected);
      }
    } catch (err) {
      setError(`Error al abrir archivo: ${err}`);
    }
  };

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    setDragging(false);
    const file = e.dataTransfer.files[0];
    if (!file) return;

    const ext = file.name.split(".").pop()?.toLowerCase() ?? "";
    if (!ACCEPTED_EXTENSIONS.includes(ext)) {
      setError(`Formato no soportado: .${ext}. Usa .img, .iso, o .bin`);
      return;
    }

    // In Tauri, we get the path from the file object via webkitRelativePath or name
    // The actual file path is available via the drop event in Tauri
    // @ts-ignore – Tauri provides the path on the file object
    const filePath = file.path || (e.dataTransfer.items[0] as unknown as { getAsEntry?: () => FileSystemEntry })?.getAsEntry?.()?.fullPath;
    if (!filePath) {
      setError("No se pudo obtener la ruta del archivo. Usa el botón de abrir.");
      return;
    }
    await loadImage(filePath);
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "8px", width: "100%" }}>
      {loading ? (
        <div className="form-input" style={{ display: "flex", alignItems: "center", gap: 8, color: "var(--text-muted)" }}>
          <div style={{
            width: 14, height: 14,
            border: "2px solid var(--shadow-dark)",
            borderTopColor: "var(--accent)",
            borderRadius: "50%",
            animation: "spin 0.8s linear infinite",
          }} />
          <span>Analizando...</span>
        </div>
      ) : image ? (
        <div
          className="form-input"
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            borderColor: "var(--accent)",
            boxShadow: "0 0 4px var(--accent-glow), var(--shadow-inset-sm)",
          }}
        >
          <span style={{ fontSize: 14 }}>💿</span>
          <span
            style={{
              flex: 1,
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
              fontSize: "12px",
              fontWeight: 600,
            }}
            title={image.name}
          >
            {image.name}
          </span>
          <button
            onClick={(e) => { e.stopPropagation(); onClear(); }}
            title="Quitar imagen"
            style={{
              background: "none",
              border: "none",
              cursor: "pointer",
              color: "var(--text-muted)",
              fontSize: 14,
              padding: "0 4px",
              display: "flex",
              alignItems: "center",
            }}
          >
            ✕
          </button>
        </div>
      ) : (
        <div
          onClick={handleOpenDialog}
          className="form-input"
          style={{
            cursor: "pointer",
            display: "flex",
            alignItems: "center",
            gap: 8,
            color: "var(--text-secondary)",
            background: "var(--surface)",
            boxShadow: "var(--shadow-raised-sm)",
            border: "1px solid transparent",
          }}
          onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={handleDrop}
        >
          <span style={{ fontSize: 14 }}>{dragging ? "📥" : "📂"}</span>
          <span style={{ fontSize: "11px", fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {dragging ? "¡Suelta aquí!" : "Seleccionar imagen (.img, .iso, .bin)..."}
          </span>
        </div>
      )}

      {error && (
        <div style={{
          padding: "6px 10px",
          borderRadius: "var(--radius-sm)",
          background: "var(--danger-bg)",
          fontSize: "10px",
          color: "var(--danger)",
          display: "flex",
          gap: 6,
          alignItems: "flex-start",
        }}>
          <span>⚠️</span>
          <span style={{ flex: 1 }}>{error}</span>
          <button
            onClick={() => setError(null)}
            style={{ background: "none", border: "none", cursor: "pointer", color: "var(--danger)", padding: 0 }}
          >✕</button>
        </div>
      )}
    </div>
  );
}
