import { useMemo } from "react";
import { ImageInfo, Device, RPiModel, FlashProgress, LogEntry, formatSize } from "../App";

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

  activeTab: "vista-previa" | "ssh" | "historial";
  setActiveTab: (tab: "vista-previa" | "ssh" | "historial") => void;

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

/* Standard board (Pi 5/4/3/2/1) — detailed top-down PCB illustration */
function StandardBoardSVG() {
  return (
    <svg width="200" height="150" viewBox="0 0 200 150" fill="none" xmlns="http://www.w3.org/2000/svg"
      style={{ filter: "drop-shadow(0 8px 20px rgba(0,0,0,0.22))" }}>
      {/* PCB base — deep green */}
      <rect width="200" height="150" rx="10" fill="#1a5c2e" />
      {/* PCB surface sheen */}
      <rect x="2" y="2" width="196" height="146" rx="9" fill="#1e7a3a" />
      {/* Silkscreen grid lines */}
      <line x1="0" y1="50" x2="200" y2="50" stroke="#155229" strokeWidth="0.5" />
      <line x1="0" y1="100" x2="200" y2="100" stroke="#155229" strokeWidth="0.5" />
      <line x1="70" y1="0" x2="70" y2="150" stroke="#155229" strokeWidth="0.5" />
      <line x1="140" y1="0" x2="140" y2="150" stroke="#155229" strokeWidth="0.5" />
      {/* Mounting holes */}
      <circle cx="10" cy="10" r="4" fill="#0f3d1e" stroke="#c0b060" strokeWidth="1" />
      <circle cx="190" cy="10" r="4" fill="#0f3d1e" stroke="#c0b060" strokeWidth="1" />
      <circle cx="10" cy="140" r="4" fill="#0f3d1e" stroke="#c0b060" strokeWidth="1" />
      <circle cx="190" cy="140" r="4" fill="#0f3d1e" stroke="#c0b060" strokeWidth="1" />

      {/* === PORTS — Right edge === */}
      {/* USB-A x2 (stacked) */}
      <rect x="188" y="18" width="14" height="28" rx="2" fill="#2a2f38" stroke="#4a5568" strokeWidth="1" />
      <rect x="190" y="20" width="10" height="11" rx="1" fill="#111" />
      <rect x="190" y="33" width="10" height="11" rx="1" fill="#111" />
      {/* USB-A x2 blue (USB3) */}
      <rect x="188" y="52" width="14" height="28" rx="2" fill="#2a2f38" stroke="#4a5568" strokeWidth="1" />
      <rect x="190" y="54" width="10" height="11" rx="1" fill="#1a3a8f" />
      <rect x="190" y="67" width="10" height="11" rx="1" fill="#1a3a8f" />
      {/* RJ45 Ethernet */}
      <rect x="187" y="86" width="15" height="22" rx="2" fill="#333" stroke="#4a5568" strokeWidth="1" />
      <rect x="189" y="88" width="11" height="18" rx="1" fill="#0a0a0a" />
      <circle cx="193" cy="107" r="1.5" fill="#f59e0b" />
      <circle cx="197" cy="107" r="1.5" fill="#10b981" />
      {/* USB-C Power */}
      <rect x="189" y="115" width="11" height="8" rx="3" fill="#555" stroke="#888" strokeWidth="0.5" />

      {/* === PORTS — Top edge === */}
      {/* micro-HDMI x2 */}
      <rect x="22" y="0" width="14" height="9" rx="2" fill="#111" stroke="#444" strokeWidth="0.5" />
      <rect x="42" y="0" width="14" height="9" rx="2" fill="#111" stroke="#444" strokeWidth="0.5" />
      {/* Camera/Display ribbon connectors */}
      <rect x="62" y="2" width="20" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
      <rect x="88" y="2" width="20" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
      {/* USB-C (top) */}
      <rect x="115" y="1" width="12" height="7" rx="3" fill="#555" stroke="#888" strokeWidth="0.5" />
      {/* microSD slot */}
      <rect x="133" y="0" width="18" height="5" rx="1" fill="#888" stroke="#aaa" strokeWidth="0.5" />
      <rect x="134" y="0.5" width="16" height="3.5" fill="#ccc" opacity="0.4" />

      {/* === PORTS — Bottom edge (GPIO) === */}
      {[...Array(20)].map((_, i) => (
        <rect key={i} x={20 + i * 7} y={143} width="5" height="7" rx="0.5"
          fill={i % 2 === 0 ? "#c0b060" : "#a09050"} />
      ))}
      {[...Array(20)].map((_, i) => (
        <rect key={i + 20} x={20 + i * 7} y={148} width="5" height="7" rx="0.5"
          fill={i % 2 === 0 ? "#a09050" : "#c0b060"} />
      ))}

      {/* === MAIN SoC CHIP === */}
      <rect x="60" y="52" width="48" height="48" rx="4" fill="#0a0f0a" stroke="#2a3a2a" strokeWidth="1.5" />
      <rect x="64" y="56" width="40" height="40" rx="2" fill="#111811" />
      {/* SoC die markings */}
      <text x="84" y="79" fontSize="6" fill="#2a5a2a" fontFamily="monospace" textAnchor="middle">BCM</text>
      <text x="84" y="87" fontSize="5" fill="#1e4a1e" fontFamily="monospace" textAnchor="middle">2712</text>
      {/* Chip pins (left) */}
      {[60,66,72,78,84,90].map((y, i) => <rect key={i} x={55} y={y} width={5} height={3} rx={0.5} fill="#9a8a40" />)}
      {/* Chip pins (right) */}
      {[60,66,72,78,84,90].map((y, i) => <rect key={i+6} x={108} y={y} width={5} height={3} rx={0.5} fill="#9a8a40" />)}
      {/* Chip pins (top) */}
      {[65,72,79,86,93,100].map((x, i) => <rect key={i+12} x={x} y={47} width={3} height={5} rx={0.5} fill="#9a8a40" />)}
      {/* Chip pins (bottom) */}
      {[65,72,79,86,93,100].map((x, i) => <rect key={i+18} x={x} y={100} width={3} height={5} rx={0.5} fill="#9a8a40" />)}

      {/* === RAM chips === */}
      <rect x="20" y="54" width="28" height="16" rx="2" fill="#111" stroke="#333" strokeWidth="1" />
      <rect x="22" y="56" width="24" height="12" rx="1" fill="#0a0f12" />
      <text x="34" y="65" fontSize="5" fill="#334" fontFamily="monospace" textAnchor="middle">LPDDR4X</text>
      <rect x="20" y="76" width="28" height="16" rx="2" fill="#111" stroke="#333" strokeWidth="1" />
      <rect x="22" y="78" width="24" height="12" rx="1" fill="#0a0f12" />

      {/* === PMIC / Power chip === */}
      <rect x="22" y="100" width="22" height="18" rx="2" fill="#1a1010" stroke="#3a2020" strokeWidth="1" />
      <text x="33" y="111" fontSize="5" fill="#5a3030" fontFamily="monospace" textAnchor="middle">PMIC</text>

      {/* === WiFi/BT module === */}
      <rect x="120" y="56" width="36" height="28" rx="3" fill="#1a1a2e" stroke="#2a2a4e" strokeWidth="1" />
      <rect x="122" y="58" width="32" height="24" rx="2" fill="#111122" />
      <rect x="124" y="60" width="28" height="4" rx="1" fill="#1a2a4a" />
      <text x="138" y="76" fontSize="5" fill="#2a4a8a" fontFamily="monospace" textAnchor="middle">WiFi/BT</text>
      {/* WiFi antenna trace */}
      <path d="M156 68 Q164 62 168 68 Q172 74 168 80" stroke="#2a4a8a" strokeWidth="1" fill="none" />
      <path d="M158 68 Q164 64 170 68 Q176 74 170 82" stroke="#1a3a7a" strokeWidth="0.5" fill="none" />

      {/* === Capacitors (SMD) === */}
      {[[120,100],[128,100],[136,100],[120,112],[128,112]].map(([x,y], i) => (
        <rect key={i} x={x} y={y} width={5} height={8} rx={1} fill="#1a3a1a" stroke="#2a5a2a" strokeWidth="0.5" />
      ))}
      {/* Small SMD resistors */}
      {[[50,110],[50,118],[50,126],[50,134]].map(([x,y], i) => (
        <rect key={i} x={x} y={y} width={8} height={4} rx={0.5} fill="#222" stroke="#444" strokeWidth="0.5" />
      ))}

      {/* === Status LEDs === */}
      <circle cx="170" cy="110" r="3" fill="#10b981" opacity="0.9" style={{ filter: "drop-shadow(0 0 4px #10b981)" }} />
      <circle cx="170" cy="120" r="3" fill="#e53e6a" opacity="0.8" />
      <circle cx="170" cy="130" r="3" fill="#f59e0b" opacity="0.7" />

      {/* === GPIO pin labels === */}
      <text x="100" y="142" fontSize="4" fill="#2a6a2a" fontFamily="monospace" textAnchor="middle">GPIO — 40 pin</text>
    </svg>
  );
}

/* Zero/Pico board — compact narrow PCB */
function ZeroBoardSVG() {
  return (
    <svg width="240" height="90" viewBox="0 0 240 90" fill="none" xmlns="http://www.w3.org/2000/svg"
      style={{ filter: "drop-shadow(0 8px 20px rgba(0,0,0,0.22))" }}>
      {/* PCB base */}
      <rect width="240" height="90" rx="8" fill="#1a5c2e" />
      <rect x="2" y="2" width="236" height="86" rx="7" fill="#1e7a3a" />
      {/* Silkscreen lines */}
      <line x1="0" y1="45" x2="240" y2="45" stroke="#155229" strokeWidth="0.4" />
      <line x1="80" y1="0" x2="80" y2="90" stroke="#155229" strokeWidth="0.4" />
      <line x1="160" y1="0" x2="160" y2="90" stroke="#155229" strokeWidth="0.4" />
      {/* Mounting holes */}
      <circle cx="9" cy="9" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="231" cy="9" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="9" cy="81" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="231" cy="81" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />

      {/* GPIO — top edge 40 pins */}
      {[...Array(20)].map((_, i) => (
        <rect key={i} x={18 + i * 10} y={0} width={7} height={5} rx={0.5} fill={i % 2 === 0 ? "#c0b060" : "#a09050"} />
      ))}
      {[...Array(20)].map((_, i) => (
        <rect key={i+20} x={18 + i * 10} y={5} width={7} height={5} rx={0.5} fill={i % 2 === 0 ? "#a09050" : "#c0b060"} />
      ))}

      {/* Main SoC */}
      <rect x="88" y="24" width="38" height="38" rx="3" fill="#0a0f0a" stroke="#2a3a2a" strokeWidth="1.2" />
      <rect x="91" y="27" width="32" height="32" rx="2" fill="#111811" />
      <text x="107" y="45" fontSize="5.5" fill="#2a5a2a" fontFamily="monospace" textAnchor="middle">BCM</text>
      <text x="107" y="52" fontSize="4.5" fill="#1e4a1e" fontFamily="monospace" textAnchor="middle">2710A1</text>
      {/* SoC pins */}
      {[28,34,40,46,52].map((y, i) => <rect key={i} x={83} y={y} width={5} height={2.5} rx={0.5} fill="#9a8a40" />)}
      {[28,34,40,46,52].map((y, i) => <rect key={i+5} x={126} y={y} width={5} height={2.5} rx={0.5} fill="#9a8a40" />)}

      {/* RAM chip */}
      <rect x="136" y="28" width="24" height="16" rx="2" fill="#111" stroke="#2a2a2a" strokeWidth="0.8" />
      <rect x="138" y="30" width="20" height="12" rx="1" fill="#0a0a0a" />
      <text x="148" y="38" fontSize="4.5" fill="#223" fontFamily="monospace" textAnchor="middle">512MB</text>

      {/* WiFi chip (Zero W only) */}
      <rect x="136" y="50" width="24" height="16" rx="2" fill="#1a1a2e" stroke="#2a2a4e" strokeWidth="0.8" />
      <text x="148" y="61" fontSize="4" fill="#2a4a8a" fontFamily="monospace" textAnchor="middle">Wi-Fi</text>

      {/* mini-HDMI */}
      <rect x="166" y="0" width="18" height="8" rx="1.5" fill="#111" stroke="#444" strokeWidth="0.5" />
      <rect x="167.5" y="1" width="15" height="6" rx="1" fill="#0a0a0a" />

      {/* Micro USB OTG */}
      <rect x="190" y="0" width="12" height="7" rx="2.5" fill="#555" stroke="#888" strokeWidth="0.5" />

      {/* Micro USB PWR */}
      <rect x="208" y="0" width="12" height="7" rx="2.5" fill="#555" stroke="#888" strokeWidth="0.5" />

      {/* Camera connector */}
      <rect x="18" y="34" width="26" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
      <rect x="20" y="35" width="22" height="4" fill="#111" opacity="0.8" />

      {/* PMIC */}
      <rect x="18" y="50" width="18" height="14" rx="1.5" fill="#1a1010" stroke="#3a2020" strokeWidth="0.8" />
      <text x="27" y="60" fontSize="4" fill="#5a3030" fontFamily="monospace" textAnchor="middle">PMIC</text>

      {/* Status LED */}
      <circle cx="60" cy="72" r="3" fill="#10b981" opacity="0.9" style={{ filter: "drop-shadow(0 0 4px #10b981)" }} />

      {/* SMD caps */}
      {[[52,38],[52,46],[62,38],[62,46],[72,38],[72,46]].map(([x,y], i) => (
        <rect key={i} x={x} y={y} width={6} height={4} rx={0.5} fill="#1a3a1a" stroke="#2a5a2a" strokeWidth="0.4" />
      ))}

      {/* microSD slot */}
      <rect x="228" y="28" width="12" height="18" rx="1" fill="#888" stroke="#aaa" strokeWidth="0.5" />
      <rect x="229" y="29" width="10" height="16" fill="#ccc" opacity="0.3" />

      {/* Bottom GPIO label */}
      <text x="120" y="88" fontSize="4" fill="#2a6a2a" fontFamily="monospace" textAnchor="middle">GPIO — 40 pin header</text>
    </svg>
  );
}

function formatETA(sec: number): string {
  if (sec <= 0) return "finalizando...";
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}m ${s}s`;
}

function DonutGauge({ pct, sublabel }: { pct: number; sublabel: string }) {
  const R = 45;
  const circ = 2 * Math.PI * R;
  const filled = (pct / 100) * circ;
  const empty = circ - filled;

  const color =
    pct > 90 ? "var(--danger)" :
    pct > 70 ? "var(--warning)" :
               "var(--accent)";

  const glowColor =
    pct > 90 ? "var(--danger-shadow)" :
    pct > 70 ? "rgba(245,158,11,0.3)" :
               "var(--accent-glow)";

  const pctClass = pct > 0 ? "text-primary" : "text-muted";

  return (
    <div style={{
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      position: "relative",
      width: 110,
      height: 110,
      flexShrink: 0,
    }}>
      <svg width="100%" height="100%" viewBox="0 0 100 100" style={{ transform: "rotate(-90deg)" }}>
        <circle
          cx="50"
          cy="50"
          r={R}
          fill="transparent"
          stroke="var(--bg-deep)"
          strokeWidth="8"
          style={{ transition: "stroke var(--transition)" }}
        />
        <circle
          cx="50"
          cy="50"
          r={R}
          fill="transparent"
          stroke={color}
          strokeWidth="8"
          strokeDasharray={`${filled} ${empty}`}
          strokeLinecap="round"
          style={{
            strokeDashoffset: 0,
            transition: "all 0.4s ease-out",
            filter: `drop-shadow(0 0 4px ${glowColor})`,
            opacity: pct > 0 ? 0.35 : 0,
          }}
        />
        <circle
          cx="50"
          cy="50"
          r={R}
          fill="transparent"
          stroke={color}
          strokeWidth="8"
          strokeDasharray={`${filled} ${empty}`}
          strokeLinecap="round"
          style={{
            strokeDashoffset: 0,
            transition: "all 0.4s ease-out",
          }}
        />
      </svg>

      <div style={{
        position: "absolute",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
      }}>
        <span className={pctClass} style={{ fontSize: 18, fontWeight: 800 }}>{pct}%</span>
        <span style={{ fontSize: 9, color: "var(--text-muted)", fontWeight: 600, textTransform: "uppercase" }}>{sublabel}</span>
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

  const spec = useMemo(() => MODEL_SPECS[rpiModel], [rpiModel]);
  const isZero = rpiModel.includes("Zero");

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
    return Math.min(100, Math.round((image.size / deviceBytes) * 100));
  }, [image, device]);

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

            <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "16px", width: "100%", maxWidth: "450px" }}>
              <div className="card" style={{ padding: "10px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)" }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700 }}>VELOCIDAD</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--accent)", marginTop: "2px" }}>
                  {progress?.speed_mbps.toFixed(1) || "0.0"} MB/s
                </span>
              </div>
              <div className="card" style={{ padding: "10px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)" }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700 }}>TIEMPO RESTANTE</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--text-primary)", marginTop: "2px" }}>
                  {progress ? formatETA(progress.eta_seconds) : "calculando..."}
                </span>
              </div>
              <div className="card" style={{ padding: "10px", display: "flex", flexDirection: "column", alignItems: "center", background: "var(--bg-deep)" }}>
                <span style={{ fontSize: "11px", color: "var(--text-muted)", fontWeight: 700 }}>ESCRITO</span>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "var(--text-primary)", marginTop: "2px" }}>
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
                Ya puedes retirar la tarjeta microSD de forma segura e insertarla en tu Raspberry Pi para encenderla.
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
              flex: "0 0 55%",
              maxWidth: "55%",
            }}>

              {/* Card 1: RPi illustration + model name + specs */}
              <div className="card" style={{
                display: "flex",
                flexDirection: "row",
                alignItems: "center",
                gap: "20px",
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
                  flexShrink: 0,
                  width: "200px",
                  height: "180px",
                  overflow: "hidden",
                }}>
                  {isZero ? <ZeroBoardSVG /> : <StandardBoardSVG />}
                </div>

                {/* Right of image: name + specs */}
                <div style={{ display: "flex", flexDirection: "column", gap: "10px", flex: 1, minWidth: 0 }}>
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
                gap: "20px",
                padding: "20px",
                flex: 1,
              }}>
                <DonutGauge pct={usagePct} sublabel={usagePct === 0 ? "SD" : "usado"} />

                <div style={{ display: "flex", flexDirection: "column", gap: "8px", flex: 1 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>microSD:</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700 }}>
                      {device ? `${device.size} — ${device.name}` : "No seleccionada"}
                    </span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Imagen:</span>
                    <span style={{ color: "var(--text-primary)", fontWeight: 700 }}>
                      {image ? `${image.name} (${formatSize(image.size)})` : "No seleccionada"}
                    </span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", alignItems: "center", paddingTop: "6px", borderTop: "1px dashed var(--shadow-dark)" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Compatibilidad:</span>
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
                </div>
              </div>

            </div>

            {/* ─── RIGHT COLUMN (~45%): summary card + flash button ─── */}
            <div style={{
              display: "flex",
              flexDirection: "column",
              gap: "16px",
              flex: 1,
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
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>Configuración SD</span>
                    <span style={{ color: "var(--accent)", fontWeight: 700, textAlign: "right", maxWidth: "160px", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{spec.firmware}</span>
                  </div>
                </div>
              </div>

              {/* Flash button — wide green pill */}
              <button
                disabled={!canFlash}
                onClick={onFlash}
                style={{
                  width: "100%",
                  padding: "18px 24px",
                  fontSize: "16px",
                  fontWeight: 800,
                  letterSpacing: "0.04em",
                  border: "none",
                  borderRadius: "var(--radius-full)",
                  cursor: canFlash ? "pointer" : "not-allowed",
                  opacity: canFlash ? 1 : 0.45,
                  background: "linear-gradient(135deg, var(--flash-light), var(--flash-dark))",
                  color: "white",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: "10px",
                  boxShadow: canFlash
                    ? "0 4px 20px var(--flash-glow), -2px -2px 8px var(--btn-shadow-light)"
                    : "none",
                  transition: "all var(--transition)",
                  flexShrink: 0,
                }}
              >
                ⚡ Iniciar Escritura en microSD
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

            <div style={{ borderBottom: "1px dashed var(--shadow-dark)", paddingBottom: "14px" }}>
              <label className="form-checkbox">
                <input
                  type="checkbox"
                  checked={sshEnabled}
                  onChange={(e) => setSshEnabled(e.target.checked)}
                  style={{ accentColor: "var(--accent)" }}
                />
                <span style={{ fontSize: "14px", fontWeight: 600, color: "var(--text-primary)" }}>Habilitar SSH automáticamente al iniciar</span>
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
                  placeholder="ej. pi"
                />
              </div>
              <div className="form-group">
                <label className="form-label">Contraseña de usuario</label>
                <input
                  type="password"
                  className="form-input"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
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
                placeholder="ej. raspberrypi"
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
                  placeholder="Nombre de red wifi"
                />
              </div>
              <div className="form-group">
                <label className="form-label">Contraseña Wifi</label>
                <input
                  type="password"
                  className="form-input"
                  value={wifiPassword}
                  onChange={(e) => setWifiPassword(e.target.value)}
                  placeholder="••••••••"
                />
              </div>
            </div>
          </div>
        ) : (
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
        )}

      </div>

      {/* Bottom Panel: Log de sistema (Console Terminal) */}
      <div className="card" style={{
        padding: "16px",
        height: "150px",
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
        <div style={{
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
        }}>
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
