import React from 'react';
import { RPiModel } from '../App';

/* ── PCB helpers ── */
const PCB = ({ w=200, h=150, children }: { w?: number; h?: number; children: React.ReactNode }) => (
  <svg width="100%" height="100%" viewBox={`0 0 ${w} ${h}`} fill="none" xmlns="http://www.w3.org/2000/svg"
    style={{ filter: "drop-shadow(0 4px 10px rgba(0,0,0,0.25))" }}>
    <rect width={w} height={h} rx="10" fill="#1a5c2e" />
    <rect x="2" y="2" width={w-4} height={h-4} rx="9" fill="#1e7a3a" />
    {children}
  </svg>
);
const Hole = ({ x, y }: { x: number; y: number }) => (
  <circle cx={x} cy={y} r="4" fill="#0f3d1e" stroke="#c0b060" strokeWidth="1" />
);
const GPIO40 = ({ y, w=200 }: { y: number; w?: number }) => <>
  {[...Array(20)].map((_, i) => <rect key={i}   x={20+i*7} y={y}   width="5" height="5" rx="0.5" fill={i%2===0?"#c0b060":"#a09050"} />)}
  {[...Array(20)].map((_, i) => <rect key={i+20} x={20+i*7} y={y+5} width="5" height="5" rx="0.5" fill={i%2===0?"#a09050":"#c0b060"} />)}
  <text x={w/2} y={y+15} fontSize="4" fill="#2a6a2a" fontFamily="monospace" textAnchor="middle">GPIO — 40 pin</text>
</>;
const SoC = ({ x, y, s, label }: { x:number; y:number; s:number; label:string }) => <>
  <rect x={x} y={y} width={s} height={s} rx="4" fill="#0a0f0a" stroke="#2a3a2a" strokeWidth="1.5" />
  <rect x={x+4} y={y+4} width={s-8} height={s-8} rx="2" fill="#111811" />
  <text x={x+s/2} y={y+s/2-2} fontSize="6" fill="#2a5a2a" fontFamily="monospace" textAnchor="middle">BCM</text>
  <text x={x+s/2} y={y+s/2+7} fontSize="5" fill="#1e4a1e" fontFamily="monospace" textAnchor="middle">{label}</text>
</>;
const USBA2 = ({ x, y, blue=false }: { x:number; y:number; blue?:boolean }) => <>
  <rect x={x} y={y} width="14" height="28" rx="2" fill="#2a2f38" stroke="#4a5568" strokeWidth="1" />
  <rect x={x+2} y={y+2} width="10" height="11" rx="1" fill={blue?"#1a3a8f":"#111"} />
  <rect x={x+2} y={y+15} width="10" height="11" rx="1" fill={blue?"#1a3a8f":"#111"} />
</>;
const Eth = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="15" height="22" rx="2" fill="#333" stroke="#4a5568" strokeWidth="1" />
  <rect x={x+2} y={y+2} width="11" height="18" rx="1" fill="#0a0a0a" />
  <circle cx={x+5} cy={y+21} r="1.5" fill="#f59e0b" />
  <circle cx={x+10} cy={y+21} r="1.5" fill="#10b981" />
</>;
const MicroHDMI = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="13" height="8" rx="2" fill="#111" stroke="#444" strokeWidth="0.5" />
  <rect x={x+1.5} y={y+1} width="10" height="6" rx="1" fill="#0a0a0a" />
</>;
const HDMI = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="18" height="9" rx="2" fill="#111" stroke="#555" strokeWidth="0.5" />
  <rect x={x+2} y={y+1.5} width="14" height="6" fill="#0a0a0a" />
</>;
const USB_C = ({ x, y }: { x:number; y:number }) => (
  <rect x={x} y={y} width="11" height="7" rx="3" fill="#555" stroke="#888" strokeWidth="0.5" />
);
const MicroUSB = ({ x, y }: { x:number; y:number }) => (
  <rect x={x} y={y} width="11" height="7" rx="2.5" fill="#555" stroke="#888" strokeWidth="0.5" />
);
const WiFiMod = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="34" height="26" rx="3" fill="#1a1a2e" stroke="#2a2a4e" strokeWidth="1" />
  <rect x={x+2} y={y+2} width="30" height="22" rx="2" fill="#111122" />
  <text x={x+17} y={y+14} fontSize="5" fill="#2a4a8a" fontFamily="monospace" textAnchor="middle">WiFi/BT</text>
  <path d={`M${x+28} ${y+8} Q${x+34} ${y+4} ${x+38} ${y+8}`} stroke="#2a4a8a" strokeWidth="1" fill="none" />
</>;
const SD = ({ x, y }: { x:number; y:number }) => <>
  <rect x={x} y={y} width="16" height="5" rx="1" fill="#888" stroke="#aaa" strokeWidth="0.5" />
  <rect x={x+1} y={y+0.5} width="14" height="3.5" fill="#ccc" opacity="0.4" />
</>;
const LED = ({ x, y, color }: { x:number; y:number; color:string }) => (
  <circle cx={x} cy={y} r="3" fill={color} opacity="0.9" style={{ filter: `drop-shadow(0 0 4px ${color})` }} />
);
const RAM = ({ x, y, label }: { x:number; y:number; label:string }) => <>
  <rect x={x} y={y} width="28" height="16" rx="2" fill="#111" stroke="#333" strokeWidth="1" />
  <rect x={x+2} y={y+2} width="24" height="12" rx="1" fill="#0a0f12" />
  <text x={x+14} y={y+10} fontSize="4.5" fill="#334" fontFamily="monospace" textAnchor="middle">{label}</text>
</>;

/* ── Pi 5 ── dual micro-HDMI, 2× camera, USB-C pwr, PCIe */
function Pi5SVG() {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    {/* top ports */}
    <MicroHDMI x={18} y={0} /><MicroHDMI x={35} y={0} />
    <rect x={54} y={1} width="18" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
    <rect x={76} y={1} width="18" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
    <USB_C x={100} y={1} /><SD x={118} y={0} />
    {/* right ports */}
    <USBA2 x={188} y={16} /><USBA2 x={188} y={50} blue />
    <Eth x={187} y={84} /><USB_C x={189} y={112} />
    {/* GPIO bottom */}
    <GPIO40 y={138} />
    {/* chips */}
    <SoC x={58} y={50} s={52} label="2712" />
    <RAM x={16} y={52} label="LPDDR4X" /><RAM x={16} y={74} label="LPDDR4X" />
    <WiFiMod x={120} y={54} />
    <rect x={120} y={95} width="30" height="10" rx="2" fill="#1a2a0a" stroke="#3a5a1a" strokeWidth="0.8" />
    <text x={135} y={102} fontSize="4.5" fill="#3a6a1a" fontFamily="monospace" textAnchor="middle">PCIe x1</text>
    <LED x={170} y={110} color="#10b981" /><LED x={170} y={120} color="#e53e6a" />
  </PCB>;
}

/* ── Pi 4 ── dual micro-HDMI, USB-C pwr, USB3 blue */
function Pi4SVG() {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    <MicroHDMI x={18} y={0} /><MicroHDMI x={35} y={0} />
    <rect x={55} y={1} width="18" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
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

/* ── Pi 3 ── full HDMI, 3.5mm jack, 4× USB-A, WiFi */
function Pi3SVG() {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    {/* top: full HDMI + CSI + microSD */}
    <HDMI x={14} y={0} />
    <rect x={36} y={1} width="18" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
    <SD x={58} y={0} />
    {/* left: 3.5mm audio */}
    <circle cx={0} cy={75} r="5" fill="#555" stroke="#888" strokeWidth="0.5" />
    {/* right: 4× USB-A + Eth + micro-USB pwr */}
    <USBA2 x={188} y={14} /><USBA2 x={188} y={48} />
    <Eth x={187} y={82} /><MicroUSB x={189} y={112} />
    <GPIO40 y={138} />
    <SoC x={60} y={54} s={44} label="2837B0" />
    <RAM x={18} y={56} label="1GB" />
    <WiFiMod x={118} y={58} />
    <LED x={170} y={112} color="#10b981" /><LED x={170} y={124} color="#e53e6a" />
  </PCB>;
}

/* ── Pi 2 / Pi 1 ── full HDMI, 4/2× USB-A, no WiFi */
function Pi2SVG({ isPi1 = false }: { isPi1?: boolean }) {
  return <PCB w={200} h={150}>
    <Hole x={10} y={10} /><Hole x={190} y={10} /><Hole x={10} y={140} /><Hole x={190} y={140} />
    <HDMI x={14} y={0} />
    <SD x={36} y={0} />
    <circle cx={0} cy={75} r="5" fill="#555" stroke="#888" strokeWidth="0.5" />
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

/* ── Zero / Zero W / Zero 2 W ── small landscape board */
function ZeroSVG({ hasWifi = false }: { hasWifi?: boolean }) {
  return (
    <svg width="100%" height="100%" viewBox="0 0 240 90" fill="none" xmlns="http://www.w3.org/2000/svg"
      style={{ filter: "drop-shadow(0 4px 10px rgba(0,0,0,0.25))" }}>
      <rect width="240" height="90" rx="8" fill="#1a5c2e" />
      <rect x="2" y="2" width="236" height="86" rx="7" fill="#1e7a3a" />
      <circle cx="9" cy="9" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="231" cy="9" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="9" cy="81" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="231" cy="81" r="3.5" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      {/* GPIO top */}
      {[...Array(20)].map((_, i) => <rect key={i}    x={18+i*10} y={0} width="7" height="5" rx="0.5" fill={i%2===0?"#c0b060":"#a09050"} />)}
      {[...Array(20)].map((_, i) => <rect key={i+20} x={18+i*10} y={5} width="7" height="5" rx="0.5" fill={i%2===0?"#a09050":"#c0b060"} />)}
      {/* mini-HDMI */}
      <rect x="166" y="0" width="15" height="8" rx="2" fill="#111" stroke="#444" strokeWidth="0.5" />
      <rect x="167.5" y="1" width="12" height="6" rx="1" fill="#0a0a0a" />
      {/* micro-USB OTG + PWR */}
      <rect x="186" y="0" width="11" height="7" rx="2.5" fill="#555" stroke="#888" strokeWidth="0.5" />
      <rect x="202" y="0" width="11" height="7" rx="2.5" fill="#555" stroke="#888" strokeWidth="0.5" />
      {/* Camera FFC */}
      <rect x="18" y="34" width="26" height="6" rx="1" fill="#222" stroke="#555" strokeWidth="0.5" />
      {/* SoC */}
      <rect x="90" y="24" width="38" height="38" rx="3" fill="#0a0f0a" stroke="#2a3a2a" strokeWidth="1.2" />
      <rect x="93" y="27" width="32" height="32" rx="2" fill="#111811" />
      <text x="109" y="45" fontSize="5.5" fill="#2a5a2a" fontFamily="monospace" textAnchor="middle">BCM</text>
      <text x="109" y="53" fontSize="4.5" fill="#1e4a1e" fontFamily="monospace" textAnchor="middle">{hasWifi ? "2710A1" : "2835"}</text>
      {/* RAM */}
      <rect x="136" y="28" width="24" height="14" rx="2" fill="#111" stroke="#2a2a2a" strokeWidth="0.8" />
      <text x="148" y="37" fontSize="4.5" fill="#334" fontFamily="monospace" textAnchor="middle">512MB</text>
      {/* WiFi module */}
      {hasWifi && <>
        <rect x="136" y="48" width="24" height="16" rx="2" fill="#1a1a2e" stroke="#2a2a4e" strokeWidth="0.8" />
        <text x="148" y="59" fontSize="4" fill="#2a4a8a" fontFamily="monospace" textAnchor="middle">Wi-Fi</text>
      </>}
      {/* microSD */}
      <rect x="226" y="28" width="14" height="18" rx="1" fill="#888" stroke="#aaa" strokeWidth="0.5" />
      <LED x={60} y={72} color="#10b981" />
    </svg>
  );
}

/* ── Pico / Pico W / Pico 2 / Pico 2 W ── long narrow MCU */
function PicoSVG({ hasWifi = false, isV2 = false }: { hasWifi?: boolean; isV2?: boolean }) {
  return (
    <svg width="100%" height="100%" viewBox="0 0 260 70" fill="none" xmlns="http://www.w3.org/2000/svg"
      style={{ filter: "drop-shadow(0 4px 10px rgba(0,0,0,0.25))" }}>
      <rect width="260" height="70" rx="6" fill="#1a5c2e" />
      <rect x="2" y="2" width="256" height="66" rx="5" fill="#1e7a3a" />
      {/* mounting holes */}
      <circle cx="8" cy="8" r="3" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="252" cy="8" r="3" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="8" cy="62" r="3" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      <circle cx="252" cy="62" r="3" fill="#0f3d1e" stroke="#c0b060" strokeWidth="0.8" />
      {/* GPIO pins top row */}
      {[...Array(20)].map((_, i) => <rect key={i}    x={16+i*11} y={0} width="8" height="5" rx="0.5" fill="#c0b060" />)}
      {/* GPIO pins bottom row */}
      {[...Array(20)].map((_, i) => <rect key={i+20} x={16+i*11} y={65} width="8" height="5" rx="0.5" fill="#a09050" />)}
      {/* micro-USB at left end */}
      <rect x="0" y="28" width="9" height="14" rx="2.5" fill="#555" stroke="#888" strokeWidth="0.5" />
      {/* main RP chip */}
      <rect x="96" y="14" width="42" height="42" rx="3" fill="#0a0f0a" stroke="#2a3a2a" strokeWidth="1.5" />
      <rect x="100" y="18" width="34" height="34" rx="2" fill="#111811" />
      <text x="117" y="36" fontSize="6" fill="#2a5a2a" fontFamily="monospace" textAnchor="middle">{isV2 ? "RP2350" : "RP2040"}</text>
      <text x="117" y="44" fontSize="5" fill="#1e4a1e" fontFamily="monospace" textAnchor="middle">{isV2 ? "Pico 2" : "Pico"}</text>
      {/* flash chip */}
      <rect x="152" y="22" width="20" height="14" rx="2" fill="#111" stroke="#333" strokeWidth="0.8" />
      <text x="162" y="31" fontSize="4" fill="#334" fontFamily="monospace" textAnchor="middle">{isV2?"4MB":"2MB"}</text>
      {/* WiFi module */}
      {hasWifi && <>
        <rect x="60" y="18" width="26" height="20" rx="2" fill="#1a1a2e" stroke="#2a2a4e" strokeWidth="0.8" />
        <text x="73" y="31" fontSize="4" fill="#2a4a8a" fontFamily="monospace" textAnchor="middle">WiFi</text>
      </>}
      <LED x={242} y={18} color="#10b981" />
    </svg>
  );
}

/* ── Master selector ── picks the right SVG for each model */
export function BoardSVG({ model, className }: { model: RPiModel; className?: string }) {
  // Apply visual style if selected/unselected state is needed
  // But wait, the standard PiIcon has a selected state.
  // Instead of modifying the detailed SVG to look selected (which might be hard), we can just wrap it in a div in the caller, or let the CSS handle it.

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

