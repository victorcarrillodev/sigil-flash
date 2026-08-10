import { beforeEach, describe, expect, it } from 'vitest';
import {
  agregarEntradaHistorial,
  CLAVE_HISTORIAL,
  construirEntradaHistorial,
  FlashHistoryEntry,
  leerHistorial,
} from './history';
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
  hostname: 'sigil-device',
  username: 'sigil',
  password: 'super-secreta',
  wifiSsid: 'Fabrica',
  wifiPassword: 'clave-wifi-secreta',
  sshEnabled: true,
  rpiModel: 'raspberry-pi-zero-2-w',
  serialNumber: 'SIG-EMOD-000042-0826',
  sigilModel: 'edge-mod',
  sigilModelVersion: '2',
  panelPin: '847392',
  apiKey: 'clave-de-un-solo-uso-secreta',
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

beforeEach(() => {
  localStorage.clear();
});

describe('construirEntradaHistorial', () => {
  it('copia los datos de identificación pero nunca los secretos', () => {
    const entry = construirEntradaHistorial({
      startedAt: new Date().toISOString(),
      image: imagen,
      device: dispositivo,
      bundle,
      config,
      progress: progresoCompletado,
    });

    expect(entry.config.hostname).toBe('sigil-device');
    expect(entry.config.serialNumber).toBe('SIG-EMOD-000042-0826');
    expect(entry.config.wifiSsid).toBe('Fabrica');
    expect(entry.config.sshEnabled).toBe(true);
    expect(entry.image.name).toBe(imagen.name);
    expect(entry.device.model).toBe('SD Card');
    expect(entry.bundle).toEqual({ architecture: 'arm64', baseImageName: bundle.base_image_name });

    // La bitácora es de fábrica, no una bóveda de credenciales.
    const serializado = JSON.stringify(entry);
    expect(serializado).not.toContain('super-secreta');
    expect(serializado).not.toContain('clave-wifi-secreta');
    expect(serializado).not.toContain('847392');
    expect(serializado).not.toContain('clave-de-un-solo-uso-secreta');
  });

  it('calcula la duración a partir de las marcas de tiempo', () => {
    const startedAt = new Date(Date.now() - 5000).toISOString();
    const entry = construirEntradaHistorial({
      startedAt,
      image: imagen,
      device: dispositivo,
      bundle: null,
      config,
      progress: progresoCompletado,
    });

    expect(entry.durationSeconds).toBeGreaterThanOrEqual(4.9);
    expect(entry.bundle).toBeNull();
  });

  it('cada entrada recibe un identificador distinto', () => {
    const startedAt = new Date().toISOString();
    const a = construirEntradaHistorial({
      startedAt,
      image: imagen,
      device: dispositivo,
      bundle,
      config,
      progress: progresoCompletado,
    });
    const b = construirEntradaHistorial({
      startedAt,
      image: imagen,
      device: dispositivo,
      bundle,
      config,
      progress: progresoCompletado,
    });
    expect(a.id).not.toBe(b.id);
  });
});

describe('leerHistorial / agregarEntradaHistorial', () => {
  it('empieza vacío sin nada guardado', () => {
    expect(leerHistorial()).toEqual([]);
  });

  it('antepone entradas nuevas y persiste en localStorage', () => {
    const primera = construirEntradaHistorial({
      startedAt: new Date().toISOString(),
      image: imagen,
      device: dispositivo,
      bundle,
      config,
      progress: progresoCompletado,
    });
    const segunda = construirEntradaHistorial({
      startedAt: new Date().toISOString(),
      image: imagen,
      device: dispositivo,
      bundle,
      config: { ...config, hostname: 'sigil-device-2' },
      progress: progresoCompletado,
    });

    let lista = agregarEntradaHistorial([], primera);
    lista = agregarEntradaHistorial(lista, segunda);

    expect(lista.map((e) => e.config.hostname)).toEqual(['sigil-device-2', 'sigil-device']);
    expect(leerHistorial()).toHaveLength(2);
  });

  it('un valor corrupto en localStorage no rompe la lectura', () => {
    localStorage.setItem(CLAVE_HISTORIAL, '{ esto no es JSON válido');
    expect(leerHistorial()).toEqual([]);
  });

  it('acota el historial para que no crezca sin límite', () => {
    let lista: FlashHistoryEntry[] = [];
    for (let i = 0; i < 520; i++) {
      const entry = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config,
        progress: progresoCompletado,
      });
      lista = agregarEntradaHistorial(lista, entry);
    }
    expect(lista.length).toBe(500);
  });
});
