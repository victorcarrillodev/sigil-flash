import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Device } from "../App";

interface Props {
  selectedDevice: Device | null;
  onDeviceSelect: (device: Device) => void;
  disabled: boolean;
}

export default function DeviceList({ selectedDevice, onDeviceSelect, disabled }: Props) {
  const [devices, setDevices] = useState<Device[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchDevices = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const devs = await invoke<Device[]>("list_devices");
      setDevices(devs);
    } catch (err) {
      setError(`${err}`);
      setDevices([]);
    } finally {
      setLoading(false);
    }
  }, []);

  // Initial load + auto-refresh every 4 seconds
  useEffect(() => {
    fetchDevices();
    const interval = setInterval(fetchDevices, 4000);
    return () => clearInterval(interval);
  }, [fetchDevices]);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "6px", width: "100%" }}>
      <div style={{ position: "relative", display: "flex", alignItems: "center" }}>
        <select
          value={selectedDevice?.path || ""}
          onChange={(e) => {
            const dev = devices.find(d => d.path === e.target.value);
            if (dev) {
              onDeviceSelect(dev);
            }
          }}
          disabled={disabled || loading}
          className="neu-select"
          style={{ paddingRight: "36px" }}
        >
          {loading && devices.length === 0 ? (
            <option value="">Detectando dispositivos...</option>
          ) : devices.length === 0 ? (
            <option value="">No se encontraron dispositivos</option>
          ) : (
            <>
              <option value="">Seleccionar dispositivo...</option>
              {devices.map((dev) => (
                <option key={dev.path} value={dev.path}>
                  {dev.path} ({dev.size}) — {dev.model || dev.name}
                </option>
              ))}
            </>
          )}
        </select>
        
        {/* Spinner or refresh indicator overlay inside select */}
        {loading && (
          <div style={{
            position: "absolute",
            right: "32px",
            pointerEvents: "none",
            display: "flex",
            alignItems: "center"
          }}>
            <div style={{
              width: 12, height: 12,
              border: "1.5px solid var(--shadow-dark)",
              borderTopColor: "var(--accent)",
              borderRadius: "50%",
              animation: "spin 0.8s linear infinite",
            }} />
          </div>
        )}
      </div>

      {error && (
        <div style={{
          padding: "6px 10px",
          borderRadius: "var(--radius-sm)",
          background: "var(--danger-bg)",
          fontSize: "10px",
          color: "var(--danger)",
        }}>
          ⚠️ {error}
        </div>
      )}
    </div>
  );
}
