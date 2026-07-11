import ImageSelector from "./ImageSelector";
import DeviceList from "./DeviceList";
import { ImageInfo, Device, RPiModel } from "../App";
import { BoardSVG } from "./BoardIcons";
interface Props {
  image: ImageInfo | null;
  device: Device | null;
  rpiModel: RPiModel;
  onRpiModelChange: (model: RPiModel) => void;
  onImageSelected: (info: ImageInfo) => void;
  onImageClear: () => void;
  onDeviceSelect: (dev: Device) => void;
  isFlashing: boolean;
  isDone: boolean;
  sshEnabled: boolean;
  setSshEnabled: (val: boolean) => void;
  username: string;
  setUsername: (val: string) => void;
  password: string;
  setPassword: (val: string) => void;
  pinPanel: string;
  setPinPanel: (val: string) => void;
  logPassword: string;
  setLogPassword: (val: string) => void;
  hostname: string;
  setHostname: (val: string) => void;
  serialNumber: string;
  setSerialNumber: (val: string) => void;
  wifiSsid: string;
  setWifiSsid: (val: string) => void;
  wifiPassword: string;
  setWifiPassword: (val: string) => void;
}

interface PiModelOption {
  id: RPiModel;
  name: string;
  sub: string;
  arch: string;
  bits: "64-bit" | "32-bit" | "MCU";
}

const PI_MODELS_DATA: Record<string, PiModelOption[]> = {
  "RASPBERRY PI 5": [
    { id: "Raspberry Pi 5 (64-bit)", name: "Pi 5", sub: "ARMv8.2 (64-bit)", arch: "ARMv8.2", bits: "64-bit" }
  ],
  "RASPBERRY PI 4": [
    { id: "Raspberry Pi 4 (64-bit)", name: "Pi 4 (64-bit)", sub: "ARMv8 (64-bit)", arch: "ARMv8", bits: "64-bit" },
    { id: "Raspberry Pi 4 (32-bit)", name: "Pi 4 (32-bit)", sub: "ARMv8 (32-bit)", arch: "ARMv8", bits: "32-bit" }
  ],
  "RASPBERRY PI 3": [
    { id: "Raspberry Pi 3 (64-bit)", name: "Pi 3 (64-bit)", sub: "ARMv8 (64-bit)", arch: "ARMv8", bits: "64-bit" },
    { id: "Raspberry Pi 3 (32-bit)", name: "Pi 3 (32-bit)", sub: "ARMv8 (32-bit)", arch: "ARMv8", bits: "32-bit" }
  ],
  "RASPBERRY PI 2": [
    { id: "Raspberry Pi 2", name: "Pi 2", sub: "ARMv7 (32-bit)", arch: "ARMv7", bits: "32-bit" }
  ],
  "RASPBERRY PI 1": [
    { id: "Raspberry Pi 1", name: "Pi 1", sub: "ARMv6 (32-bit)", arch: "ARMv6", bits: "32-bit" }
  ],
  "RASPBERRY PI ZERO": [
    { id: "Raspberry Pi Zero 2 W (64-bit)", name: "Zero 2 W (64-bit)", sub: "ARMv8 (64-bit)", arch: "ARMv8", bits: "64-bit" },
    { id: "Raspberry Pi Zero 2 W (32-bit)", name: "Zero 2 W (32-bit)", sub: "ARMv8 (32-bit)", arch: "ARMv8", bits: "32-bit" },
    { id: "Raspberry Pi Zero W (32-bit)", name: "Zero W (32-bit)", sub: "ARMv6 (32-bit)", arch: "ARMv6", bits: "32-bit" },
    { id: "Raspberry Pi Zero (32-bit)", name: "Zero (32-bit)", sub: "ARMv6 (32-bit)", arch: "ARMv6", bits: "32-bit" }
  ],
  "RASPBERRY PI PICO": [
    { id: "Raspberry Pi Pico 2 W", name: "Pico 2W", sub: "Cortex-M33", arch: "Cortex-M33", bits: "MCU" },
    { id: "Raspberry Pi Pico 2", name: "Pico 2", sub: "Cortex-M33", arch: "Cortex-M33", bits: "MCU" },
    { id: "Raspberry Pi Pico W", name: "Pico W", sub: "Cortex-M0+", arch: "Cortex-M0+", bits: "MCU" },
    { id: "Raspberry Pi Pico", name: "Pico", sub: "Cortex-M0+", arch: "Cortex-M0+", bits: "MCU" }
  ]
};



export default function Sidebar({
  image, device, rpiModel, onRpiModelChange, onImageSelected, onImageClear, onDeviceSelect, isFlashing, isDone,
  sshEnabled, setSshEnabled,
  username, setUsername,
  password, setPassword,
  pinPanel, setPinPanel,
  logPassword, setLogPassword,
  hostname, setHostname,
  serialNumber, setSerialNumber,
  wifiSsid, setWifiSsid,
  wifiPassword, setWifiPassword
}: Props) {
  return (
    <aside className="sidebar" style={{ gap: "14px", overflowY: "auto", display: "flex", flexDirection: "column" }}>
      
      {/* Section 1: Almacenamiento */}
      <div className="panel-section" style={{ borderBottom: "1px dashed var(--shadow-dark)", paddingBottom: 14 }}>
        <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
          <div style={{
            width: 24, height: 24, borderRadius: "8px",
            background: "var(--accent-bg)", color: "var(--accent)",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 14, fontWeight: 700,
          }}>
            💾
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Almacenamiento</span>
            <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 500 }}>Selecciona la SD y la imagen a escribir</span>
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: "10px", marginTop: 4 }}>
          {/* Tarjeta MicroSD Dropdown */}
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span style={{ fontSize: "11px", fontWeight: 700, color: "var(--text-muted)", letterSpacing: "0.05em" }}>TARJETA MICROSD</span>
            <DeviceList
              selectedDevice={device}
              onDeviceSelect={onDeviceSelect}
              disabled={isFlashing || isDone}
            />
          </div>

          {/* Imagen de Linux */}
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span style={{ fontSize: "11px", fontWeight: 700, color: "var(--text-muted)", letterSpacing: "0.05em" }}>IMAGEN DE LINUX</span>
            <ImageSelector
              image={image}
              onImageSelected={onImageSelected}
              onClear={onImageClear}
            />
          </div>
        </div>
      </div>

      {/* Section 2: Modelo de Raspberry Pi */}
      <div className="panel-section" style={{
        display: "flex",
        flexDirection: "column",
        opacity: isFlashing || isDone ? 0.6 : 1,
        pointerEvents: isFlashing || isDone ? "none" : "auto",
        transition: "opacity var(--transition)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "4px" }}>
          <div style={{
            width: 24, height: 24, borderRadius: "8px",
            background: "var(--accent-bg)", color: "var(--accent)",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 14, fontWeight: 700,
          }}>
            🍓
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Modelo de Raspberry Pi</span>
            <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 500 }}>Define la arquitectura del sistema operativo</span>
          </div>
        </div>

        {/* Categories and visual grids */}
        <div style={{ display: "flex", flexDirection: "column", marginTop: 6 }}>
          {Object.entries(PI_MODELS_DATA).map(([categoryName, models]) => (
            <div key={categoryName} style={{ display: "flex", flexDirection: "column" }}>
              <div className="model-category-title">{categoryName}</div>
              <div className="model-grid">
                {models.map((model) => {
                  const isSelected = rpiModel === model.id;
                  return (
                    <div
                      key={model.id}
                      className={`model-card ${isSelected ? "selected" : ""}`}
                      onClick={() => onRpiModelChange(model.id)}
                    >
                      <div style={{
                        width: "56px", height: "42px",
                        display: "flex", alignItems: "center", justifyContent: "center",
                        opacity: isSelected ? 1 : 0.45,
                        filter: isSelected ? "none" : "grayscale(100%) brightness(0.7)",
                        transition: "all var(--transition)",
                        marginBottom: "4px"
                      }}>
                        <BoardSVG model={model.id} />
                      </div>
                      <div className="model-card-title">{model.name}</div>
                      <span className="model-card-badge">{model.bits}</span>
                      <span className="model-card-arch">{model.arch}</span>
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Section 3: Configuración de Usuario */}
      <div className="panel-section" style={{
        display: "flex", flexDirection: "column",
        opacity: isFlashing || isDone ? 0.6 : 1, pointerEvents: isFlashing || isDone ? "none" : "auto", transition: "opacity var(--transition)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
          <div style={{ width: 24, height: 24, borderRadius: "8px", background: "var(--accent-bg)", color: "var(--accent)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, fontWeight: 700 }}>
            👤
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Configuración de Usuario</span>
            <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 500 }}>Credenciales del primer arranque</span>
          </div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
          <div className="form-group">
            <label className="form-label">USUARIO</label>
            <input type="text" className="form-input" value={username} onChange={(e) => setUsername(e.target.value)} placeholder="victor" />
          </div>
          <div className="form-group">
            <label className="form-label">CONTRASEÑA</label>
            <input type="password" className="form-input" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" />
          </div>
          <div className="form-group">
            <label className="form-label">PIN DEL PANEL</label>
            <input type="password" className="form-input" value={pinPanel} onChange={(e) => setPinPanel(e.target.value)} placeholder="4821" />
          </div>
          <div className="form-group">
            <label className="form-label">CONTRASEÑA DE LOGS</label>
            <input type="password" className="form-input" value={logPassword} onChange={(e) => setLogPassword(e.target.value)} placeholder="••••••••" />
          </div>
        </div>
      </div>

      {/* Section 4: Identidad del Dispositivo */}
      <div className="panel-section" style={{
        display: "flex", flexDirection: "column",
        opacity: isFlashing || isDone ? 0.6 : 1, pointerEvents: isFlashing || isDone ? "none" : "auto", transition: "opacity var(--transition)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
          <div style={{ width: 24, height: 24, borderRadius: "8px", background: "var(--accent-bg)", color: "var(--accent)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, fontWeight: 700 }}>
            🗄️
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Identidad del Dispositivo</span>
            <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 500 }}>Hostname y número de serie único</span>
          </div>
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "10px" }}>
          <div className="form-group">
            <label className="form-label">HOSTNAME</label>
            <input type="text" className="form-input" value={hostname} onChange={(e) => setHostname(e.target.value)} placeholder="sigil-device-1" />
          </div>
          <div className="form-group">
            <label className="form-label">NÚMERO DE SERIE</label>
            <input type="text" className="form-input" value={serialNumber} onChange={(e) => setSerialNumber(e.target.value)} placeholder="SIGIL-000001" />
          </div>
        </div>
      </div>

      {/* Section 5: Red Wi-Fi */}
      <div className="panel-section" style={{
        display: "flex", flexDirection: "column",
        opacity: isFlashing || isDone ? 0.6 : 1, pointerEvents: isFlashing || isDone ? "none" : "auto", transition: "opacity var(--transition)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
          <div style={{ width: 24, height: 24, borderRadius: "8px", background: "var(--accent-bg)", color: "var(--accent)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, fontWeight: 700 }}>
            📶
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Red Wi-Fi</span>
            <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 500 }}>Conexión automática en primer arranque</span>
          </div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
          <div className="form-group">
            <label className="form-label">NOMBRE DE RED (SSID)</label>
            <input type="text" className="form-input" value={wifiSsid} onChange={(e) => setWifiSsid(e.target.value)} placeholder="MiRedWiFi" />
          </div>
          <div className="form-group">
            <label className="form-label">CONTRASEÑA WI-FI</label>
            <input type="password" className="form-input" value={wifiPassword} onChange={(e) => setWifiPassword(e.target.value)} placeholder="••••••••" />
          </div>
        </div>
      </div>

      {/* Section 6: Habilitar SSH */}
      <div className="panel-section" style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        opacity: isFlashing || isDone ? 0.6 : 1, pointerEvents: isFlashing || isDone ? "none" : "auto", transition: "opacity var(--transition)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
          <div style={{ width: 24, height: 24, borderRadius: "8px", background: "var(--accent-bg)", color: "var(--accent)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, fontWeight: 700 }}>
            🛡️
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Habilitar SSH</span>
            <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 500 }}>Acceso remoto desde el primer arranque</span>
          </div>
        </div>
        <label className="neu-switch">
          <input type="checkbox" checked={sshEnabled} onChange={(e) => setSshEnabled(e.target.checked)} />
          <span className="neu-switch-slider"></span>
        </label>
      </div>


      
    </aside>
  );
}
