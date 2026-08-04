import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";

interface ServerConfig {
  server_url: string;
  has_keyring_password: boolean;
}

interface Props {
  isOpen: boolean;
  onClose: () => void;
  initialError?: string | null;
  onSuccess?: () => void;
}

export default function ServerLoginModal({ isOpen, onClose, initialError, onSuccess }: Props) {
  const [serverUrl, setServerUrl] = useState("");
  const [factoryPassword, setFactoryPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [hasKeyringPassword, setHasKeyringPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen) {
      setErrorMsg(initialError || null);
      setSuccessMsg(null);
      setFactoryPassword("");
      loadConfig();
    }
  }, [isOpen, initialError]);

  const loadConfig = async () => {
    try {
      const config = await invoke<ServerConfig>("get_server_config");
      setServerUrl(config.server_url || "https://sigil-server.sphinx-pickerel.ts.net");
      setHasKeyringPassword(config.has_keyring_password);
    } catch (err) {
      console.error("Error al cargar configuración del servidor:", err);
    }
  };

  if (!isOpen) return null;

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!serverUrl.trim()) {
      setErrorMsg("La URL del servidor no puede estar vacía.");
      return;
    }

    setLoading(true);
    setErrorMsg(null);
    setSuccessMsg(null);

    try {
      await invoke("save_server_config", {
        serverUrl: serverUrl.trim(),
        factoryPassword: factoryPassword.trim() || null,
      });

      setSuccessMsg("¡Configuración y credenciales guardadas exitosamente!");
      setHasKeyringPassword(true);
      setFactoryPassword("");

      if (onSuccess) {
        onSuccess();
      }

      setTimeout(() => {
        onClose();
      }, 1200);
    } catch (err: any) {
      setErrorMsg(typeof err === "string" ? err : err.message || "Error al guardar la configuración");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-box" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 480 }}>
        {/* Header with Icon */}
        <div style={{ display: "flex", alignItems: "center", gap: 14, marginBottom: 20 }}>
          <div style={{
            width: 48,
            height: 48,
            borderRadius: "16px",
            background: "var(--surface)",
            boxShadow: "var(--shadow-raised-sm)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 22,
            flexShrink: 0,
            border: "1px solid var(--border-light)",
          }}>
            🔑
          </div>
          <div>
            <h2 className="text-lg font-bold text-primary" style={{ letterSpacing: "-0.01em", margin: 0 }}>
              Servidor de Fabricación SIGIL
            </h2>
            <p className="text-xs text-secondary mt-xs" style={{ margin: 0 }}>
              Configura la URL de la API backend y la contraseña de provisión (`fabrica`)
            </p>
          </div>
        </div>

        {/* Dynamic Alerts */}
        {errorMsg && (
          <div style={{
            padding: "10px 14px",
            borderRadius: "var(--radius-md)",
            background: "var(--danger-bg)",
            borderLeft: "3px solid var(--danger)",
            marginBottom: 16,
            fontSize: 12,
            color: "var(--danger)",
            lineHeight: 1.5,
          }}>
            ⚠️ <strong>Error:</strong> {errorMsg}
          </div>
        )}

        {successMsg && (
          <div style={{
            padding: "10px 14px",
            borderRadius: "var(--radius-md)",
            background: "var(--success-bg, rgba(46, 204, 113, 0.15))",
            borderLeft: "3px solid var(--success, #2ecc71)",
            marginBottom: 16,
            fontSize: 12,
            color: "var(--success, #2ecc71)",
            lineHeight: 1.5,
          }}>
            ✅ {successMsg}
          </div>
        )}

        <form onSubmit={handleSave}>
          <div style={{ display: "flex", flexDirection: "column", gap: 16, marginBottom: 24 }}>
            {/* Server URL Input */}
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: "var(--text-primary)", marginBottom: 6 }}>
                URL del Servidor Backend (SIGIL API)
              </label>
              <input
                type="url"
                className="input-text"
                placeholder="https://sigil-server.sphinx-pickerel.ts.net"
                value={serverUrl}
                onChange={(e) => setServerUrl(e.target.value)}
                style={{ width: "100%", padding: "10px 14px", fontSize: 13, borderRadius: "var(--radius-md)" }}
                required
              />
              <span style={{ fontSize: 10, color: "var(--text-muted)", display: "block", marginTop: 4 }}>
                Se guardará en <code style={{ fontFamily: "var(--font-mono)" }}>~/.config/sigil-flash/config.toml</code>
              </span>
            </div>

            {/* Factory Username */}
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: "var(--text-primary)", marginBottom: 6 }}>
                Usuario de Provisión
              </label>
              <input
                type="text"
                className="input-text"
                value="fabrica"
                disabled
                style={{ width: "100%", padding: "10px 14px", fontSize: 13, borderRadius: "var(--radius-md)", opacity: 0.75, cursor: "not-allowed" }}
              />
            </div>

            {/* Factory Password */}
            <div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                <label style={{ fontSize: 12, fontWeight: 600, color: "var(--text-primary)" }}>
                  Contraseña de Fabricación
                </label>
                {hasKeyringPassword && (
                  <span style={{ fontSize: 11, color: "var(--success, #2ecc71)", fontWeight: 600 }}>
                    ✓ Keyring configurado
                  </span>
                )}
              </div>
              <div style={{ position: "relative" }}>
                <input
                  type={showPassword ? "text" : "password"}
                  className="input-text"
                  placeholder={hasKeyringPassword ? "•••••••• (Dejar en blanco para mantener actual)" : "Ingresa la contraseña del usuario fabrica"}
                  value={factoryPassword}
                  onChange={(e) => setFactoryPassword(e.target.value)}
                  style={{ width: "100%", padding: "10px 40px 10px 14px", fontSize: 13, borderRadius: "var(--radius-md)" }}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  style={{
                    position: "absolute",
                    right: 10,
                    top: "50%",
                    transform: "translateY(-50%)",
                    background: "none",
                    border: "none",
                    cursor: "pointer",
                    fontSize: 14,
                    opacity: 0.7,
                  }}
                  title={showPassword ? "Ocultar contraseña" : "Mostrar contraseña"}
                >
                  {showPassword ? "👁️" : "🙈"}
                </button>
              </div>
              <span style={{ fontSize: 10, color: "var(--text-muted)", display: "block", marginTop: 4 }}>
                Se almacenará de forma segura en GNOME Keyring vía <code style={{ fontFamily: "var(--font-mono)" }}>secret-tool</code>
              </span>
            </div>
          </div>

          {/* Action Buttons */}
          <div style={{ display: "flex", gap: 12, justifyContent: "flex-end" }}>
            <button
              type="button"
              className="btn btn-secondary"
              onClick={onClose}
              style={{ fontSize: 13, padding: "8px 16px" }}
              disabled={loading}
            >
              Cancelar
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              style={{ fontSize: 13, padding: "8px 20px" }}
              disabled={loading}
            >
              {loading ? "Guardando..." : "Guardar Credenciales"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
