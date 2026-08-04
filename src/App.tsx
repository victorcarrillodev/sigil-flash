import { useState, useCallback, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import Header from "./components/Header";
import Sidebar from "./components/Sidebar";
import CenterPanel from "./components/CenterPanel";
import ConfirmModal from "./components/ConfirmModal";

export interface ImageInfo {
  path: string;
  name: string;
  size: number;
}

export interface Device {
  name: string;
  path: string;
  size: string;
  model: string;
  type: string;
  removable: boolean;
  transport: string;
}

export type RPiModel =
  | "Raspberry Pi 5 (64-bit)"
  | "Raspberry Pi 4 (64-bit)"
  | "Raspberry Pi 4 (32-bit)"
  | "Raspberry Pi 3 (64-bit)"
  | "Raspberry Pi 3 (32-bit)"
  | "Raspberry Pi 2"
  | "Raspberry Pi 1"
  | "Raspberry Pi Zero 2 W (64-bit)"
  | "Raspberry Pi Zero 2 W (32-bit)"
  | "Raspberry Pi Zero W (32-bit)"
  | "Raspberry Pi Zero (32-bit)"
  | "Raspberry Pi Pico 2 W"
  | "Raspberry Pi Pico 2"
  | "Raspberry Pi Pico W"
  | "Raspberry Pi Pico";

export interface FlashProgress {
  bytes_written: number;
  total_bytes: number;
  speed_mbps: number;
  eta_seconds: number;
  status: "running" | "done" | "error" | "cancelled";
  message: string;
}

export type AppStep = "select-image" | "select-device" | "flashing" | "done";

export interface LogEntry {
  time: string;
  msg: string;
  type: "info" | "success" | "error" | "warning";
}

export function formatSize(bytes: number): string {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
}

export default function App() {
  const [step, setStep] = useState<AppStep>("select-image");
  const [image, setImage] = useState<ImageInfo | null>(null);
  const [device, setDevice] = useState<Device | null>(null);
  const [showConfirm, setShowConfirm] = useState(false);
  const [progress, setProgress] = useState<FlashProgress | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [isFlashing, setIsFlashing] = useState(false);
  const flashRequestActive = useRef(false);
  const [rpiModel, setRpiModel] = useState<RPiModel>("Raspberry Pi 4 (64-bit)");

  // Custom visual tab states
  const [activeTab, setActiveTab] = useState<"vista-previa" | "ssh" | "historial" | "motor">("vista-previa");

  // Custom OS configuration states
  const [sshEnabled, setSshEnabled] = useState(true);
  const [username, setUsername] = useState("sigil");
  const [password, setPassword] = useState("");
  const [pinPanel, setPinPanel] = useState("");
  const [logPassword, setLogPassword] = useState("");
  const [hostname, setHostname] = useState("sigil");
  const [serialNumber, setSerialNumber] = useState("");
  const [sigilModel, setSigilModel] = useState("Sigil-Streamer");
  const [sigilModelVersion, setSigilModelVersion] = useState("v1");
  const [wifiSsid, setWifiSsid] = useState("");
  const [wifiPassword, setWifiPassword] = useState("");

  const addLog = useCallback((msg: string, type: LogEntry["type"] = "info") => {
    const now = new Date();
    const time = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}:${String(now.getSeconds()).padStart(2, "0")}`;
    setLogs(prev => [...prev.slice(-200), { time, msg, type }]);
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: UnlistenFn | undefined;
    const setup = async () => {
      const listener = await listen<FlashProgress>("flash-progress", (event) => {
        setProgress(event.payload);
        if (event.payload.message) {
          const t = event.payload.status === "error" ? "error"
            : event.payload.status === "done" ? "success" : "info";
          addLog(event.payload.message, t);
        }
        if (event.payload.status === "error") { setIsFlashing(false); }
        if (event.payload.status === "cancelled") {
          setIsFlashing(false);
          addLog("Flasheo cancelado por el usuario.", "warning");
        }
      });
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    };
    void setup();
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [addLog]);

  const handleImageSelected = (info: ImageInfo) => {
    setImage(info);
    setStep("select-device");
    addLog(`Imagen seleccionada: ${info.name} (${formatSize(info.size)})`, "success");
  };

  const handleFlashClick = () => {
    if (!image || !device || isFlashing || flashRequestActive.current) return;
    const normalizedPanelPin = pinPanel.trim();
    const validationError = validateManufacturingInputs({
      rpiModel,
      sshEnabled,
      username,
      password,
      panelPin: normalizedPanelPin,
      hostname,
      serialNumber,
    });
    if (validationError) {
      addLog(validationError, "error");
      return;
    }
    setShowConfirm(true);
  };

  const handleConfirmFlash = async () => {
    if (!image || !device || flashRequestActive.current) return;
    flashRequestActive.current = true;
    setShowConfirm(false);
    setStep("flashing");
    setIsFlashing(true);
    setLogs([]);
    setProgress(null);
    addLog(`Iniciando flasheo: ${image.name} → ${device.path}`, "info");
    addLog("Solicitando permisos de administrador...", "warning");
    try {
      const normalizedPanelPin = pinPanel.trim();
      const config = {
        hostname,
        username,
        password: sshEnabled ? password || null : null,
        wifiSsid: wifiSsid || null,
        wifiPassword: wifiSsid ? wifiPassword || null : null,
        sshEnabled,
        rpiModel,
        serialNumber: serialNumber || null,
        sigilModel: sigilModel || null,
        sigilModelVersion: sigilModelVersion || null,
        panelPin: normalizedPanelPin || null,
      };
      await invoke("start_flash", {
        imagePath: image.path,
        devicePath: device.path,
        config,
      });

      setStep("done");
      setPassword("");
      setPinPanel("");
      setLogPassword("");
      addLog("¡Proceso completado exitosamente!", "success");
    } catch (err) {
      addLog(`Error: ${err}`, "error");
    } finally {
      flashRequestActive.current = false;
      setIsFlashing(false);
    }
  };

  const handleCancelFlash = async () => {
    try {
      await invoke("cancel_flash");
      addLog("Enviando señal de cancelación...", "warning");
    } catch (err) {
      addLog(`No se pudo cancelar: ${err}`, "error");
    }
  };

  const handleReset = () => {
    setStep("select-image");
    setImage(null);
    setDevice(null);
    setProgress(null);
    setLogs([]);
    setIsFlashing(false);
    setActiveTab("vista-previa");
    setSshEnabled(true);
    setUsername("sigil");
    setPassword("");
    setPinPanel("");
    setLogPassword("");
    setHostname("sigil");
    setSerialNumber("");
    setWifiSsid("");
    setWifiPassword("");
  };

  const isDone = step === "done";
  const canFlash = image !== null && device !== null && !isFlashing;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", overflow: "hidden" }}>
      <Header />

      <div className="app-shell" style={{ marginTop: 0 }}>
        {/* Left Column: configuration parameters */}
        <Sidebar
          image={image}
          device={device}
          rpiModel={rpiModel}
          onRpiModelChange={setRpiModel}
          onImageSelected={handleImageSelected}
          onImageClear={() => setImage(null)}
          onDeviceSelect={setDevice}
          isFlashing={isFlashing}
          isDone={isDone}
          sshEnabled={sshEnabled} setSshEnabled={setSshEnabled}
          username={username} setUsername={setUsername}
          password={password} setPassword={setPassword}
          pinPanel={pinPanel} setPinPanel={setPinPanel}
          logPassword={logPassword} setLogPassword={setLogPassword}
          hostname={hostname} setHostname={setHostname}
          serialNumber={serialNumber} setSerialNumber={setSerialNumber}
          sigilModel={sigilModel} setSigilModel={setSigilModel}
          sigilModelVersion={sigilModelVersion} setSigilModelVersion={setSigilModelVersion}
          wifiSsid={wifiSsid} setWifiSsid={setWifiSsid}
          wifiPassword={wifiPassword} setWifiPassword={setWifiPassword}
        />

        {/* Unified Main Content View */}
        <main className="main-content" style={{ padding: "0 16px 16px 16px", flex: 1, overflow: "hidden" }}>
          <CenterPanel
            image={image}
            device={device}
            rpiModel={rpiModel}
            progress={progress}
            logs={logs}
            isFlashing={isFlashing}
            isDone={isDone}
            canFlash={canFlash}
            onFlash={handleFlashClick}
            onCancel={handleCancelFlash}
            onReset={handleReset}
            activeTab={activeTab}
            setActiveTab={setActiveTab}
            sshEnabled={sshEnabled}
            setSshEnabled={setSshEnabled}
            username={username}
            setUsername={setUsername}
            password={password}
            setPassword={setPassword}
            hostname={hostname}
            setHostname={setHostname}
            serialNumber={serialNumber}
            setSerialNumber={setSerialNumber}
            pinPanel={pinPanel}
            setPinPanel={setPinPanel}
            logPassword={logPassword}
            setLogPassword={setLogPassword}
            wifiSsid={wifiSsid}
            setWifiSsid={setWifiSsid}
            wifiPassword={wifiPassword}
            setWifiPassword={setWifiPassword}
          />
        </main>
      </div>

      {showConfirm && image && device && (
        <ConfirmModal
          image={image}
          device={device}
          onConfirm={handleConfirmFlash}
          onCancel={() => setShowConfirm(false)}
        />
      )}
    </div>
  );
}

interface ManufacturingInputs {
  rpiModel: RPiModel;
  sshEnabled: boolean;
  username: string;
  password: string;
  panelPin: string;
  hostname: string;
  serialNumber: string;
}

export function validateManufacturingInputs(inputs: ManufacturingInputs): string | null {
  if (inputs.rpiModel.includes("Pico")) {
    return "El flujo de fabricación Linux no admite Raspberry Pi Pico.";
  }
  if (inputs.username !== "sigil") {
    return "El usuario del sistema debe ser 'sigil'.";
  }
  if (!/^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/.test(inputs.hostname)) {
    return "El hostname debe tener entre 1 y 63 caracteres seguros.";
  }
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(inputs.serialNumber)) {
    return "El número de serie es obligatorio y solo admite letras, números, punto, guion y guion bajo.";
  }
  if (!/^\d{6,12}$/.test(inputs.panelPin)) {
    return "El PIN del panel debe contener entre 6 y 12 dígitos.";
  }
  const repeatedPin = [...inputs.panelPin].every((digit) => digit === inputs.panelPin[0]);
  const ascendingPin = "12345678901234567890".includes(inputs.panelPin);
  const descendingPin = "98765432109876543210".includes(inputs.panelPin);
  if (repeatedPin || ascendingPin || descendingPin) {
    return "El PIN del panel es demasiado predecible.";
  }
  if (inputs.sshEnabled) {
    if (inputs.password.length < 6 || inputs.password.length > 128) {
      return "La contraseña SSH debe tener entre 6 y 128 caracteres.";
    }
    if (/[\r\n\0]/.test(inputs.password)) {
      return "La contraseña SSH contiene caracteres no permitidos.";
    }
  }
  return null;
}
