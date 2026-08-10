import { FlashHistoryEntry, FlashHistoryStatus } from './history';

/**
 * Formato tabular compartido por CSV y Excel: una única lista de columnas
 * decide qué campo va en qué posición para los dos formatos y para las dos
 * direcciones (exportar/importar), así no hay dos mapeos que puedan divergir.
 *
 * El comando de Excel en Rust y el análisis de CSV de aquí abajo solo mueven
 * texto — ninguno de los dos sabe qué es un "hostname" o un "número de
 * serie". Esa traducción vive una sola vez, aquí.
 */
interface HistoryColumn {
  header: string;
  get: (entry: FlashHistoryEntry) => string;
}

const COLUMNS: HistoryColumn[] = [
  { header: 'id', get: (e) => e.id },
  { header: 'estado', get: (e) => e.status },
  { header: 'mensaje', get: (e) => e.message },
  { header: 'hostname', get: (e) => e.config.hostname },
  { header: 'numero_serie', get: (e) => e.config.serialNumber ?? '' },
  { header: 'modelo_placa', get: (e) => e.config.rpiModel ?? '' },
  { header: 'ssh', get: (e) => String(e.config.sshEnabled) },
  { header: 'wifi_ssid', get: (e) => e.config.wifiSsid ?? '' },
  { header: 'servidor', get: (e) => e.config.serverUrl ?? '' },
  { header: 'sigil_modelo', get: (e) => e.config.sigilModel ?? '' },
  { header: 'sigil_modelo_version', get: (e) => e.config.sigilModelVersion ?? '' },
  { header: 'imagen_nombre', get: (e) => e.image.name },
  { header: 'imagen_tamano_bytes', get: (e) => String(e.image.size) },
  { header: 'imagen_sha256', get: (e) => e.image.sha256 ?? '' },
  { header: 'dispositivo_modelo', get: (e) => e.device.model },
  { header: 'dispositivo_ruta', get: (e) => e.device.path },
  { header: 'dispositivo_tamano', get: (e) => e.device.size },
  { header: 'dispositivo_transporte', get: (e) => e.device.transport },
  { header: 'bundle_arquitectura', get: (e) => e.bundle?.architecture ?? '' },
  { header: 'bundle_imagen_base', get: (e) => e.bundle?.baseImageName ?? '' },
  { header: 'bytes_escritos', get: (e) => String(e.bytesWritten) },
  { header: 'bytes_totales', get: (e) => String(e.totalBytes) },
  { header: 'duracion_segundos', get: (e) => String(e.durationSeconds) },
  { header: 'iniciado', get: (e) => e.startedAt },
  { header: 'finalizado', get: (e) => e.finishedAt },
];

const VALID_STATUSES: FlashHistoryStatus[] = ['done', 'error', 'cancelled'];

/** Primera fila de cabeceras + una fila de texto por entrada. Mismo array de
 *  filas que espera `export_xlsx` en Rust y que arma el CSV de abajo. */
export function entriesToRows(entries: FlashHistoryEntry[]): string[][] {
  return [COLUMNS.map((c) => c.header), ...entries.map((e) => COLUMNS.map((c) => c.get(e)))];
}

function numberOr(value: string, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

/** Reconstruye entradas a partir de filas de texto (vengan de CSV o de
 *  Excel). Tolerante a propósito: columnas que faltan o vienen en otro orden
 *  no rompen la importación entera, solo esa columna cae a su valor por
 *  defecto; una fila sin lo mínimo para identificar el flasheo se cuenta
 *  como omitida en vez de abortar el resto del archivo. */
export function rowsToEntries(rows: string[][]): { entries: FlashHistoryEntry[]; skipped: number } {
  if (rows.length < 2) return { entries: [], skipped: 0 };

  const header = rows[0].map((h) => h.trim().toLowerCase());
  const col = (name: string) => header.indexOf(name);
  const idx = {
    id: col('id'),
    estado: col('estado'),
    mensaje: col('mensaje'),
    hostname: col('hostname'),
    numeroSerie: col('numero_serie'),
    modeloPlaca: col('modelo_placa'),
    ssh: col('ssh'),
    wifiSsid: col('wifi_ssid'),
    servidor: col('servidor'),
    sigilModelo: col('sigil_modelo'),
    sigilModeloVersion: col('sigil_modelo_version'),
    imagenNombre: col('imagen_nombre'),
    imagenTamano: col('imagen_tamano_bytes'),
    imagenSha256: col('imagen_sha256'),
    dispositivoModelo: col('dispositivo_modelo'),
    dispositivoRuta: col('dispositivo_ruta'),
    dispositivoTamano: col('dispositivo_tamano'),
    dispositivoTransporte: col('dispositivo_transporte'),
    bundleArquitectura: col('bundle_arquitectura'),
    bundleImagenBase: col('bundle_imagen_base'),
    bytesEscritos: col('bytes_escritos'),
    bytesTotales: col('bytes_totales'),
    duracion: col('duracion_segundos'),
    iniciado: col('iniciado'),
    finalizado: col('finalizado'),
  };

  const cell = (row: string[], i: number): string => (i >= 0 && i < row.length ? (row[i] ?? '').trim() : '');

  const entries: FlashHistoryEntry[] = [];
  let skipped = 0;

  for (const row of rows.slice(1)) {
    if (row.every((v) => v.trim() === '')) continue;

    const hostname = cell(row, idx.hostname);
    const estado = cell(row, idx.estado);
    const startedAt = cell(row, idx.iniciado);
    const finishedAt = cell(row, idx.finalizado);
    const fechasValidas = !Number.isNaN(new Date(startedAt).getTime()) && !Number.isNaN(new Date(finishedAt).getTime());

    if (!hostname || !VALID_STATUSES.includes(estado as FlashHistoryStatus) || !fechasValidas) {
      skipped += 1;
      continue;
    }

    const bundleArquitectura = cell(row, idx.bundleArquitectura);
    const bundleImagenBase = cell(row, idx.bundleImagenBase);

    entries.push({
      id: cell(row, idx.id) || `${startedAt}-${Math.random().toString(36).slice(2, 8)}`,
      startedAt,
      finishedAt,
      durationSeconds: numberOr(cell(row, idx.duracion), 0),
      status: estado as FlashHistoryStatus,
      message: cell(row, idx.mensaje),
      bytesWritten: numberOr(cell(row, idx.bytesEscritos), 0),
      totalBytes: numberOr(cell(row, idx.bytesTotales), 0),
      image: {
        name: cell(row, idx.imagenNombre),
        size: numberOr(cell(row, idx.imagenTamano), 0),
        sha256: cell(row, idx.imagenSha256) || null,
      },
      device: {
        model: cell(row, idx.dispositivoModelo),
        path: cell(row, idx.dispositivoRuta),
        size: cell(row, idx.dispositivoTamano),
        transport: cell(row, idx.dispositivoTransporte),
      },
      bundle: bundleArquitectura && bundleImagenBase
        ? { architecture: bundleArquitectura, baseImageName: bundleImagenBase }
        : null,
      config: {
        hostname,
        serialNumber: cell(row, idx.numeroSerie) || null,
        rpiModel: cell(row, idx.modeloPlaca) || null,
        sshEnabled: cell(row, idx.ssh).toLowerCase() === 'true',
        wifiSsid: cell(row, idx.wifiSsid) || null,
        serverUrl: cell(row, idx.servidor) || null,
        sigilModel: cell(row, idx.sigilModelo) || null,
        sigilModelVersion: cell(row, idx.sigilModeloVersion) || null,
      },
    });
  }

  return { entries, skipped };
}

// ── CSV ──────────────────────────────────────────────────────────────────
//
// Separador ';' y BOM UTF-8 a propósito: Excel en español abre un .csv con
// el separador de listas regional, que en es-ES es ';' (la ',' ya es el
// separador decimal). Con ',' el archivo se abre entero en una sola columna.

const CSV_DELIMITER = ';';
const BOM = String.fromCharCode(0xfeff);

function csvEscapeField(value: string): string {
  if (value.includes(CSV_DELIMITER) || value.includes('"') || value.includes('\n') || value.includes('\r')) {
    return `"${value.replace(/"/g, '""')}"`;
  }
  return value;
}

export function rowsToCsv(rows: string[][]): string {
  const lines = rows.map((row) => row.map(csvEscapeField).join(CSV_DELIMITER));
  return BOM + lines.join('\r\n') + '\r\n';
}

function detectDelimiter(headerLine: string): string {
  const semicolons = (headerLine.match(/;/g) ?? []).length;
  const commas = (headerLine.match(/,/g) ?? []).length;
  return semicolons >= commas ? ';' : ',';
}

/** Analizador de CSV consciente de comillas (RFC 4180): un campo entre
 *  comillas puede contener el delimitador, saltos de línea o comillas
 *  escapadas como '""'. Necesario porque varios campos del historial
 *  (mensaje de error, ruta) pueden traer texto libre. */
export function csvToRows(text: string): string[][] {
  const sinBom = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const normalizado = sinBom.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const finPrimeraLinea = normalizado.indexOf('\n');
  const primeraLinea = finPrimeraLinea === -1 ? normalizado : normalizado.slice(0, finPrimeraLinea);
  const delimiter = detectDelimiter(primeraLinea);

  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < normalizado.length; i++) {
    const char = normalizado[i];

    if (inQuotes) {
      if (char === '"') {
        if (normalizado[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += char;
      }
      continue;
    }

    if (char === '"') {
      inQuotes = true;
    } else if (char === delimiter) {
      row.push(field);
      field = '';
    } else if (char === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else {
      field += char;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows.filter((r) => r.some((f) => f.trim() !== ''));
}
