import { useState, useCallback, useEffect } from "react";
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
  const [rpiModel, setRpiModel] = useState<RPiModel>("Raspberry Pi 4 (64-bit)");

  // Custom visual tab states
  const [activeTab, setActiveTab] = useState<"vista-previa" | "ssh" | "historial" | "motor">("vista-previa");

  // Custom OS configuration states
  const [sshEnabled, setSshEnabled] = useState(true);
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [pinPanel, setPinPanel] = useState("");
  const [logPassword, setLogPassword] = useState("");
  const [hostname, setHostname] = useState("");
  const [serialNumber, setSerialNumber] = useState("");
  const [wifiSsid, setWifiSsid] = useState("");
  const [wifiPassword, setWifiPassword] = useState("");

  const addLog = useCallback((msg: string, type: LogEntry["type"] = "info") => {
    const now = new Date();
    const time = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}:${String(now.getSeconds()).padStart(2, "0")}`;
    setLogs(prev => [...prev.slice(-200), { time, msg, type }]);
  }, []);

  useEffect(() => {
    let unlisten: UnlistenFn | undefined;
    const setup = async () => {
      unlisten = await listen<FlashProgress>("flash-progress", (event) => {
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
    };
    setup();
    return () => { unlisten?.(); };
  }, [addLog]);

  const handleImageSelected = (info: ImageInfo) => {
    setImage(info);
    setStep("select-device");
    addLog(`Imagen seleccionada: ${info.name} (${formatSize(info.size)})`, "success");
  };

  const handleFlashClick = () => {
    if (!image || !device) return;
    setShowConfirm(true);
  };

  const handleConfirmFlash = async () => {
    setShowConfirm(false);
    if (!image || !device) return;
    setStep("flashing");
    setIsFlashing(true);
    setLogs([]);
    setProgress(null);
    addLog(`Iniciando flasheo: ${image.name} → ${device.path}`, "info");
    addLog("Solicitando permisos de administrador...", "warning");
    try {
      await invoke("start_flash", { imagePath: image.path, devicePath: device.path });
      
      if (!rpiModel.includes("Pico")) {
        try {
          addLog("Inyectando configuración y optimizaciones en la partición boot...", "warning");
          const config = {
            hostname,
            username,
            password: password || null,
            wifiSsid: wifiSsid || null,
            wifiPassword: wifiPassword || null,
            sshEnabled,
            rpiModel,
            serialNumber: serialNumber || null,
          };
          await invoke("save_device_config", { mountPath: device.path, config });
          addLog("¡Configuración y optimizaciones inyectadas con éxito!", "success");
        } catch (configErr) {
          addLog(`Advertencia: No se pudo inyectar la configuración: ${configErr}`, "warning");
        }
      }

      setIsFlashing(false);
      setStep("done");
      addLog("¡Proceso completado exitosamente!", "success");
    } catch (err) {
      addLog(`Error: ${err}`, "error");
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
    setUsername("pi");
    setPassword("raspberry");
    setHostname("raspberrypi");
    setWifiSsid("");
    setWifiPassword("");
  };

  const isDone = step === "done";
  const canFlash = image !== null && device !== null;

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
