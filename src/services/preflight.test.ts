import { describe, expect, it } from 'vitest';
import { buildPreflight, STEP_IDS } from './preflight';
import { BundlePair, Device, DeviceConfig, ImageInfo } from '../types/models';

const imagen: ImageInfo = {
  path: '/artifacts/images/2026-06-18-raspios-trixie-arm64-lite.img.xz',
  name: '2026-06-18-raspios-trixie-arm64-lite.img.xz',
  size: 524_875_608,
  sha256: null,
};

const bundle: BundlePair = {
  contract_name: 'offline-package-contract',
  repo: '/artifacts/bundles/offline-package-contract-repo',
  payload: '/artifacts/payloads/offline-package-contract-payload',
  architecture: 'arm64',
  base_image_name: '2026-06-18-raspios-trixie-arm64-lite.img.xz',
  base_image_sha256: 'a'.repeat(64),
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

const configValida: DeviceConfig = {
  hostname: 'sigil-device',
  username: 'sigil',
  serialNumber: 'SN-2026-0001',
  sshEnabled: false,
  rpiModel: 'raspberry-pi-zero-2-w',
  serverUrl: 'https://sigil-server.example',
  apiKey: 'enrollment-key-de-un-solo-uso',
};

const estadoCompleto = {
  image: imagen,
  bundle,
  bundleError: null,
  device: dispositivo,
  config: configValida,
  flashing: false,
};

describe('buildPreflight', () => {
  it('declara los cuatro pasos en orden de fabricación', () => {
    const { steps } = buildPreflight(estadoCompleto);
    expect(steps.map((s) => s.id)).toEqual(STEP_IDS);
    expect(steps).toHaveLength(4);
  });

  it('autoriza el flasheo solo cuando todos los pasos están completos', () => {
    const preflight = buildPreflight(estadoCompleto);
    expect(preflight.canFlash).toBe(true);
    expect(preflight.blockers).toEqual([]);
    expect(preflight.steps.every((s) => s.state === 'complete')).toBe(true);
  });

  it('bloquea sin imagen y lo dice de forma accionable', () => {
    const preflight = buildPreflight({ ...estadoCompleto, image: null, bundle: null });
    expect(preflight.canFlash).toBe(false);
    expect(preflight.blockers[0]).toMatch(/imagen/i);
    expect(preflight.steps[0].state).toBe('active');
  });

  it('bloquea cuando el bundle no se pudo resolver y muestra el motivo del backend', () => {
    const preflight = buildPreflight({
      ...estadoCompleto,
      bundle: null,
      bundleError: 'No existe ningún repositorio APT offline construido junto a su payload.',
    });
    expect(preflight.canFlash).toBe(false);
    expect(preflight.blockers).toContain(
      'No existe ningún repositorio APT offline construido junto a su payload.'
    );
    expect(preflight.steps[0].state).toBe('blocked');
  });

  it('bloquea sin dispositivo destino', () => {
    const preflight = buildPreflight({ ...estadoCompleto, device: null });
    expect(preflight.canFlash).toBe(false);
    expect(preflight.blockers.some((b) => /microSD|dispositivo|unidad/i.test(b))).toBe(true);
  });

  it('arrastra los errores de validación de la configuración', () => {
    const preflight = buildPreflight({
      ...estadoCompleto,
      config: { ...configValida, serialNumber: '', hostname: '-malo-' },
    });
    expect(preflight.canFlash).toBe(false);
    expect(preflight.blockers.length).toBeGreaterThanOrEqual(2);
    expect(preflight.steps[2].state).toBe('blocked');
  });

  it('bloquea sin credencial de enrolamiento: el equipo no podría enrolarse', () => {
    const preflight = buildPreflight({
      ...estadoCompleto,
      config: { ...configValida, apiKey: undefined },
    });
    expect(preflight.canFlash).toBe(false);
    expect(preflight.blockers.some((b) => /credencial/i.test(b))).toBe(true);
    expect(preflight.steps[3].state).toBe('active');
  });

  it('bloquea mientras hay un flasheo en curso', () => {
    const preflight = buildPreflight({ ...estadoCompleto, flashing: true });
    expect(preflight.canFlash).toBe(false);
  });

  // Una ARM1176 no ejecuta aarch64. Antes esto producía una tarjeta muda y el
  // flasheo anunciaba éxito; ahora se bloquea antes de escribir nada.
  it('bloquea una placa que no puede arrancar la arquitectura de la imagen', () => {
    const preflight = buildPreflight({
      ...estadoCompleto,
      config: { ...configValida, rpiModel: 'raspberry-pi-zero-w' },
    });
    expect(preflight.canFlash).toBe(false);
    expect(preflight.blockers.some((b) => /no arranca imágenes arm64/i.test(b))).toBe(true);
    expect(preflight.steps.find((s) => s.id === 'image')?.state).toBe('blocked');
  });

  it('acepta las placas que sí admiten la arquitectura de la imagen', () => {
    for (const rpiModel of ['raspberry-pi-5', 'raspberry-pi-4b', 'raspberry-pi-zero-2-w']) {
      const preflight = buildPreflight({
        ...estadoCompleto,
        config: { ...configValida, rpiModel },
      });
      expect(preflight.blockers.filter((b) => /no arranca imágenes/i.test(b))).toEqual([]);
    }
  });

  it('con una imagen armhf rechaza la Pi 5 y admite la Zero W', () => {
    const armhf = { ...bundle, architecture: 'armhf' };
    const pi5 = buildPreflight({
      ...estadoCompleto,
      bundle: armhf,
      config: { ...configValida, rpiModel: 'raspberry-pi-5' },
    });
    expect(pi5.blockers.some((b) => /no arranca imágenes armhf/i.test(b))).toBe(true);

    const zero = buildPreflight({
      ...estadoCompleto,
      bundle: armhf,
      config: { ...configValida, rpiModel: 'raspberry-pi-zero-w' },
    });
    expect(zero.blockers.filter((b) => /no arranca imágenes/i.test(b))).toEqual([]);
  });

  // Avisar de algo que el operario no puede cambiar no es un aviso: es ruido
  // en cada fabricación, y enseña a ignorar los avisos que sí importan.
  it('no avisa de la MAC, que esta estación nunca puede conocer', () => {
    const preflight = buildPreflight(estadoCompleto);
    expect(preflight.canFlash).toBe(true);
    expect(preflight.warnings.some((w) => /MAC/i.test(w))).toBe(false);
  });

  it('el primer bloqueo es el que el operario debe resolver primero', () => {
    const preflight = buildPreflight({
      ...estadoCompleto,
      image: null,
      bundle: null,
      device: null,
      config: { ...configValida, serialNumber: '' },
    });
    expect(preflight.blockers[0]).toMatch(/imagen/i);
  });
});
