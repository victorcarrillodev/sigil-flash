/**
 * Formato de cifras para un operario de fábrica: unidades legibles, coma
 * decimal española y un guion cuando el dato todavía no se conoce. Prometer
 * "0 s" de ETA cuando no hay estimación es peor que no decir nada.
 */

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB'] as const;

function oneDecimal(value: number): string {
  return value.toFixed(1).replace('.', ',');
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${Math.round(bytes)} B`;

  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${oneDecimal(value)} ${UNITS[unit]}`;
}

export function formatSpeed(megabytesPerSecond: number): string {
  if (!Number.isFinite(megabytesPerSecond) || megabytesPerSecond < 0) return '0,0 MB/s';
  return `${oneDecimal(megabytesPerSecond)} MB/s`;
}

export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return '—';

  const total = Math.round(seconds);
  if (total < 60) return `${total} s`;

  if (total < 3600) {
    const minutes = Math.floor(total / 60);
    const rest = total % 60;
    return rest === 0 ? `${minutes} min` : `${minutes} min ${rest} s`;
  }

  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  return `${hours} h ${minutes} min`;
}

export function percentOf(current: number, total: number): number {
  if (!Number.isFinite(current) || !Number.isFinite(total) || total <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((current / total) * 100)));
}

const SIZE_MULTIPLIERS: Record<string, number> = {
  b: 1,
  kb: 1024,
  mb: 1024 ** 2,
  gb: 1024 ** 3,
  tb: 1024 ** 4,
};

/**
 * Interpreta el texto de tamaño que reporta el backend ("29,74 GB", "512.00
 * MB") para el desglose visual de almacenamiento. Best-effort: un formato que
 * no reconoce no debe romper el panel, solo omitir la barra.
 */
export function parseDeviceSize(text: string): number | null {
  const match = text.trim().match(/^([\d.,]+)\s*(b|kb|mb|gb|tb)$/i);
  if (!match) return null;
  const value = Number.parseFloat(match[1].replace(',', '.'));
  if (!Number.isFinite(value)) return null;
  return value * SIZE_MULTIPLIERS[match[2].toLowerCase()];
}
