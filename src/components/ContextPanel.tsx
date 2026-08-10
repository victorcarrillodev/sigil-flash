import React from 'react';
import { BundlePair, Device, DeviceConfig, ImageInfo } from '../types/models';
import { formatBytes, parseDeviceSize } from '../services/format';

interface ContextPanelProps {
  image: ImageInfo | null;
  bundle: BundlePair | null;
  device: Device | null;
  config: DeviceConfig;
}

const BOARD_NAMES: Record<string, string> = {
  'raspberry-pi-5': 'Raspberry Pi 5',
  'raspberry-pi-4b': 'Raspberry Pi 4B',
  'raspberry-pi-3b-plus': 'Raspberry Pi 3B+',
  'raspberry-pi-3b': 'Raspberry Pi 3B',
  'raspberry-pi-zero-2-w': 'Raspberry Pi Zero 2 W',
  'raspberry-pi-zero-w': 'Raspberry Pi Zero W',
  'raspberry-pi-1': 'Raspberry Pi 1',
};

const BOARD_BITS: Record<string, string> = {
  'raspberry-pi-5': '64 bits · PCIe',
  'raspberry-pi-4b': '64 bits',
  'raspberry-pi-3b-plus': '64 bits',
  'raspberry-pi-3b': '64 bits',
  'raspberry-pi-zero-2-w': '64 bits',
  'raspberry-pi-zero-w': '32 bits',
  'raspberry-pi-1': '32 bits',
};

/**
 * Rasgos reales que distinguen cada placa: no hay una sola silueta con dos
 * variantes. La 3B y la 3B+ son casi idénticas por fuera y la Zero W de la
 * Zero 2 W ni eso — para esas, la etiqueta del chip es lo único honesto que
 * las diferencia, y se dibuja igual.
 *
 * Proporciones reales (no inventadas): la placa "tamaño completo" (3B, 3B+,
 * 4B, 5) mide 85×56 mm — 1,52:1 — y la Zero mide 65×30 mm — 2,17:1. La Zero
 * es más alargada y angosta que la de tamaño completo, no más cuadrada.
 */
interface BoardSpec {
  formFactor: 'full' | 'zero' | 'legacy';
  hdmi: 'dual-micro' | 'full';
  usb3: boolean;
  ethernet: boolean;
  pcie: boolean;
  audioJack: boolean;
  dsi: boolean;
  wireless: boolean;
  poe: boolean;
  /** Blindaje metálico sobre el chip inalámbrico: desde la 3B+, no en la 3B. */
  shielded: boolean;
  powerConnector: 'usb-c' | 'micro-usb';
  chip: string;
}

const BOARD_SPECS: Record<string, BoardSpec> = {
  'raspberry-pi-5': {
    formFactor: 'full',
    hdmi: 'dual-micro',
    usb3: true,
    ethernet: true,
    pcie: true,
    audioJack: false,
    dsi: true,
    wireless: true,
    poe: false,
    shielded: true,
    powerConnector: 'usb-c',
    chip: '5',
  },
  'raspberry-pi-4b': {
    formFactor: 'full',
    hdmi: 'dual-micro',
    usb3: true,
    ethernet: true,
    pcie: false,
    audioJack: false,
    dsi: true,
    wireless: true,
    poe: true,
    shielded: true,
    powerConnector: 'usb-c',
    chip: '4B',
  },
  'raspberry-pi-3b-plus': {
    formFactor: 'full',
    hdmi: 'full',
    usb3: false,
    ethernet: true,
    pcie: false,
    audioJack: true,
    dsi: true,
    wireless: true,
    poe: true,
    shielded: true,
    powerConnector: 'micro-usb',
    chip: '3B+',
  },
  'raspberry-pi-3b': {
    formFactor: 'full',
    hdmi: 'full',
    usb3: false,
    ethernet: true,
    pcie: false,
    audioJack: true,
    dsi: true,
    wireless: true,
    poe: false,
    shielded: false,
    powerConnector: 'micro-usb',
    chip: '3B',
  },
  'raspberry-pi-zero-2-w': {
    formFactor: 'zero',
    hdmi: 'full',
    usb3: false,
    ethernet: false,
    pcie: false,
    audioJack: false,
    dsi: false,
    wireless: true,
    poe: false,
    shielded: false,
    powerConnector: 'micro-usb',
    chip: 'Z2W',
  },
  'raspberry-pi-zero-w': {
    formFactor: 'zero',
    hdmi: 'full',
    usb3: false,
    ethernet: false,
    pcie: false,
    audioJack: false,
    dsi: false,
    wireless: true,
    poe: false,
    shielded: false,
    powerConnector: 'micro-usb',
    chip: 'ZW',
  },
  'raspberry-pi-1': {
    formFactor: 'legacy',
    hdmi: 'full',
    usb3: false,
    ethernet: true,
    pcie: false,
    audioJack: true,
    dsi: false,
    wireless: false,
    poe: false,
    shielded: false,
    powerConnector: 'micro-usb',
    chip: '1',
  },
};

/** Puerto de dos tonos — carcasa clara y ranura oscura — como se ve un
 *  conector real desde arriba, no un bloque ciego de un solo color. */
const Port: React.FC<{ x: number; y: number; w: number; h: number; rx?: number; slotClass?: string }> = ({
  x,
  y,
  w,
  h,
  rx = 1.4,
  slotClass,
}) => {
  const inset = Math.min(w, h) * 0.24;
  return (
    <>
      <rect x={x} y={y} width={w} height={h} rx={rx} className="board-port" />
      <rect
        x={x + inset}
        y={y + inset}
        width={w - inset * 2}
        height={h - inset * 2}
        rx={Math.max(rx - 0.6, 0)}
        className={slotClass ?? 'board-port-slot'}
      />
    </>
  );
};

/** Agujero de montaje: anillo dorado con el centro perforado. */
const MountHole: React.FC<{ cx: number; cy: number; r?: number }> = ({ cx, cy, r = 4.2 }) => (
  <>
    <circle cx={cx} cy={cy} r={r} className="board-hole-ring" />
    <circle cx={cx} cy={cy} r={r * 0.48} className="board-hole-center" />
  </>
);

/** Fila de pines dorados: la cabecera GPIO, o los 4 pines extra del PoE. */
const PinRow: React.FC<{ x: number; y: number; count: number; span: number }> = ({ x, y, count, span }) => (
  <>
    {Array.from({ length: count }).map((_, i) => (
      <rect key={i} x={x + i * (span / count)} y={y} width={2.6} height={3.6} rx={0.5} className="board-pin" />
    ))}
  </>
);

/** Conector de cinta flexible (cámara/pantalla) visto de frente, con sus "dientes". */
const Ribbon: React.FC<{ x: number; y: number }> = ({ x, y }) => (
  <>
    <rect x={x} y={y} width={11} height={5.5} rx={0.8} className="board-ribbon" />
    {[0, 1, 2, 3].map((i) => (
      <line
        key={i}
        x1={x + 1.6 + i * 2.5}
        y1={y + 0.8}
        x2={x + 1.6 + i * 2.5}
        y2={y + 4.7}
        className="board-ribbon-tooth"
      />
    ))}
  </>
);

/** Placa de tamaño completo (85×56 mm reales): cabecera GPIO arriba,
 *  USB/Ethernet al costado derecho, vídeo/alimentación abajo — como en la
 *  placa real, no apiladas todas en el mismo borde. */
const FullBoardIcon: React.FC<{ spec: BoardSpec; legacy: boolean }> = ({ spec, legacy }) => {
  const { hdmi, usb3, ethernet, pcie, audioJack, dsi, wireless, poe, shielded, powerConnector, chip } = spec;
  const bx = 8;
  const by = 20;
  const bw = 140;
  const bh = 92;
  const right = bx + bw;
  const bottom = by + bh;
  const headerCount = legacy ? 13 : 20;
  const headerSpan = bw * (legacy ? 0.5 : 0.86);
  const chipX = bx + bw * 0.27;
  const chipY = by + bh * 0.3;
  const chipW = 32;
  // USB en dos vainas lado a lado: así se ven de verdad los puertos apilados,
  // no como un bloque ciego.
  const usbBlockH = usb3 ? 16 : 13;
  const usbShellH = (usbBlockH - 2) / 2;
  const usbY = by + 18;
  const ethY = usbY + usbBlockH + 5;

  return (
    <svg className="board-icon" viewBox="0 0 168 138" style={{ aspectRatio: '168 / 138' }} aria-hidden="true">
      <defs>
        <linearGradient id="boardChip" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="var(--chip-fill-2)" />
          <stop offset="100%" stopColor="var(--chip-fill)" />
        </linearGradient>
      </defs>

      <rect x={bx} y={by} width={bw} height={bh} rx={7} className="board-pcb" />

      {/* Cabecera GPIO: una fila, 40 pines reales (26 en la Pi 1). */}
      <PinRow x={bx + 8} y={by - 9} count={headerCount} span={headerSpan} />

      {/* Conectores de cinta: cámara en todas, pantalla desde la Pi 2. */}
      <Ribbon x={bx + 10} y={by - 3} />
      {dsi && <Ribbon x={right - 27} y={by - 3} />}

      {/* SoC con su etiqueta y el chip de memoria/alimentación junto a él. */}
      <rect x={chipX} y={chipY} width={chipW} height={chipW} rx={4} fill="url(#boardChip)" />
      <text x={chipX + chipW / 2} y={chipY + chipW / 2 + 4} textAnchor="middle" className="board-chip-label">
        {chip}
      </text>
      <rect x={chipX + chipW + 4} y={chipY + 6} width={14} height={14} rx={2} className="board-chip-secondary" />

      {/* Módulo inalámbrico — no está en la Pi 1. Desde la 3B+ vive bajo una
          lata metálica de blindaje; en la 3B va al descubierto. */}
      {wireless && (
        <rect
          x={bx + 12}
          y={bottom - 40}
          width={15}
          height={15}
          rx={2}
          className={shielded ? 'board-shield' : 'board-chip-secondary'}
        />
      )}

      {/* Ranura de la microSD, cerca del borde izquierdo. */}
      <rect x={14} y={36} width={18} height={22} rx={1.5} className="board-port" />
      <rect x={17} y={39} width={12} height={16} rx={1} className="board-port-slot" />

      {/* Botón de encendido: novedad de la Pi 5. */}
      {chip === '5' && <circle cx={bx + 26} cy={bottom - 20} r={2.2} className="board-button" />}

      {/* LEDs de estado: rojo de encendido, verde de actividad. */}
      <circle cx={bx + 8} cy={65} r={1.6} className="board-led-power" />
      <circle cx={bx + 14} cy={65} r={1.6} className="board-led-act" />

      {/* Cabecera PoE (3B+ en adelante): cuatro pines aparte, borde derecho. */}
      {poe && <PinRow x={right - 20} y={bottom - 34} count={4} span={16} />}

      <MountHole cx={bx + 9} cy={by + 9} />
      <MountHole cx={right - 9} cy={by + 9} />
      <MountHole cx={bx + 9} cy={bottom - 9} />
      <MountHole cx={right - 9} cy={bottom - 9} />

      {/* Borde derecho: USB en dos vainas — así se ven los puertos apilados
          desde arriba — y Ethernet debajo. El azul de la ranura es el color
          real de un USB3, no un acento decorativo. */}
      <Port x={right - 4} y={usbY} w={12} h={usbShellH} slotClass={usb3 ? 'board-port-slot-usb3' : undefined} />
      <Port
        x={right - 4}
        y={usbY + usbShellH + 2}
        w={12}
        h={usbShellH}
        slotClass={usb3 ? 'board-port-slot-usb3' : undefined}
      />
      {ethernet && <Port x={right - 4} y={ethY} w={12} h={14} />}

      {/* Borde inferior: alimentación, vídeo, audio/compuesto y (Pi 5) PCIe. */}
      <Port x={bx + 10} y={bottom - 4} w={powerConnector === 'usb-c' ? 16 : 11} h={8} />
      {hdmi === 'dual-micro' ? (
        <>
          <Port x={bx + 36} y={bottom - 4} w={9} h={8} />
          <Port x={bx + 48} y={bottom - 4} w={9} h={8} />
        </>
      ) : (
        <Port x={bx + 36} y={bottom - 4} w={15} h={8} />
      )}
      {audioJack && (
        <>
          <circle cx={bx + 64} cy={bottom + 1} r={4.5} className="board-port" />
          <circle cx={bx + 64} cy={bottom + 1} r={2} className="board-port-slot" />
        </>
      )}
      {pcie && <Port x={right - 30} y={bottom - 3} w={22} h={6} rx={1} />}
    </svg>
  );
};

/** Placa Zero (65×30 mm reales): tira, no rectángulo — huella de 40 pines y
 *  los conectores en el borde inferior, como en la real. */
const ZeroBoardIcon: React.FC<{ spec: BoardSpec }> = ({ spec }) => {
  const { chip, wireless } = spec;
  const bx = 8;
  const by = 18;
  const bw = 108;
  const bh = 50;
  const right = bx + bw;
  const bottom = by + bh;

  return (
    <svg className="board-icon" viewBox="0 0 124 90" style={{ aspectRatio: '124 / 90' }} aria-hidden="true">
      <defs>
        <linearGradient id="boardChip" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="var(--chip-fill-2)" />
          <stop offset="100%" stopColor="var(--chip-fill)" />
        </linearGradient>
      </defs>

      <rect x={bx} y={by} width={bw} height={bh} rx={5} className="board-pcb" />

      {/* Huella de 40 pines. */}
      <PinRow x={bx + 9} y={by - 8} count={20} span={bw - 18} />

      <rect x={bx + bw / 2 - 11} y={by + bh / 2 - 11} width={22} height={22} rx={3} fill="url(#boardChip)" />
      <text
        x={bx + bw / 2}
        y={by + bh / 2 + 4.5}
        textAnchor="middle"
        className="board-chip-label board-chip-label-sm"
      >
        {chip}
      </text>

      <MountHole cx={bx + 6} cy={by + 6} r={3.2} />
      <MountHole cx={right - 6} cy={by + 6} r={3.2} />
      <MountHole cx={bx + 6} cy={bottom - 6} r={3.2} />
      <MountHole cx={right - 6} cy={bottom - 6} r={3.2} />

      {/* Ranura de la microSD. */}
      <rect x={12} y={30.5} width={14} height={18} rx={1.2} className="board-port" />
      <rect x={14} y={32.5} width={10} height={14} rx={1} className="board-port-slot" />

      {/* Conector de cámara en el borde derecho. */}
      <Port x={right - 3} y={by + bh / 2 - 5} w={8} h={10} />

      {/* Antena de PCB: un rastro grabado en la placa, no un chip aparte. */}
      {wireless && (
        <path d={`M ${bx + 78},${by + 2} l 4,-3 l 4,3 l 4,-3 l 4,3`} className="board-antenna" />
      )}

      {/* LED de actividad. */}
      <circle cx={30} cy={20} r={1.3} className="board-led-act" />

      {/* Borde inferior: micro-USB de alimentación, micro-USB de datos, mini-HDMI. */}
      <Port x={14} y={66} w={9} h={7} />
      <Port x={34} y={66} w={9} h={7} />
      <Port x={94} y={66} w={14} h={7} />
    </svg>
  );
};

/** Silueta esquemática, no una foto: forma, puertos y chip cambian según el modelo real. */
const BoardIcon: React.FC<{ spec: BoardSpec }> = ({ spec }) =>
  spec.formFactor === 'zero' ? (
    <ZeroBoardIcon spec={spec} />
  ) : (
    <FullBoardIcon spec={spec} legacy={spec.formFactor === 'legacy'} />
  );

const BoardCard: React.FC<{ model?: string | null }> = ({ model }) => {
  const key = model || 'raspberry-pi-zero-2-w';
  const spec = BOARD_SPECS[key] ?? BOARD_SPECS['raspberry-pi-zero-2-w'];
  const name = BOARD_NAMES[key] ?? key;
  const bits = BOARD_BITS[key] ?? '';

  return (
    <div className="context-board">
      <BoardIcon spec={spec} />
      <div className="context-board-text">
        <span className="context-board-name">{name}</span>
        {bits && <span className="context-board-bits">{bits}</span>}
      </div>
    </div>
  );
};

const DONUT_R = 26;
const DONUT_CIRCUMFERENCE = 2 * Math.PI * DONUT_R;

/** Misma cifra que la barra plana, en forma circular: dos lecturas del mismo dato.
 *  Sin unidad elegida el arco de valor mide 0 (dasharray "0 circunferencia"),
 *  así que el track queda solo — la gráfica sigue ahí, solo vacía. */
const StorageDonut: React.FC<{ percent: number; overflow: boolean; label?: string }> = ({
  percent,
  overflow,
  label,
}) => {
  const clamped = Math.max(0, Math.min(100, percent));
  const dash = (clamped / 100) * DONUT_CIRCUMFERENCE;

  return (
    <svg className="storage-donut" viewBox="0 0 64 64" aria-hidden="true">
      <defs>
        <linearGradient id="storageDonutGrad" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="var(--accent)" />
          <stop offset="100%" stopColor="var(--accent-strong)" />
        </linearGradient>
      </defs>
      <circle cx="32" cy="32" r={DONUT_R} className="storage-donut-track" strokeWidth="9" fill="none" />
      <circle
        cx="32"
        cy="32"
        r={DONUT_R}
        className={`storage-donut-value${overflow ? ' storage-donut-value-overflow' : ''}`}
        strokeWidth="9"
        fill="none"
        strokeLinecap="round"
        strokeDasharray={`${dash} ${DONUT_CIRCUMFERENCE}`}
        transform="rotate(-90 32 32)"
      />
      <text x="32" y="37" textAnchor="middle" className="storage-donut-label">
        {label ?? `${Math.round(clamped)}%`}
      </text>
    </svg>
  );
};

/** La gráfica se dibuja siempre — con o sin unidad elegida — para que la
 *  tarjeta no colapse a un simple aviso de texto. Sin unidad, el donut y la
 *  barra quedan en su estado vacío (mismo hueco, sin relleno de color). */
const StorageBreakdown: React.FC<{ device: Device | null; image: ImageInfo | null }> = ({
  device,
  image,
}) => {
  const totalBytes = device ? parseDeviceSize(device.size) : null;
  const imageBytes = image?.size ?? 0;
  const known = totalBytes !== null && totalBytes > 0;
  const usedPercent = known ? (imageBytes / totalBytes!) * 100 : 0;
  const overflow = known && imageBytes > totalBytes!;
  const freeBytes = known ? Math.max(totalBytes! - imageBytes, 0) : null;

  return (
    <div className={`context-storage${device ? '' : ' context-storage-empty'}`}>
      <div className="storage-head">
        <span className="storage-model">{device ? device.model : 'Sin unidad seleccionada'}</span>
        {device && <code className="storage-path">{device.path}</code>}
      </div>

      <div className="storage-visuals">
        <StorageDonut percent={known ? usedPercent : 0} overflow={overflow} label={known ? undefined : '—'} />

        <div className="storage-bar-col">
          <div
            className={`storage-bar${overflow ? ' storage-bar-overflow' : ''}`}
            role="img"
            aria-label={
              !device
                ? 'Sin unidad de almacenamiento seleccionada'
                : image
                  ? `${formatBytes(imageBytes)} de imagen sobre ${device.size} de capacidad`
                  : `Unidad de ${device.size} sin imagen asignada todavía`
            }
          >
            {known && image && (
              <div className="storage-bar-used" style={{ width: `${Math.min(100, usedPercent)}%` }} />
            )}
          </div>

          <div className="storage-figures">
            {!device ? (
              <span className="context-empty">Elija una unidad</span>
            ) : image ? (
              <>
                <span>
                  <span className="legend-dot legend-dot-used" aria-hidden="true" />
                  {formatBytes(imageBytes)} imagen
                </span>
                {freeBytes !== null && (
                  <span>
                    <span className="legend-dot legend-dot-free" aria-hidden="true" />
                    {formatBytes(freeBytes)} libres
                  </span>
                )}
              </>
            ) : (
              <span className="context-empty">Elija una imagen</span>
            )}
            <span className="storage-total">{device ? `${device.size} total` : '—'}</span>
          </div>
        </div>
      </div>

      {overflow && <p className="message-error storage-warning">La imagen no cabe en esta unidad.</p>}
    </div>
  );
};

const DetailRow: React.FC<{ label: string; value: React.ReactNode }> = ({ label, value }) => (
  <div className="context-detail">
    <span className="context-detail-key">{label}</span>
    <span className="context-detail-value">{value}</span>
  </div>
);

export const ContextPanel: React.FC<ContextPanelProps> = ({ image, bundle, device, config }) => (
  <section className="context-panel" aria-label="Resumen de la fabricación">
    <div className="context-card">
      <span className="context-card-title">Placa de destino</span>
      <BoardCard model={config.rpiModel} />
    </div>

    <div className="context-card">
      <span className="context-card-title">Unidad de almacenamiento</span>
      <StorageBreakdown device={device} image={image} />
    </div>

    <div className="context-card context-card-details">
      <span className="context-card-title">Características</span>
      <div className="context-detail-grid">
        <DetailRow label="Hostname" value={config.hostname || '—'} />
        <DetailRow label="N.º de serie" value={config.serialNumber || '—'} />
        <DetailRow label="SSH" value={config.sshEnabled ? 'Activado' : 'Desactivado'} />
        <DetailRow label="WiFi" value={config.wifiSsid ? config.wifiSsid : 'Sin configurar'} />
        <DetailRow label="Imagen" value={image ? image.name : 'Sin elegir'} />
        <DetailRow
          label="Bundle"
          value={bundle ? `${bundle.contract_name} · ${bundle.architecture}` : '—'}
        />
      </div>
    </div>
  </section>
);
