import React from 'react';
import { RPiModel } from '../App';

/* ── PCB SVG Defs & Shared Gradients for Neumorphic hardware ── */
const SVGDefs = () => (
  <defs>
    {/* PCB Board surface gradient */}
    <linearGradient id="pcbOuterGrad" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stopColor="#1e5e31" />
      <stop offset="100%" stopColor="#0f3d1e" />
    </linearGradient>
    <linearGradient id="pcbInnerGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stopColor="#24733c" />
      <stop offset="100%" stopColor="#164e27" />
    </linearGradient>
    {/* Brushed metal connectors */}
    <linearGradient id="metalGrad" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stopColor="#64748b" />
      <stop offset="50%" stopColor="#475569" />
      <stop offset="100%" stopColor="#334155" />
    </linearGradient>
    {/* Metallic IC Chip surface */}
    <linearGradient id="chipGrad" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stopColor="#29303b" />
      <stop offset="100%" stopColor="#11161d" />
    </linearGradient>
    {/* Gold contacts */}
    <linearGradient id="goldGrad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stopColor="#f59e0b" />
      <stop offset="100%" stopColor="#d97706" />
    </linearGradient>
    {/* Metallic shield box */}
    <linearGradient id="shieldGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stopColor="#3b4252" />
      <stop offset="100%" stopColor="#1e232a" />
    </linearGradient>
  </defs>
);

const PCB = ({ w=200, h=150, children }: { w?: number; h?: number; children: React.ReactNode }) => (
  <svg width="100%" height="100%" viewBox={`0 0 ${w} ${h}`} fill="none" xmlns="http://www.w3.org/2000/svg"
    style={{ filter: "drop-shadow(0 8px 18px rgba(0,0,0,0.35))" }}>
    <SVGDefs />
    <rect width={w} height={h} rx="12" fill="url(#pcbOuterGrad)" stroke="rgba(255,255,255,0.12)" strokeWidth="1" />
    <rect x="3" y="3" width={w-6} height={h-6} rx="10" fill="url(#pcbInnerGrad)" />
    {/* Subtle silkscreen PCB trace details */}
    <path d={`M 15 25 L 45 25 L 55 35 M 150 40 L 175 40 M 15 110 L 40 110`} stroke="rgba(245,158,11,0.2)" strokeWidth="0.8" strokeDasharray="3 2" fill="none" />
    {children}
  </svg>
);

const Hole = ({ x, y }: { x: number; y: number }) => (
  <g>
    <circle cx={x} cy={y} r="4.5" fill="#0c2d16" stroke="url(#goldGrad)" strokeWidth="1.2" />
    <circle cx={x} cy={y} r="2" fill="#071b0d" />
  </g>
);

const GPIO40 = ({ y, w=200 }: { y: number; w?: number }) => <>
  <rect x="18" y={y-1} width={w-36} height="12" rx="2" fill="#1e293b" opacity="0.6" />
  {[...Array(20)].map((_, i) => <rect key={i}   x={20+i*7} y={y}   width="5" height="5" rx="1" fill={i%2===0?"url(#goldGrad)":"#b45309"} />)}
  {[...Array(20)].map((_, i) => <rect key={i+20} x={20+i*7} y={y+5} width="5" height="5" rx="1" fill={i%2===0?"#b45309":"url(#goldGrad)"} />)}
</>;

const SoC = ({ x, y, s, label }: { x:number; y:number; s:number; label:string }) => <>
  <rect x={x} y={y} width={s} height={s} rx="4" fill="url(#chipGrad)" stroke="#475569" strokeWidth="1" />
  <rect x={x+3} y={y+3} width={s-6} height={s-6} rx="2" fill="#0f172a" />
  <text x={x+s/2} y={y+s/2-2} fontSize="6" fill="#cbd5e1" fontFamily="sans-serif" fontWeight="700" textAnchor="middle">BCM</text>
  <text x={x+s/2} y={y+s/2+7} fontSize="5" fill="#94a3b8" fontFamily="sans-serif" textAnchor="middle">{label}</text>
</>;

const USBA2 = ({ x, y, blue=false }: { x:number; y:number; blue?:boolean }) => <>
  <rect x={x} y={y} width="14" height="28" rx="2" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.8" />
  <rect x={x+2} y={y+2} width="10" height="11" rx="1" fill={blue?"#0284c7":"#0f172a"} />
  <rect x={x+2} y={y+15} width="10" height="11" rx="1" fill={blue?"#0284c7":"#0f172a"} />
</>;

const Eth = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="15" height="22" rx="2" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.8" />
  <rect x={x+2} y={y+2} width="11" height="18" rx="1" fill="#0f172a" />
  <circle cx={x+5} cy={y+21} r="1.2" fill="#f59e0b" style={{ filter: "drop-shadow(0 0 3px #f59e0b)" }} />
  <circle cx={x+10} cy={y+21} r="1.2" fill="#10b981" style={{ filter: "drop-shadow(0 0 3px #10b981)" }} />
</>;

const MicroHDMI = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="13" height="8" rx="2" fill="url(#metalGrad)" stroke="#475569" strokeWidth="0.5" />
  <rect x={x+1.5} y={y+1} width="10" height="6" rx="1" fill="#0f172a" />
  <rect x={x+3.5} y={y+2.5} width="6" height="3" fill="url(#goldGrad)" opacity="0.8" />
</>;

const HDMI = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="18" height="9" rx="2" fill="url(#metalGrad)" stroke="#475569" strokeWidth="0.5" />
  <rect x={x+2} y={y+1.5} width="14" height="6" fill="#0f172a" />
  <rect x={x+5} y={y+3} width="8" height="3" fill="url(#goldGrad)" opacity="0.8" />
</>;

const USB_C = ({ x, y }: { x:number; y:number }) => (
  <g>
    <rect x={x} y={y} width="11" height="7" rx="3" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.5" />
    <rect x={x+2} y={y+2} width="7" height="3" rx="1.5" fill="#0f172a" />
  </g>
);

const MicroUSB = ({ x, y }: { x:number; y:number }) => (
  <g>
    <rect x={x} y={y} width="11" height="7" rx="2.5" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.5" />
    <rect x={x+2} y={y+2} width="7" height="3" rx="1" fill="#0f172a" />
  </g>
);

const WiFiMod = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="34" height="26" rx="3" fill="url(#shieldGrad)" stroke="#475569" strokeWidth="0.8" />
  <rect x={x+2} y={y+2} width="30" height="22" rx="2" fill="#1e293b" opacity="0.8" />
  <text x={x+17} y={y+14} fontSize="5" fill="#38bdf8" fontFamily="sans-serif" fontWeight="600" textAnchor="middle">Wi-Fi / BT</text>
  <path d={`M${x+26} ${y+8} Q${x+31} ${y+4} ${x+35} ${y+8}`} stroke="#38bdf8" strokeWidth="1" fill="none" />
</>;

const SD = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="16" height="5" rx="1" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.5" />
  <rect x={x+2} y={y+1} width="12" height="3" fill="url(#goldGrad)" opacity="0.9" />
</>;

const LED = ({ x, y, color }: { x:number; y:number; color:string }) => (
  <circle cx={x} cy={y} r="3" fill={color} style={{ filter: `drop-shadow(0 0 5px ${color})` }} />
);

const RAM = ({ x, y, label }: { x:number; y:number; label:string }) => <>
  <rect x={x} y={y} width="28" height="16" rx="2" fill="url(#chipGrad)" stroke="#334155" strokeWidth="0.8" />
  <rect x={x+2} y={y+2} width="24" height="12" rx="1" fill="#0f172a" />
  <text x={x+14} y={y+10} fontSize="4.5" fill="#94a3b8" fontFamily="sans-serif" textAnchor="middle">{label}</text>
</>;

/* ── Pi 5 SVG ── */
function Pi5SVG() {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    <MicroHDMI x={18} y={0} /><MicroHDMI x={35} y={0} />
    <rect x={54} y={1} width="18" height="6" rx="1" fill="#1e293b" stroke="#475569" strokeWidth="0.5" />
    <rect x={76} y={1} width="18" height="6" rx="1" fill="#1e293b" stroke="#475569" strokeWidth="0.5" />
    <USB_C x={100} y={1} /><SD x={118} y={0} />
    <USBA2 x={188} y={16} /><USBA2 x={188} y={50} blue />
    <Eth x={187} y={84} /><USB_C x={189} y={112} />
    <GPIO40 y={138} />
    <SoC x={58} y={50} s={52} label="2712" />
    <RAM x={16} y={52} label="LPDDR4X" /><RAM x={16} y={74} label="LPDDR4X" />
    <WiFiMod x={120} y={54} />
    <rect x={120} y={95} width="30" height="10" rx="2" fill="#0f172a" stroke="#0284c7" strokeWidth="0.8" />
    <text x={135} y={102} fontSize="4.5" fill="#38bdf8" fontFamily="sans-serif" textAnchor="middle">PCIe x1</text>
    <LED x={170} y={110} color="#10b981" /><LED x={170} y={120} color="#e53e6a" />
  </PCB>;
}

/* ── Pi 4 SVG ── */
function Pi4SVG() {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    <MicroHDMI x={18} y={0} /><MicroHDMI x={35} y={0} />
    <rect x={55} y={1} width="18" height="6" rx="1" fill="#1e293b" stroke="#475569" strokeWidth="0.5" />
    <USB_C x={78} y={1} /><SD x={96} y={0} />
    <USBA2 x={188} y={16} /><USBA2 x={188} y={50} blue />
    <Eth x={187} y={84} /><USB_C x={189} y={112} />
    <GPIO40 y={138} />
    <SoC x={58} y={52} s={48} label="2711" />
    <RAM x={16} y={54} label="LPDDR4" /><RAM x={16} y={76} label="LPDDR4" />
    <WiFiMod x={118} y={56} />
    <LED x={170} y={110} color="#10b981" /><LED x={170} y={122} color="#e53e6a" />
  </PCB>;
}

/* ── Pi 3 SVG ── */
function Pi3SVG() {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    <HDMI x={14} y={0} />
    <rect x={36} y={1} width="18" height="6" rx="1" fill="#1e293b" stroke="#475569" strokeWidth="0.5" />
    <SD x={58} y={0} />
    <circle cx={0} cy={75} r="5" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.5" />
    <USBA2 x={188} y={14} /><USBA2 x={188} y={48} />
    <Eth x={187} y={82} /><MicroUSB x={189} y={112} />
    <GPIO40 y={138} />
    <SoC x={60} y={54} s={44} label="2837B0" />
    <RAM x={18} y={56} label="1GB" />
    <WiFiMod x={118} y={58} />
    <LED x={170} y={112} color="#10b981" /><LED x={170} y={124} color="#e53e6a" />
  </PCB>;
}

/* ── Pi 2 / Pi 1 SVG ── */
function Pi2SVG({ isPi1 = false }: { isPi1?: boolean }) {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    <HDMI x={14} y={0} />
    <SD x={36} y={0} />
    <circle cx={0} cy={75} r="5" fill="url(#metalGrad)" stroke="#64748b" strokeWidth="0.5" />
    {isPi1 ? <>
      <USBA2 x={188} y={20} />
      <Eth x={187} y={56} />
    </> : <>
      <USBA2 x={188} y={14} /><USBA2 x={188} y={48} />
      <Eth x={187} y={82} />
    </>}
    <MicroUSB x={189} y={isPi1 ? 80 : 112} />
    <GPIO40 y={138} />
    <SoC x={62} y={58} s={42} label={isPi1 ? "2835" : "2836"} />
    <RAM x={18} y={60} label={isPi1 ? "512MB" : "1GB"} />
    <LED x={170} y={112} color="#10b981" />
  </PCB>;
}

/* ── Zero SVG ── */
function ZeroSVG({ hasWifi = false }: { hasWifi?: boolean }) {
  return (
    <svg width="100%" height="100%" viewBox="0 0 240 90" fill="none" xmlns="http://www.w3.org/2000/svg"
      style={{ filter: "drop-shadow(0 8px 18px rgba(0,0,0,0.35))" }}>
      <SVGDefs />
      <rect width="240" height="90" rx="10" fill="url(#pcbOuterGrad)" stroke="rgba(255,255,255,0.12)" strokeWidth="1" />
      <rect x="3" y="3" width="234" height="84" rx="8" fill="url(#pcbInnerGrad)" />
      <Hole x={10} y={10} /><Hole x={230} y={10} /><Hole x={10} y={80} /><Hole x={230} y={80} />
      {[...Array(20)].map((_, i) => <rect key={i}    x={18+i*10} y={0} width="7" height="5" rx="1" fill={i%2===0?"url(#goldGrad)":"#b45309"} />)}
      {[...Array(20)].map((_, i) => <rect key={i+20} x={18+i*10} y={5} width="7" height="5" rx="1" fill={i%2===0?"#b45309":"url(#goldGrad)"} />)}
      <MicroHDMI x={166} y={0} />
      <MicroUSB x={186} y={0} />
      <MicroUSB x={202} y={0} />
      <rect x="18" y="34" width="26" height="6" rx="1" fill="#1e293b" stroke="#475569" strokeWidth="0.5" />
      <SoC x={90} y={24} s={38} label={hasWifi ? "2710A1" : "2835"} />
      <RAM x={136} y={28} label="512MB" />
      {hasWifi && <WiFiMod x={136} y={48} />}
      <SD x={226} y={28} />
      <LED x={60} y={72} color="#10b981" />
    </svg>
  );
}

/* ── Pico SVG ── */
function PicoSVG({ hasWifi = false, isV2 = false }: { hasWifi?: boolean; isV2?: boolean }) {
  return (
    <svg width="100%" height="100%" viewBox="0 0 260 70" fill="none" xmlns="http://www.w3.org/2000/svg"
      style={{ filter: "drop-shadow(0 8px 18px rgba(0,0,0,0.35))" }}>
      <SVGDefs />
      <rect width="260" height="70" rx="8" fill="url(#pcbOuterGrad)" stroke="rgba(255,255,255,0.12)" strokeWidth="1" />
      <rect x="3" y="3" width="254" height="64" rx="6" fill="url(#pcbInnerGrad)" />
      <Hole x={9} y={9} /><Hole x={251} y={9} /><Hole x={9} y={61} /><Hole x={251} y={61} />
      {[...Array(20)].map((_, i) => <rect key={i}    x={16+i*11} y={0} width="8" height="5" rx="1" fill="url(#goldGrad)" />)}
      {[...Array(20)].map((_, i) => <rect key={i+20} x={16+i*11} y={65} width="8" height="5" rx="1" fill="#b45309" />)}
      <MicroUSB x={0} y={28} />
      <SoC x={96} y={14} s={42} label={isV2 ? "RP2350" : "RP2040"} />
      <RAM x={152} y={22} label={isV2 ? "4MB" : "2MB"} />
      {hasWifi && <WiFiMod x={60} y={18} />}
      <LED x={242} y={18} color="#10b981" />
    </svg>
  );
}

export function BoardSVG({ model, className }: { model: RPiModel; className?: string }) {
  if (model.includes("Pico 2 W") || model.includes("Pico 2"))
    return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><PicoSVG hasWifi={model.includes("W")} isV2 /></div>;
  if (model.includes("Pico"))
    return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><PicoSVG hasWifi={model.includes("W")} /></div>;
  if (model.includes("Zero"))
    return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><ZeroSVG hasWifi={model.includes("W")} /></div>;
  if (model.includes("Pi 5"))  return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><Pi5SVG /></div>;
  if (model.includes("Pi 4"))  return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><Pi4SVG /></div>;
  if (model.includes("Pi 3"))  return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><Pi3SVG /></div>;
  if (model === "Raspberry Pi 1") return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><Pi2SVG isPi1 /></div>;
  return <div className={className} style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}><Pi2SVG /></div>;
}
