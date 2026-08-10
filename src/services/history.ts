import { BundlePair, Device, DeviceConfig, FlashProgress, ImageInfo } from '../types/models';

/**
 * Historial de fabricaciones — persistido en localStorage, igual que el
 * contador de serie: la estación no tiene backend propio, así que la memoria
 * de qué se fabricó vive en el mismo sitio que el resto del estado de sesión
 * a largo plazo.
 *
 * Solo se guardan datos de identificación, nunca secretos: ni contraseña, ni
 * clave WiFi, ni PIN del panel, ni clave de enrolamiento. El historial es una
 * bitácora de fábrica, no una bóveda de credenciales.
 */

export type FlashHistoryStatus = 'done' | 'error' | 'cancelled';

export interface FlashHistoryEntry {
  id: string;
  startedAt: string;
  finishedAt: string;
  durationSeconds: number;
  status: FlashHistoryStatus;
  message: string;
  bytesWritten: number;
  totalBytes: number;
  image: {
    name: string;
    size: number;
    sha256: string | null;
  };
  device: {
    model: string;
    path: string;
    size: string;
    transport: string;
  };
  bundle: {
    architecture: string;
    baseImageName: string;
  } | null;
  config: {
    hostname: string;
    serialNumber: string | null;
    rpiModel: string | null;
    sshEnabled: boolean;
    wifiSsid: string | null;
    serverUrl: string | null;
    sigilModel: string | null;
    sigilModelVersion: string | null;
  };
}

export const CLAVE_HISTORIAL = 'sigil-flash.history';

// Mismo criterio que el registro de actividad: una estación que lleva meses
// en marcha no debe crecer sin tope en el almacenamiento local.
const MAX_ENTRADAS_HISTORIAL = 500;

export function leerHistorial(): FlashHistoryEntry[] {
  try {
    const raw = localStorage.getItem(CLAVE_HISTORIAL);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function guardarHistorial(entries: FlashHistoryEntry[]): void {
  try {
    localStorage.setItem(CLAVE_HISTORIAL, JSON.stringify(entries));
  } catch {
    // Sin almacenamiento persistente, el historial sigue visible en esta
    // sesión; solo no sobrevive al reinicio.
  }
}

/** Antepone la entrada nueva y persiste. Devuelve la lista resultante, lista
 *  para usarse directamente como próximo estado de React. */
export function agregarEntradaHistorial(
  entries: FlashHistoryEntry[],
  entry: FlashHistoryEntry
): FlashHistoryEntry[] {
  const next = [entry, ...entries].slice(0, MAX_ENTRADAS_HISTORIAL);
  guardarHistorial(next);
  return next;
}

/** Combina lo importado con lo que ya había, por `id`: reimportar el mismo
 *  archivo dos veces no duplica filas. En un choque de id gana la versión
 *  importada, porque es la que el operario acaba de traer a propósito. */
export function fusionarHistorial(
  actuales: FlashHistoryEntry[],
  importadas: FlashHistoryEntry[]
): FlashHistoryEntry[] {
  const porId = new Map<string, FlashHistoryEntry>();
  for (const entry of actuales) porId.set(entry.id, entry);
  for (const entry of importadas) porId.set(entry.id, entry);

  const fusionado = Array.from(porId.values()).sort(
    (a, b) => new Date(b.finishedAt).getTime() - new Date(a.finishedAt).getTime()
  );
  const limitado = fusionado.slice(0, MAX_ENTRADAS_HISTORIAL);
  guardarHistorial(limitado);
  return limitado;
}

/** Construye la entrada a partir de lo que estaba seleccionado al iniciar la
 *  fabricación (la instantánea) y el estado final que publicó el escritor. */
export function construirEntradaHistorial(params: {
  startedAt: string;
  image: ImageInfo;
  device: Device;
  bundle: BundlePair | null;
  config: DeviceConfig;
  progress: FlashProgress;
}): FlashHistoryEntry {
  const { startedAt, image, device, bundle, config, progress } = params;
  const finishedAt = new Date().toISOString();
  const durationSeconds = Math.max(
    0,
    (new Date(finishedAt).getTime() - new Date(startedAt).getTime()) / 1000
  );

  return {
    id: `${startedAt}-${Math.random().toString(36).slice(2, 8)}`,
    startedAt,
    finishedAt,
    durationSeconds,
    status: progress.status as FlashHistoryStatus,
    message: progress.message,
    bytesWritten: progress.bytes_written,
    totalBytes: progress.total_bytes,
    image: {
      name: image.name,
      size: image.size,
      sha256: image.sha256 ?? null,
    },
    device: {
      model: device.model,
      path: device.path,
      size: device.size,
      transport: device.transport,
    },
    bundle: bundle
      ? { architecture: bundle.architecture, baseImageName: bundle.base_image_name }
      : null,
    config: {
      hostname: config.hostname,
      serialNumber: config.serialNumber ?? null,
      rpiModel: config.rpiModel ?? null,
      sshEnabled: config.sshEnabled,
      wifiSsid: config.wifiSsid ?? null,
      serverUrl: config.serverUrl ?? null,
      sigilModel: config.sigilModel ?? null,
      sigilModelVersion: config.sigilModelVersion ?? null,
    },
  };
}
