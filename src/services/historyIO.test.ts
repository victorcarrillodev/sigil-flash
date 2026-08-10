import { describe, expect, it } from 'vitest';
import { csvToRows, entriesToRows, rowsToCsv, rowsToEntries } from './historyIO';
import { construirEntradaHistorial, FlashHistoryEntry } from './history';
import { BundlePair, Device, DeviceConfig, FlashProgress, ImageInfo } from '../types/models';

const imagen: ImageInfo = {
  path: '/artifacts/images/2026-06-18-raspios-trixie-arm64-lite.img.xz',
  name: '2026-06-18-raspios-trixie-arm64-lite.img.xz',
  size: 524_875_608,
  sha256: 'a'.repeat(64),
};

const dispositivo: Device = {
  name: 'mmcblk0',
  path: '/dev/mmcblk0',
  size: '29,74 GB',
  model: 'SD Card',
  type: 'disk',
  removable: true,
  transport: 'mmc',
};

const bundle: BundlePair = {
  contract_name: 'offline-package-contract',
  repo: '/artifacts/bundles/offline-package-contract-repo',
  payload: '/artifacts/payloads/offline-package-contract-payload',
  architecture: 'arm64',
  base_image_name: '2026-06-18-raspios-trixie-arm64-lite.img.xz',
  base_image_sha256: 'b'.repeat(64),
};

const config: DeviceConfig = {
  hostname: 'sigil-device-07',
  username: 'sigil',
  sshEnabled: true,
  rpiModel: 'raspberry-pi-zero-2-w',
  serialNumber: 'SIG-EMOD-000007-0826',
  wifiSsid: 'Fabrica',
  serverUrl: 'https://sigil-server.sphinx-pickerel.ts.net',
};

const progresoCompletado: FlashProgress = {
  bytes_written: 524_875_608,
  total_bytes: 524_875_608,
  speed_mbps: 42,
  eta_seconds: 0,
  status: 'done',
  message: 'Flasheo, instalación y provisión completados exitosamente',
};

function crearEntrada(overrides: Partial<Parameters<typeof construirEntradaHistorial>[0]> = {}): FlashHistoryEntry {
  return construirEntradaHistorial({
    startedAt: new Date(Date.now() - 90_000).toISOString(),
    image: imagen,
    device: dispositivo,
    bundle,
    config,
    progress: progresoCompletado,
    ...overrides,
  });
}

describe('entriesToRows / rowsToEntries', () => {
  it('la fila de cabecera trae los mismos campos que se usan al leer', () => {
    const rows = entriesToRows([]);
    expect(rows).toEqual([expect.arrayContaining(['id', 'estado', 'hostname', 'numero_serie'])]);
  });

  it('reconstruye exactamente la misma entrada tras ida y vuelta', () => {
    const entrada = crearEntrada();
    const { entries, skipped } = rowsToEntries(entriesToRows([entrada]));

    expect(skipped).toBe(0);
    expect(entries).toEqual([entrada]);
  });

  it('mapea por nombre de cabecera, no por posición', () => {
    const entrada = crearEntrada();
    const filas = entriesToRows([entrada]);
    const cabecera = [...filas[0]];
    const fila = [...filas[1]];

    // Se baraja el orden de las columnas, como haría un operario que
    // reorganiza el Excel a mano.
    const orden = [3, 1, 0, 2, ...cabecera.slice(4).map((_, i) => i + 4)];
    const cabeceraBarajada = orden.map((i) => cabecera[i]);
    const filaBarajada = orden.map((i) => fila[i]);

    const { entries } = rowsToEntries([cabeceraBarajada, filaBarajada]);
    expect(entries[0].config.hostname).toBe(entrada.config.hostname);
    expect(entries[0].status).toBe(entrada.status);
  });

  it('omite filas sin lo mínimo para identificar el flasheo, sin abortar el resto', () => {
    const buena = crearEntrada();
    const filas = entriesToRows([buena]);
    const cabecera = filas[0];
    const filaSinHostname = filas[1].map((v, i) => (cabecera[i] === 'hostname' ? '' : v));
    const filaConEstadoInventado = filas[1].map((v, i) => (cabecera[i] === 'estado' ? 'lo_que_sea' : v));

    const { entries, skipped } = rowsToEntries([cabecera, filaSinHostname, filaConEstadoInventado, filas[1]]);

    expect(skipped).toBe(2);
    expect(entries).toHaveLength(1);
    expect(entries[0].config.hostname).toBe(buena.config.hostname);
  });

  it('ignora filas completamente en blanco sin contarlas como omitidas', () => {
    const buena = crearEntrada();
    const filas = entriesToRows([buena]);
    const filaVacia = filas[1].map(() => '');

    const { entries, skipped } = rowsToEntries([filas[0], filaVacia, filas[1]]);
    expect(skipped).toBe(0);
    expect(entries).toHaveLength(1);
  });

  it('sin filas de datos no produce entradas ni cuenta omisiones', () => {
    expect(rowsToEntries([])).toEqual({ entries: [], skipped: 0 });
    expect(rowsToEntries([['id', 'estado']])).toEqual({ entries: [], skipped: 0 });
  });
});

describe('rowsToCsv / csvToRows', () => {
  it('un csv construido por la propia app se relee exactamente igual', () => {
    const entrada = crearEntrada({
      progress: { ...progresoCompletado, message: 'Todo bien' },
    });
    const filas = entriesToRows([entrada]);
    const csv = rowsToCsv(filas);
    expect(csv.charCodeAt(0)).toBe(0xfeff);
    expect(csvToRows(csv)).toEqual(filas);
  });

  it('escapa y recupera campos con el delimitador, comillas y saltos de línea', () => {
    const entrada = crearEntrada({
      progress: {
        ...progresoCompletado,
        status: 'error',
        message: 'Fallo en "partición 2"; reintentar\ncon la tarjeta reinsertada',
      },
    });
    const filas = entriesToRows([entrada]);
    const releidas = csvToRows(rowsToCsv(filas));
    expect(releidas).toEqual(filas);

    const { entries } = rowsToEntries(releidas);
    expect(entries[0].message).toBe('Fallo en "partición 2"; reintentar\ncon la tarjeta reinsertada');
  });

  it('detecta coma como delimitador en un csv exportado con configuración regional en inglés', () => {
    const texto = 'id,estado,hostname\nabc123,done,sigil-device-09\n';
    const filas = csvToRows(texto);
    expect(filas).toEqual([
      ['id', 'estado', 'hostname'],
      ['abc123', 'done', 'sigil-device-09'],
    ]);
  });

  it('detecta punto y coma como delimitador (Excel en español)', () => {
    const texto = 'id;estado;hostname\nabc123;done;sigil-device-09\n';
    const filas = csvToRows(texto);
    expect(filas).toEqual([
      ['id', 'estado', 'hostname'],
      ['abc123', 'done', 'sigil-device-09'],
    ]);
  });
});
