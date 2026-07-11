import { ImageInfo, Device, formatSize } from "../App";

interface Props {
  image: ImageInfo;
  device: Device;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ConfirmModal({ image, device, onConfirm, onCancel }: Props) {
  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal-box" onClick={(e) => e.stopPropagation()}>
        {/* Warning icon */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginBottom: 24, gap: 12 }}>
          <div style={{
            width: 72, height: 72,
            borderRadius: "20px",
            background: "var(--surface)",
            boxShadow: "var(--shadow-raised), 0 0 30px var(--danger-shadow)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 32,
          }}>
            ⚠️
          </div>
          <div style={{ textAlign: "center" }}>
            <h2 className="text-xl font-bold text-primary" style={{ letterSpacing: "-0.02em" }}>
              ¿Confirmar flasheo?
            </h2>
            <p className="text-sm text-secondary mt-xs">
              Esta acción <strong>borrará permanentemente</strong> todos los datos del dispositivo
            </p>
          </div>
        </div>

        {/* Warning alert */}
        <div style={{
          padding: "12px 16px",
          borderRadius: "var(--radius-md)",
          background: "var(--danger-bg)",
          boxShadow: "inset 2px 2px 5px rgba(0, 0, 0, 0.08), inset -2px -2px 5px rgba(255, 255, 255, 0.15)",
          marginBottom: 20,
          borderLeft: "3px solid var(--danger)",
        }}>
          <p style={{ fontSize: 12, color: "var(--danger)", fontWeight: 600, marginBottom: 6 }}>
            🚨 ACCIÓN DESTRUCTIVA E IRREVERSIBLE
          </p>
          <p style={{ fontSize: 12, color: "var(--text-secondary)", lineHeight: 1.6 }}>
            Todos los datos en <code style={{ color: "var(--danger)", fontFamily: "var(--font-mono)" }}>{device.path}</code> serán destruidos. Asegúrate de haber respaldado cualquier información importante.
          </p>
        </div>

        {/* Summary */}
        <div style={{
          display: "flex",
          flexDirection: "column",
          gap: 8,
          padding: "14px 16px",
          borderRadius: "var(--radius-md)",
          background: "var(--bg-deep)",
          boxShadow: "var(--shadow-inset)",
          marginBottom: 24,
        }}>
          <ConfirmRow emoji="🖼️" label="Imagen" value={image.name} />
          <ConfirmRow emoji="📦" label="Tamaño" value={formatSize(image.size)} />
          <ConfirmRow emoji="💾" label="Destino" value={device.path} mono />
          <ConfirmRow emoji="🔌" label="Modelo" value={device.model || device.name} />
          <ConfirmRow emoji="💿" label="Capacidad" value={device.size} />
        </div>

        {/* Actions */}
        <div style={{ display: "flex", gap: 12 }}>
          <button
            className="btn btn-secondary w-full"
            onClick={onCancel}
            style={{ fontSize: 13 }}
          >
            Cancelar
          </button>
          <button
            className="btn btn-danger w-full"
            onClick={onConfirm}
            style={{ fontSize: 13 }}
          >
            ⚡ Flashear ahora
          </button>
        </div>

        <p className="text-xs text-muted text-center mt-sm">
          Se solicitará tu contraseña de administrador
        </p>
      </div>
    </div>
  );
}

function ConfirmRow({ emoji, label, value, mono }: {
  emoji: string; label: string; value: string; mono?: boolean;
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 13 }}>
      <span style={{ fontSize: 14 }}>{emoji}</span>
      <span style={{ color: "var(--text-muted)", minWidth: 70, fontWeight: 500 }}>{label}</span>
      <span style={{
        color: "var(--text-primary)",
        fontWeight: 600,
        fontFamily: mono ? "var(--font-mono)" : "var(--font-sans)",
        fontSize: mono ? 12 : 13,
        flex: 1,
        textAlign: "right",
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap",
      }}>
        {value}
      </span>
    </div>
  );
}
