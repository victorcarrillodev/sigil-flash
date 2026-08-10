import { beforeEach, describe, expect, it } from 'vitest';
import {
  CLAVE_SSH_HOSTS,
  eliminarHost,
  generarIdHost,
  guardarHost,
  leerSshHosts,
  marcarConectado,
  sugerirHostsDesdeHistorial,
} from './sshHosts';
import { construirEntradaHistorial, FlashHistoryEntry } from './history';
import { BundlePair, Device, DeviceConfig, FlashProgress, ImageInfo } from '../types/models';

const imagen: ImageInfo = {
  path: '/artifacts/images/x.img.xz',
  name: 'x.img.xz',
  size: 100,
  sha256: null,
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
  contract_name: 'c',
  repo: '/r',
  payload: '/p',
  architecture: 'arm64',
  base_image_name: 'x.img.xz',
  base_image_sha256: 'a'.repeat(64),
};
const progreso: FlashProgress = {
  bytes_written: 100,
  total_bytes: 100,
  speed_mbps: 1,
  eta_seconds: 0,
  status: 'done',
  message: 'ok',
};

function entradaHistorial(hostname: string, overrides: Partial<DeviceConfig> = {}): FlashHistoryEntry {
  const config: DeviceConfig = {
    hostname,
    username: 'sigil',
    sshEnabled: true,
    rpiModel: 'raspberry-pi-zero-2-w',
    serialNumber: `SIG-${hostname}`,
    ...overrides,
  };
  return construirEntradaHistorial({
    startedAt: new Date().toISOString(),
    image: imagen,
    device: dispositivo,
    bundle,
    config,
    progress: progreso,
  });
}

beforeEach(() => {
  localStorage.clear();
});

describe('generarIdHost', () => {
  it('identifica el destino por usuario+host+puerto, sin distinguir mayúsculas en el host', () => {
    expect(generarIdHost('Sigil-Device-07.local', 22, 'sigil')).toBe(
      generarIdHost('sigil-device-07.local', 22, 'sigil')
    );
    expect(generarIdHost('a', 22, 'sigil')).not.toBe(generarIdHost('a', 2222, 'sigil'));
    expect(generarIdHost('a', 22, 'sigil')).not.toBe(generarIdHost('a', 22, 'root'));
  });
});

describe('guardarHost / leerSshHosts', () => {
  it('empieza vacío', () => {
    expect(leerSshHosts()).toEqual([]);
  });

  it('guarda y persiste', () => {
    const hosts = guardarHost([], { label: 'Banco 1', host: 'sigil-device-07.local', port: 22, username: 'sigil' });
    expect(hosts).toHaveLength(1);
    expect(leerSshHosts()).toEqual(hosts);
  });

  it('guardar el mismo destino dos veces actualiza en vez de duplicar', () => {
    let hosts = guardarHost([], { label: 'Viejo nombre', host: 'sigil-device-07.local', port: 22, username: 'sigil' });
    hosts = guardarHost(hosts, { label: 'Nuevo nombre', host: 'sigil-device-07.local', port: 22, username: 'sigil' });

    expect(hosts).toHaveLength(1);
    expect(hosts[0].label).toBe('Nuevo nombre');
  });

  it('sin etiqueta usa el host como nombre visible', () => {
    const hosts = guardarHost([], { label: '', host: 'sigil-device-07.local', port: 22, username: 'sigil' });
    expect(hosts[0].label).toBe('sigil-device-07.local');
  });

  it('un valor corrupto en localStorage no rompe la lectura', () => {
    localStorage.setItem(CLAVE_SSH_HOSTS, '{ no es json');
    expect(leerSshHosts()).toEqual([]);
  });
});

describe('marcarConectado', () => {
  it('sube el host conectado al frente y le pone fecha', () => {
    let hosts = guardarHost([], { label: 'A', host: 'a.local', port: 22, username: 'sigil' });
    hosts = guardarHost(hosts, { label: 'B', host: 'b.local', port: 22, username: 'sigil' });
    // B quedó primero por orden de inserción; conectar A debe subirlo.
    const idA = hosts.find((h) => h.host === 'a.local')!.id;

    hosts = marcarConectado(hosts, idA);

    expect(hosts[0].host).toBe('a.local');
    expect(hosts[0].lastConnectedAt).not.toBeNull();
  });

  it('un id inexistente no cambia nada', () => {
    const hosts = guardarHost([], { label: 'A', host: 'a.local', port: 22, username: 'sigil' });
    expect(marcarConectado(hosts, 'no-existe')).toEqual(hosts);
  });
});

describe('eliminarHost', () => {
  it('quita el host y persiste', () => {
    let hosts = guardarHost([], { label: 'A', host: 'a.local', port: 22, username: 'sigil' });
    const id = hosts[0].id;
    hosts = eliminarHost(hosts, id);
    expect(hosts).toHaveLength(0);
    expect(leerSshHosts()).toEqual([]);
  });
});

describe('sugerirHostsDesdeHistorial', () => {
  it('sugiere hostnames del historial, más recientes primero, sin repetir', () => {
    const entries = [entradaHistorial('sigil-device-02'), entradaHistorial('sigil-device-01')];
    const sugerencias = sugerirHostsDesdeHistorial(entries, []);

    expect(sugerencias.map((s) => s.host)).toEqual(['sigil-device-02', 'sigil-device-01']);
  });

  it('no repite un hostname que ya salió antes en el historial', () => {
    const entries = [entradaHistorial('sigil-device-01'), entradaHistorial('sigil-device-01')];
    const sugerencias = sugerirHostsDesdeHistorial(entries, []);
    expect(sugerencias).toHaveLength(1);
  });

  it('no sugiere un host que ya está guardado', () => {
    const guardados = guardarHost([], { label: '', host: 'sigil-device-01', port: 22, username: 'sigil' });
    const entries = [entradaHistorial('sigil-device-01'), entradaHistorial('sigil-device-02')];
    const sugerencias = sugerirHostsDesdeHistorial(entries, guardados);
    expect(sugerencias.map((s) => s.host)).toEqual(['sigil-device-02']);
  });

  it('entradas sin hostname no producen sugerencias vacías', () => {
    const entries = [entradaHistorial('')];
    expect(sugerirHostsDesdeHistorial(entries, [])).toEqual([]);
  });
});
