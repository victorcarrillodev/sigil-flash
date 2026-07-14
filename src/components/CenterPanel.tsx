import { useMemo, useRef, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ImageInfo, Device, RPiModel, FlashProgress, LogEntry, formatSize } from "../App";
import { BoardSVG } from "./BoardIcons";
import EnginePanel from "./EnginePanel";

interface Props {
  image: ImageInfo | null;
  device: Device | null;
  rpiModel: RPiModel;
  progress: FlashProgress | null;
  logs: LogEntry[];
  isFlashing: boolean;
  isDone: boolean;
  canFlash: boolean;
  onFlash: () => void;
  onCancel: () => void;
  onReset: () => void;

  activeTab: "vista-previa" | "ssh" | "historial" | "motor";
  setActiveTab: (tab: "vista-previa" | "ssh" | "historial" | "motor") => void;

  sshEnabled: boolean;
  setSshEnabled: (val: boolean) => void;
  username: string;
  setUsername: (val: string) => void;
  password: string;
  setPassword: (val: string) => void;
  hostname: string;
  setHostname: (val: string) => void;
  serialNumber: string;
  setSerialNumber: (val: string) => void;
  pinPanel: string;
  setPinPanel: (val: string) => void;
  logPassword: string;
  setLogPassword: (val: string) => void;
  wifiSsid: string;
  setWifiSsid: (val: string) => void;
  wifiPassword: string;
  setWifiPassword: (val: string) => void;
}

interface ModelSpec {
  cpu: string;
  ram: string;
  ports: string;
  arch: string;
  kernel: string;
  firmware: string;
}

const MODEL_SPECS: Record<RPiModel, ModelSpec> = {
  "Raspberry Pi 5 (64-bit)": {
    cpu: "Broadcom BCM2712 Quad-Core @ 2.4GHz",
    ram: "4GB / 8GB LPDDR4X",
    ports: "Dual 4K HDMI, USB 3.0, PCIe 2.0",
    arch: "ARMv8.2 (64-bit)",
    kernel: "64-bit OS",
    firmware: "arm_64bit=1 (Forzado 64-bit)"
  },
  "Raspberry Pi 4 (64-bit)": {
    cpu: "Broadcom BCM2711 Quad-Core @ 1.5GHz",
    ram: "2GB / 4GB / 8GB LPDDR4",
    ports: "Dual micro-HDMI, USB 3.0, Gigabit Ethernet",
    arch: "ARMv8 (64-bit)",
    kernel: "64-bit OS",
    firmware: "arm_64bit=1 (Forzado 64-bit)"
  },
  "Raspberry Pi 4 (32-bit)": {
    cpu: "Broadcom BCM2711 Quad-Core @ 1.5GHz",
    ram: "2GB / 4GB / 8GB LPDDR4",
    ports: "Dual micro-HDMI, USB 3.0, Gigabit Ethernet",
    arch: "ARMv8 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi 3 (64-bit)": {
    cpu: "Broadcom BCM2837B0 Quad-Core @ 1.4GHz",
    ram: "1GB LPDDR2",
    ports: "Full HDMI, USB 2.0, Ethernet",
    arch: "ARMv8 (64-bit)",
    kernel: "64-bit OS",
    firmware: "arm_64bit=1 (Forzado 64-bit)"
  },
  "Raspberry Pi 3 (32-bit)": {
    cpu: "Broadcom BCM2837B0 Quad-Core @ 1.4GHz",
    ram: "1GB LPDDR2",
    ports: "Full HDMI, USB 2.0, Ethernet",
    arch: "ARMv8 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi Zero 2 W (64-bit)": {
    cpu: "Broadcom BCM2710A1 Quad-Core @ 1.0GHz",
    ram: "512MB LPDDR2",
    ports: "Mini-HDMI, Micro-USB OTG, Wifi 2.4GHz",
    arch: "ARMv8 (64-bit)",
    kernel: "64-bit OS",
    firmware: "arm_64bit=1 (Forzado 64-bit)"
  },
  "Raspberry Pi Zero 2 W (32-bit)": {
    cpu: "Broadcom BCM2710A1 Quad-Core @ 1.0GHz",
    ram: "512MB LPDDR2",
    ports: "Mini-HDMI, Micro-USB OTG, Wifi 2.4GHz",
    arch: "ARMv8 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi Zero W (32-bit)": {
    cpu: "Broadcom BCM2835 Single-Core @ 1.0GHz",
    ram: "512MB LPDDR2",
    ports: "Mini-HDMI, Micro-USB OTG, Wifi 2.4GHz",
    arch: "ARMv6 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi Zero (32-bit)": {
    cpu: "Broadcom BCM2835 Single-Core @ 1.0GHz",
    ram: "512MB LPDDR2",
    ports: "Mini-HDMI, Micro-USB OTG, No Wireless",
    arch: "ARMv6 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi 2": {
    cpu: "Broadcom BCM2836 Quad-Core @ 900MHz",
    ram: "1GB LPDDR2",
    ports: "HDMI, 4x USB 2.0, Ethernet",
    arch: "ARMv7 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi 1": {
    cpu: "Broadcom BCM2835 Single-Core @ 700MHz",
    ram: "512MB LPDDR2",
    ports: "HDMI, 2x USB 2.0, Ethernet",
    arch: "ARMv6 (32-bit)",
    kernel: "32-bit OS",
    firmware: "arm_64bit=0 (Forzado 32-bit)"
  },
  "Raspberry Pi Pico 2 W": {
    cpu: "RP2350 Dual Cortex-M33 / RISC-V @ 150MHz",
    ram: "520KB SRAM, 4MB Flash",
    ports: "Micro-USB, Wi-Fi 4 / BLE",
    arch: "Cortex-M33 / Hazard3",
    kernel: "MCU / Baremetal",
    firmware: "UF2 Bootloader"
  },
  "Raspberry Pi Pico 2": {
    cpu: "RP2350 Dual Cortex-M33 / RISC-V @ 150MHz",
    ram: "520KB SRAM, 4MB Flash",
    ports: "Micro-USB",
    arch: "Cortex-M33 / Hazard3",
    kernel: "MCU / Baremetal",
    firmware: "UF2 Bootloader"
  },
  "Raspberry Pi Pico W": {
    cpu: "RP2040 Dual Cortex-M0+ @ 133MHz",
    ram: "264KB SRAM, 2MB Flash",
    ports: "Micro-USB, Wi-Fi 4",
    arch: "Cortex-M0+",
    kernel: "MCU / Baremetal",
    firmware: "UF2 Bootloader"
  },
  "Raspberry Pi Pico": {
    cpu: "RP2040 Dual Cortex-M0+ @ 133MHz",
    ram: "264KB SRAM, 2MB Flash",
    ports: "Micro-USB",
    arch: "Cortex-M0+",
    kernel: "MCU / Baremetal",
    firmware: "UF2 Bootloader"
  }
};


function formatETA(sec: number): string {
  if (sec <= 0) return "finalizando...";
  const roundedSec = Math.round(sec);
  if (roundedSec < 60) return `${roundedSec}s`;
  const m = Math.floor(roundedSec / 60);
  const s = roundedSec % 60;
  return `${m}m ${s}s`;
}

function DonutGauge({ 
  pct, 
  sublabel, 
  pctBoot,
  pctOS,
  pctPanel,
  pctServices,
  pctMusic,
  pctFree
}: { 
  pct: number; 
  sublabel: string; 
  pctBoot: number;
  pctOS: number;
  pctPanel: number;
  pctServices: number;
  pctMusic: number;
  pctFree: number;
}) {
  const R = 40;
  const circ = 2 * Math.PI * R;

  const filledBoot = (pctBoot / 100) * circ;
  const filledOS = (pctOS / 100) * circ;
  const filledPanel = (pctPanel / 100) * circ;
  const filledServices = (pctServices / 100) * circ;
  const filledMusic = (pctMusic / 100) * circ;
  const filledFree = (pctFree / 100) * circ;

  const pctClass = pct > 0 ? "text-primary" : "text-muted";

  return (
    <div style={{
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      position: "relative",
      width: 165,
      height: 165,
      flexShrink: 0,
    }}>
      <svg width="100%" height="100%" viewBox="0 0 100 100" style={{ transform: "rotate(-90deg)" }}>
        {/* Círculo base gris */}
        <circle
          cx="50"
          cy="50"
          r={R}
          fill="transparent"
          stroke="var(--bg-deep)"
          strokeWidth="14"
        />
        {pct > 0 ? (
          <>
            {/* Segmento 6: Libre (Gris) */}
            <circle
              cx="50"
              cy="50"
              r={R}
              fill="transparent"
              stroke="#475569"
              strokeWidth="14"
              strokeDasharray={`${filledFree} ${circ - filledFree}`}
              strokeDashoffset={-(filledBoot + filledOS + filledPanel + filledServices + filledMusic)}
              strokeLinecap="butt"
              style={{ transition: "all 0.4s ease-out" }}
            />
            {/* Segmento 5: Música (Verde) */}
            <circle
              cx="50"
              cy="50"
              r={R}
              fill="transparent"
              stroke="#10b981"
              strokeWidth="14"
              strokeDasharray={`${filledMusic} ${circ - filledMusic}`}
              strokeDashoffset={-(filledBoot + filledOS + filledPanel + filledServices)}
              strokeLinecap="butt"
              style={{ transition: "all 0.4s ease-out" }}
            />
            {/* Segmento 4: Servicios (Púrpura) */}
            <circle
              cx="50"
              cy="50"
              r={R}
              fill="transparent"
              stroke="#a855f7"
              strokeWidth="14"
              strokeDasharray={`${filledServices} ${circ - filledServices}`}
              strokeDashoffset={-(filledBoot + filledOS + filledPanel)}
              strokeLinecap="butt"
              style={{ transition: "all 0.4s ease-out" }}
            />
            {/* Segmento 3: Panel (Naranja) */}
            <circle
              cx="50"
              cy="50"
              r={R}
              fill="transparent"
              stroke="#f97316"
              strokeWidth="14"
              strokeDasharray={`${filledPanel} ${circ - filledPanel}`}
              strokeDashoffset={-(filledBoot + filledOS)}
              strokeLinecap="butt"
              style={{ transition: "all 0.4s ease-out" }}
            />
            {/* Segmento 2: OS Base (Magenta) */}
            <circle
              cx="50"
              cy="50"
              r={R}
              fill="transparent"
              stroke="var(--accent)"
              strokeWidth="14"
              strokeDasharray={`${filledOS} ${circ - filledOS}`}
              strokeDashoffset={-filledBoot}
              strokeLinecap="butt"
              style={{ transition: "all 0.4s ease-out" }}
            />
            {/* Segmento 1: Boot (Cian) */}
            <circle
              cx="50"
              cy="50"
              r={R}
              fill="transparent"
              stroke="var(--info)"
              strokeWidth="14"
              strokeDasharray={`${filledBoot} ${circ - filledBoot}`}
              strokeDashoffset={0}
              strokeLinecap="butt"
              style={{ transition: "all 0.4s ease-out" }}
            />
          </>
        ) : (
          /* Si no hay datos, mostramos un círculo vacío */
          <circle
            cx="50"
            cy="50"
            r={R}
            fill="transparent"
            stroke="var(--text-muted)"
            strokeWidth="3"
            opacity="0.2"
          />
        )}
      </svg>

      <div style={{
        position: "absolute",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
      }}>
        <span className={pctClass} style={{ fontSize: 28, fontWeight: 800 }}>{pct}%</span>
        <span style={{ fontSize: 11, color: "var(--text-muted)", fontWeight: 600, textTransform: "uppercase" }}>{sublabel}</span>
      </div>
    </div>
  );
}

export default function CenterPanel({
  image, device, rpiModel, progress, logs, isFlashing, isDone, canFlash, onFlash, onCancel, onReset,
  activeTab, setActiveTab,
  sshEnabled, setSshEnabled,
  username, setUsername,
  password, setPassword,
  hostname, setHostname,
  wifiSsid, setWifiSsid,
  wifiPassword, setWifiPassword
}: Props) {

  const consoleRef = useRef<HTMLDivElement | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [hardwareSize, setHardwareSize] = useState(0);

  useEffect(() => {
    invoke("get_hardware_size")
      .then((size: any) => {
        if (typeof size === "number") {
          setHardwareSize(size);
        }
      })
      .catch((err) => {
        console.error("Error al obtener tamaño de sigil-hardware:", err);
      });
  }, []);

  const totalWriteSize = useMemo(() => {
    if (!image) return 0;
    // image.size + hardwareSize real + 1.2 GB de almacenamiento de música
    const musicBytes = 1200 * 1024 * 1024;
    return image.size + hardwareSize + musicBytes;
  }, [image, hardwareSize]);

  useEffect(() => {
    if (consoleRef.current) {
      consoleRef.current.scrollTop = consoleRef.current.scrollHeight;
    }
  }, [logs]);

  useEffect(() => {
    let timer: any;
    if (isFlashing) {
      setElapsed(0);
      const startTime = Date.now();
      timer = setInterval(() => {
        setElapsed(Math.round((Date.now() - startTime) / 1000));
      }, 1000);
    }
    return () => clearInterval(timer);
  }, [isFlashing]);

  const spec = useMemo(() => MODEL_SPECS[rpiModel], [rpiModel]);

  const progressPct = useMemo(() => {
    if (!progress || progress.total_bytes === 0) return 0;
    return Math.min(100, Math.round((progress.bytes_written / progress.total_bytes) * 100));
  }, [progress]);

  // Calculate device size in bytes for Donut Gauge
  const usagePct = useMemo(() => {
    if (!image || !device) return 0;
    const sizeStr = device.size.trim();
    const match = sizeStr.match(/^([\d.]+)\s*([KMGTP]?)/i);
    if (!match) return 0;
    const val = parseFloat(match[1]);
    const unit = match[2].toUpperCase();
    const multipliers: Record<string, number> = {
      '': 1, K: 1024, M: 1024**2, G: 1024**3, T: 1024**4
    };
    const deviceBytes = val * (multipliers[unit] ?? 1);
    if (deviceBytes === 0) return 0;
    return Math.min(100, Math.round((totalWriteSize / deviceBytes) * 100));
  }, [image, device, totalWriteSize]);

  // Parse total device bytes
  const deviceBytes = useMemo(() => {
    if (!device) return 0;
    const sizeStr = device.size.trim();
    const match = sizeStr.match(/^([\d.]+)\s*([KMGTP]?)/i);
    if (!match) return 0;
    const val = parseFloat(match[1]);
    const unit = match[2].toUpperCase();
    const multipliers: Record<string, number> = {
      '': 1, K: 1024, M: 1024**2, G: 1024**3, T: 1024**4
    };
    return val * (multipliers[unit] ?? 1);
  }, [device]);

  // Parse unified space distribution percentages matching central usagePct
  const spaceBreakdown = useMemo(() => {
    if (!image || !device || deviceBytes === 0) {
      return { pctBoot: 0, pctOS: 0, pctPanel: 0, pctServices: 0, pctMusic: 0, pctFree: 100 };
    }
    const bootBytes = 512 * 1024 * 1024;
    const effectiveBoot = Math.min(image.size, bootBytes);
    const osBytes = Math.max(0, image.size - effectiveBoot);
    
    // Desglosamos el hardwareSize real obtenido de Rust (40% panel, 60% services)
    const panelBytes = Math.round(hardwareSize * 0.4);
    const servicesBytes = Math.max(0, hardwareSize - panelBytes);
    const musicBytes = 1200 * 1024 * 1024;
    
    const totalUsedBytes = effectiveBoot + osBytes + panelBytes + servicesBytes + musicBytes;

    const rawBoot = (effectiveBoot / totalUsedBytes) * usagePct;
    const rawOS = (osBytes / totalUsedBytes) * usagePct;
    const rawPanel = (panelBytes / totalUsedBytes) * usagePct;
    const rawServices = (servicesBytes / totalUsedBytes) * usagePct;
    const rawMusic = (musicBytes / totalUsedBytes) * usagePct;

    // Garantizar un mínimo visual de 3.5% para segmentos ocupados para que se vean con terminación recta
    const pctBoot = rawBoot > 0 ? Math.max(rawBoot, 3.5) : 0;
    const pctOS = rawOS > 0 ? Math.max(rawOS, 3.5) : 0;
    const pctPanel = rawPanel > 0 ? Math.max(rawPanel, 3.5) : 0;
    const pctServices = rawServices > 0 ? Math.max(rawServices, 3.5) : 0;
    const pctMusic = rawMusic > 0 ? Math.max(rawMusic, 3.5) : 0;

    const totalUsedVisual = pctBoot + pctOS + pctPanel + pctServices + pctMusic;
    const pctFree = Math.max(5, 100 - totalUsedVisual);

    return {
      pctBoot,
      pctOS,
      pctPanel,
      pctServices,
      pctMusic,
      pctFree
    };
  }, [image, device, deviceBytes, usagePct, hardwareSize]);

  // Static list of mock completed flashes
  const mockHistory = [
    { name: "Raspberry Pi OS Lite (64-bit)", device: "/dev/mmcblk0 (16GB)", date: "Hace 2 horas", status: "success" },
    { name: "Ubuntu Server 23.04 (64-bit)", device: "/dev/sdb (32GB)", date: "Ayer", status: "success" },
    { name: "RetroPie Setup Image", device: "/dev/mmcblk0 (64GB)", date: "Hace 3 días", status: "cancelled" }
  ];

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", gap: "12px", padding: "12px 0 0 0" }}>
      
      {/* Top Navigation Tab Bar */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexShrink: 0, padding: "0 12px" }}>
        <div className="tabs-container">
          <button
            className={`tab-button ${activeTab === "vista-previa" ? "active" : ""}`}
            onClick={() => setActiveTab("vista-previa")}
            disabled={isFlashing}
          >
            Vista previa
          </button>
          <button
            className={`tab-button ${activeTab === "ssh" ? "active" : ""}`}
            onClick={() => setActiveTab("ssh")}
            disabled={isFlashing}
          >
            Control SSH
          </button>
          <button
            className={`tab-button ${activeTab === "historial" ? "active" : ""}`}
            onClick={() => setActiveTab("historial")}
            disabled={isFlashing}
          >
            Historial
          </button>
          <button
            className={`tab-button ${activeTab === "motor" ? "active" : ""}`}
            onClick={() => setActiveTab("motor")}
            disabled={isFlashing}
          >
            Motor SIGIL
          </button>
        </div>

        {(isDone || progress?.status === "error" || progress?.status === "cancelled") && (
          <button className="btn btn-secondary" onClick={onReset} style={{ padding: "6px 14px", fontSize: "13px" }}>
            Volver a empezar
          </button>
        )}
      </div>

      {/* Main Tab Content Area */}
      <div style={{ flex: 1, overflowY: "auto", display: "flex", flexDirection: "column", gap: "16px", padding: "8px 12px 16px 12px" }}>
        
        {/* FLASHING SCREEN OVERLAY */}
        {isFlashing ? (
          <div className="card" style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: "32px", gap: "24px", flex: 1 }}>
            <div style={{ position: "relative", width: "120px", height: "120px", display: "flex", alignItems: "center", justifyContent: "center" }}>
              <svg width="100%" height="100%" viewBox="0 0 100 100" style={{ transform: "rotate(-90deg)" }}>
                <circle cx="50" cy="50" r="44" fill="transparent" stroke="var(--bg-deep)" strokeWidth="6" />
                <circle
                  cx="50"
                  cy="50"
                  r="44"
                  fill="transparent"
                  stroke="var(--accent)"
                  strokeWidth="6"
                  strokeDasharray={`${2 * Math.PI * 44}`}
                  strokeDashoffset={`${2 * Math.PI * 44 * (1 - progressPct / 100)}`}
                  strokeLinecap="round"
                  style={{ transition: "stroke-dashoffset 0.3s ease" }}
                />
              </svg>
              <div style={{ position: "absolute", display: "flex", flexDirection: "column", alignItems: "center" }}>
                <span style={{ fontSize: "24px", fontWeight: 800, color: "var(--text-primary)" }}>{progressPct}%</span>
                <span style={{ fontSize: "10px", fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase" }}>progreso</span>
              </div>
            </div>

            <div style={{ textAlign: "center" }}>
              <h3 style={{ fontSize: "18px", fontWeight: 700, color: "var(--text-primary)" }}>
                Escribiendo imagen en la tarjeta microSD...
              </h3>
              <p style={{ fontSize: "14px", color: "var(--text-muted)", marginTop: "4px" }}>
                Por favor, no desconectes el lector de tarjetas.
              </p>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "repeat(4, minmax(0, 1fr))", gap: "16px", width: "100%", maxWidth: "580px" }}>
              <div className="card" style={{ padding: "14px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)", gap: "4px", minWidth: 0 }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700, whiteSpace: "nowrap" }}>VELOCIDAD</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--accent)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {progress?.speed_mbps.toFixed(1) || "0.0"} MB/s
                </span>
              </div>
              <div className="card" style={{ padding: "14px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)", gap: "4px", minWidth: 0 }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700, whiteSpace: "nowrap" }}>TIEMPO RESTANTE</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--text-primary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {progress ? formatETA(progress.eta_seconds) : "calculando..."}
                </span>
              </div>
              <div className="card" style={{ padding: "14px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)", gap: "4px", minWidth: 0 }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700, whiteSpace: "nowrap" }}>TRANSCURRIDO</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--text-primary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {formatETA(elapsed)}
                </span>
              </div>
              <div className="card" style={{ padding: "14px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)", gap: "4px", minWidth: 0 }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700, whiteSpace: "nowrap" }}>ESCRITO</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--text-primary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {progress ? formatSize(progress.bytes_written) : "0 B"}
                </span>
              </div>
            </div>

            <button className="btn btn-secondary" onClick={onCancel} style={{ marginTop: "8px", borderColor: "var(--danger)", color: "var(--danger)" }}>
              ⛔ Cancelar escritura
            </button>
          </div>
        ) : isDone ? (
          <div className="card" style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: "32px", gap: "20px", flex: 1 }}>
            <div style={{
              width: "64px", height: "64px", borderRadius: "50%",
              background: "var(--success-bg)", display: "flex", alignItems: "center", justifyContent: "center",
              fontSize: "32px", boxShadow: "0 0 16px var(--success-shadow)"
            }}>
              ✓
            </div>
            <div style={{ textAlign: "center" }}>
              <h3 style={{ fontSize: "18px", fontWeight: 800, color: "var(--text-primary)" }}>
                ¡Escritura completada con éxito!
              </h3>
              <p style={{ fontSize: "12px", color: "var(--text-muted)", marginTop: "6px", maxWidth: "340px" }}>
                Proceso finalizado con éxito en <strong>{formatETA(elapsed)}</strong>. Ya puedes retirar la tarjeta microSD de forma segura e insertarla en tu Raspberry Pi para encenderla.
              </p>
            </div>
            <button className="btn btn-primary" onClick={onReset} style={{ padding: "10px 24px" }}>
              Grabar otra imagen
            </button>
          </div>
        ) : activeTab === "vista-previa" ? (
          /* TAB 1: VISTA PREVIA — two-column layout matching mockup */
          <div style={{
            display: "flex",
            flexDirection: "row",
            gap: "16px",
            flex: 1,
            minHeight: 0,
          }}>

            {/* ─── LEFT COLUMN (~55%): board card + microSD card ─── */}
            <div style={{
              display: "flex",
              flexDirection: "column",
              gap: "16px",
              flex: "0 0 58%",
              maxWidth: "58%",
            }}>

              {/* Card 1: RPi illustration + model name + specs */}
              <div className="card" style={{
                display: "flex",
                flexDirection: "row",
                alignItems: "stretch",
                gap: "24px",
                padding: "20px",
                flex: "0 0 auto",
              }}>
                {/* Board image with inset background */}
                <div style={{
                  background: "var(--bg-deep)",
                  boxShadow: "var(--shadow-inset)",
                  borderRadius: "var(--radius-lg)",
                  padding: "16px",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  flex: "1 1 50%",
                  height: "240px",
                  overflow: "hidden",
                }}>
                  <BoardSVG model={rpiModel} />
                </div>

                {/* Right of image: name + specs */}
                <div style={{ display: "flex", flexDirection: "column", gap: "10px", flex: "1 1 50%", minWidth: 0, justifyContent: "center" }}>
                  <h2 style={{
                    fontSize: "22px",
                    fontWeight: 800,
                    color: "var(--text-primary)",
                    margin: 0,
                    lineHeight: 1.1,
                  }}>
                    {rpiModel}
                  </h2>

                  <div style={{ display: "flex", flexDirection: "column", gap: "7px", marginTop: "2px" }}>
                    <div style={{ fontSize: "13px", color: "var(--text-muted)", lineHeight: 1.5 }}>
                      <span style={{ fontWeight: 600, color: "var(--text-secondary)" }}>CPU: </span>
                      {spec.cpu}
                    </div>
                    <div style={{ fontSize: "13px", color: "var(--text-muted)", lineHeight: 1.5 }}>
                      <span style={{ fontWeight: 600, color: "var(--text-secondary)" }}>RAM: </span>
                      {spec.ram}
                    </div>
                    <div style={{ fontSize: "13px", color: "var(--text-muted)", lineHeight: 1.5 }}>
                      <span style={{ fontWeight: 600, color: "var(--text-secondary)" }}>Arq.: </span>
                      {spec.arch}
                    </div>
                    <div style={{ fontSize: "13px", color: "var(--text-muted)", lineHeight: 1.5 }}>
                      <span style={{ fontWeight: 600, color: "var(--text-secondary)" }}>Puertos: </span>
                      {spec.ports}
                    </div>
                  </div>
                </div>
              </div>

              {/* Card 2: microSD usage gauge + compatibility */}
              <div className="card" style={{
                display: "flex",
                alignItems: "center",
                gap: "24px",
                padding: "20px",
                flex: 1,
              }}>
                <DonutGauge 
                  pct={usagePct} 
                  sublabel={usagePct === 0 ? "SD" : "usado"} 
                  pctBoot={spaceBreakdown.pctBoot}
                  pctOS={spaceBreakdown.pctOS}
                  pctPanel={spaceBreakdown.pctPanel}
                  pctServices={spaceBreakdown.pctServices}
                  pctMusic={spaceBreakdown.pctMusic}
                  pctFree={spaceBreakdown.pctFree}
                />

                <div style={{ display: "flex", flexDirection: "column", gap: "8px", flex: 1, minWidth: 0 }}>
                  <div style={{ display: "flex", gap: "8px", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600, minWidth: "115px", flexShrink: 0 }}>microSD:</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                      {device ? `${device.size} — ${device.name}` : "No seleccionada"}
                    </span>
                  </div>
                  <div style={{ display: "flex", gap: "8px", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600, minWidth: "115px", flexShrink: 0 }}>Imagen:</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                      {image ? `${image.name} (${formatSize(image.size)})` : "No seleccionada"}
                    </span>
                  </div>
                  <div style={{ display: "flex", gap: "8px", fontSize: "13px", alignItems: "center", paddingTop: "6px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600, minWidth: "115px", flexShrink: 0 }}>Compatibilidad:</span>
                    <span style={{
                      fontSize: "12px",
                      fontWeight: 800,
                      textTransform: "uppercase",
                      color: image && device
                        ? (image.size < deviceBytes * 0.98 ? "var(--success)" : "var(--danger)")
                        : "var(--text-muted)",
                    }}>
                      {image && device
                        ? (image.size < deviceBytes * 0.98 ? "✓ Compatible" : "✗ Insuficiente")
                        : "—"}
                    </span>
                  </div>

                  {image && device && deviceBytes > 0 && (
                    <div style={{ display: "flex", flexDirection: "column", gap: "6px", marginTop: "8px", borderTop: "1px dashed var(--border-dark)", paddingTop: "8px" }}>
                      <span style={{ fontSize: "11px", fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: "0.02em" }}>Distribución de espacio estimada</span>
                      
                      <div style={{ display: "flex", height: "8px", borderRadius: "4px", overflow: "hidden", background: "var(--bg-deep)", boxShadow: "var(--shadow-inset-sm)" }}>
                        <div style={{ width: `${spaceBreakdown.pctBoot}%`, background: "var(--info)" }} title="Partición Boot" />
                        <div style={{ width: `${spaceBreakdown.pctOS}%`, background: "var(--accent)" }} title="Sistema Raíz (OS Base)" />
                        <div style={{ width: `${spaceBreakdown.pctPanel}%`, background: "#f97316" }} title="Streamer Web Panel" />
                        <div style={{ width: `${spaceBreakdown.pctServices}%`, background: "#a855f7" }} title="Servicios y Daemons" />
                        <div style={{ width: `${spaceBreakdown.pctMusic}%`, background: "#10b981" }} title="Música / Datos" />
                        <div style={{ flex: 1, background: "#475569" }} title="Espacio Libre (Usuario)" />
                      </div>

                      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "6px 8px", fontSize: "10px", marginTop: "2px" }}>
                        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                          <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "var(--info)", display: "inline-block", flexShrink: 0 }}></span>
                          <span style={{ color: "var(--text-secondary)", whiteSpace: "nowrap" }}>Boot: 512 MB</span>
                        </div>
                        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                          <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "var(--accent)", display: "inline-block", flexShrink: 0 }}></span>
                          <span style={{ color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>OS Base: {formatSize(Math.max(0, image.size - 512 * 1024 * 1024))}</span>
                        </div>
                        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                          <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "#f97316", display: "inline-block", flexShrink: 0 }}></span>
                          <span style={{ color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>Web Panel: {formatSize(Math.round(hardwareSize * 0.4))}</span>
                        </div>
                        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                          <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "#a855f7", display: "inline-block", flexShrink: 0 }}></span>
                          <span style={{ color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>Daemons: {formatSize(Math.max(0, hardwareSize - Math.round(hardwareSize * 0.4)))}</span>
                        </div>
                        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                          <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "#10b981", display: "inline-block", flexShrink: 0 }}></span>
                          <span style={{ color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>Música: 1.2 GB</span>
                        </div>
                        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                          <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "#475569", display: "inline-block", flexShrink: 0 }}></span>
                          <span style={{ color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>Libre: {formatSize(Math.max(0, deviceBytes - totalWriteSize))}</span>
                        </div>
                      </div>
                    </div>
                  )}
                </div>
              </div>

            </div>

            {/* ─── RIGHT COLUMN (~45%): summary card + flash button ─── */}
            <div style={{
              display: "flex",
              flexDirection: "column",
              gap: "16px",
              flex: "0 0 42%",
              maxWidth: "42%",
              minWidth: 0,
            }}>

              {/* Card: full installation summary */}
              <div className="card" style={{
                display: "flex",
                flexDirection: "column",
                gap: "12px",
                padding: "20px",
                flex: 1,
              }}>
                <span style={{
                  fontSize: "10px",
                  fontWeight: 700,
                  color: "var(--text-muted)",
                  textTransform: "uppercase",
                  letterSpacing: "0.1em",
                }}>
                  Resumen de instalación
                </span>

                <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
                  {/* Device */}
                  <div style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
                    <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 600 }}>Dispositivo destino</span>
                    <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>
                      {rpiModel}
                    </span>
                  </div>
                  {/* Image */}
                  <div style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
                    <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 600 }}>Imagen a instalar</span>
                    <span style={{ fontSize: "13px", fontWeight: 700, color: "var(--text-primary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                      {image ? image.name : <span style={{ color: "var(--text-muted)", fontStyle: "italic" }}>Sin imagen</span>}
                    </span>
                  </div>
                  {/* Separator */}
                  <div style={{ borderTop: "1px dashed var(--shadow-dark)" }} />
                  {/* User */}
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Usuario</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700 }}>{username}</span>
                  </div>
                  {/* Hostname */}
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Hostname</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700 }}>{hostname}.local</span>
                  </div>
                  {/* SSH */}
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", alignItems: "center" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>SSH al iniciar</span>
                    <span style={{
                      fontSize: "11px", fontWeight: 800, padding: "2px 8px",
                      borderRadius: "var(--radius-full)",
                      background: sshEnabled ? "var(--success-bg)" : "var(--bg-deep)",
                      color: sshEnabled ? "var(--success)" : "var(--text-muted)",
                    }}>
                      {sshEnabled ? "HABILITADO" : "DESHABILITADO"}
                    </span>
                  </div>
                  {/* WiFi */}
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Red Wi-Fi</span>
                    <span style={{ color: wifiSsid ? "var(--text-primary)" : "var(--text-muted)", fontWeight: 700 }}>
                      {wifiSsid || "No configurada"}
                    </span>
                  </div>
                  {/* Arch / Kernel */}
                  <div style={{ borderTop: "1px dashed var(--shadow-dark)" }} />
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Arquitectura</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700 }}>{spec.arch}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", gap: "10px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600, flexShrink: 0 }}>Configuración SD</span>
                    <span style={{ color: "var(--accent)", fontWeight: 700, textAlign: "right", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{spec.firmware}</span>
                  </div>
                </div>
              </div>

              {/* Flash button — wide green pill (themed via .btn-flash) */}
              <button
                type="button"
                disabled={!canFlash || isFlashing}
                onClick={onFlash}
                className="btn-flash"
                title={canFlash ? "Escribir imagen a la tarjeta SD" : "Selecciona una imagen y un dispositivo"}
              >
                ⚡ Iniciar Escritura
              </button>

            </div>

          </div>
        ) : activeTab === "ssh" ? (
          /* TAB 2: SSH CONTROL */
          <div className="card" style={{ padding: "16px", display: "flex", flexDirection: "column", gap: "16px" }}>
            <div style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
              <h3 style={{ fontSize: "16px", fontWeight: 700, color: "var(--text-primary)" }}>Personalización del Sistema Operativo</h3>
              <p style={{ fontSize: "13px", color: "var(--text-muted)" }}>Estos parámetros se escribirán automáticamente en los archivos de configuración de la SD.</p>
            </div>

            <div style={{ borderBottom: "1px dashed var(--shadow-dark)", paddingBottom: "14px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <span style={{ fontSize: "14px", fontWeight: 600, color: "var(--text-primary)" }}>Habilitar SSH automáticamente al iniciar</span>
              <label className="neu-switch">
                <input
                  type="checkbox"
                  checked={sshEnabled}
                  onChange={(e) => setSshEnabled(e.target.checked)}
                />
                <span className="neu-switch-slider"></span>
              </label>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "14px" }}>
              <div className="form-group">
                <label className="form-label">Usuario principal</label>
                <input
                  type="text"
                  className="form-input"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  placeholder="Introduce el nombre de usuario"
                />
              </div>
              <div className="form-group">
                <label className="form-label">Contraseña de usuario</label>
                <input
                  type="password"
                  className="form-input"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Introduce la contraseña del usuario"
                />
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">Hostname de red</label>
              <input
                type="text"
                className="form-input"
                value={hostname}
                onChange={(e) => setHostname(e.target.value)}
                placeholder="Introduce el nombre del dispositivo"
              />
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: "2px", marginTop: "4px" }}>
              <h4 style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>Configuración de Red Inalámbrica (Opcional)</h4>
              <p style={{ fontSize: "12px", color: "var(--text-muted)" }}>Permite que el dispositivo se conecte a internet automáticamente.</p>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "14px" }}>
              <div className="form-group">
                <label className="form-label">SSID de Red Wifi</label>
                <input
                  type="text"
                  className="form-input"
                  value={wifiSsid}
                  onChange={(e) => setWifiSsid(e.target.value)}
                  placeholder="Introduce el nombre de la red Wi-Fi (SSID)"
                />
              </div>
              <div className="form-group">
                <label className="form-label">Contraseña Wifi</label>
                <input
                  type="password"
                  className="form-input"
                  value={wifiPassword}
                  onChange={(e) => setWifiPassword(e.target.value)}
                  placeholder="Introduce la contraseña de la red Wi-Fi"
                />
              </div>
            </div>
          </div>
        ) : activeTab === "historial" ? (
          /* TAB 3: HISTORIAL */
          <div style={{ display: "flex", flexDirection: "column", gap: "12px" }}>
            <span style={{ fontSize: "12px", fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: "0.05em" }}>
              Historial de Flasheos
            </span>
            <div className="history-list">
              {mockHistory.map((item, i) => (
                <div key={i} className="history-item">
                  <div style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
                    <span style={{ fontSize: "14px", fontWeight: 700, color: "var(--text-primary)" }}>{item.name}</span>
                    <span style={{ fontSize: "12px", color: "var(--text-muted)" }}>Destino: {item.device}</span>
                  </div>
                  <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: "4px" }}>
                    <span style={{
                      fontSize: "10px", fontWeight: 800, padding: "2px 6px", borderRadius: "var(--radius-full)",
                      background: item.status === "success" ? "var(--success-bg)" : "var(--danger-bg)",
                      color: item.status === "success" ? "var(--success)" : "var(--danger)"
                    }}>
                      {item.status === "success" ? "COMPLETADO" : "CANCELADO"}
                    </span>
                    <span style={{ fontSize: "11px", color: "var(--text-muted)" }}>{item.date}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ) : activeTab === "motor" ? (
          /* TAB 4: MOTOR SIGIL */
          <div style={{ flex: 1, overflowY: "auto", display: "flex", flexDirection: "column" }}>
            <EnginePanel />
          </div>
        ) : null}

      </div>

      {/* Bottom Panel: Log de sistema (Console Terminal) */}
      <div className="card" style={{
        padding: "16px",
        height: "220px",
        display: "flex",
        flexDirection: "column",
        gap: "6px",
        flexShrink: 0,
        margin: "0 12px 12px 12px"
      }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span style={{ fontSize: "11px", fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Log de sistema
          </span>
          <span className="badge" style={{ fontSize: "11px", padding: "2px 8px", background: "var(--bg-deep)", color: "var(--text-secondary)" }}>
            {logs.length} entradas
          </span>
        </div>
        <div 
          ref={consoleRef}
          style={{
            flex: 1,
            background: "var(--bg-deep)",
            boxShadow: "var(--shadow-inset)",
            borderRadius: "var(--radius-md)",
            padding: "10px",
            fontFamily: "var(--font-mono)",
            fontSize: "12px",
            overflowY: "auto",
            display: "flex",
            flexDirection: "column",
            gap: "4px",
            color: "#34d399",
          }}
        >
          {logs.length === 0 ? (
            <span style={{ color: "var(--text-muted)", fontStyle: "italic" }}>Consola inactiva. Esperando escritura...</span>
          ) : (
            logs.map((log, i) => (
              <div key={i} style={{ display: "flex", gap: "8px", lineHeight: "1.4" }}>
                <span style={{ color: "var(--text-muted)", flexShrink: 0 }}>[{log.time}]</span>
                <span style={{
                  color: log.type === "success" ? "#10b981" :
                         log.type === "error" ? "#ef4444" :
                         log.type === "warning" ? "#f59e0b" :
                                                  "#10b981"
                }}>{log.msg}</span>
              </div>
            ))
          )}
        </div>
      </div>

    </div>
  );
}
