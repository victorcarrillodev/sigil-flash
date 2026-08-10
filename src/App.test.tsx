import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from './App';
import { BundlePair, Device, DeviceConfig, FlashProgress, ImageInfo } from './types/models';
import { agregarEntradaHistorial, CLAVE_HISTORIAL, construirEntradaHistorial } from './services/history';

vi.mock('./services/tauri', () => ({
  listDevices: vi.fn(),
  refreshDevices: vi.fn(),
  selectImage: vi.fn(),
  pickImageFile: vi.fn(),
  verifySha256: vi.fn(),
  validateConfig: vi.fn(),
  resolveBundle: vi.fn(),
  getBundleStatus: vi.fn(),
  rebuildPayloads: vi.fn(),
  startFlash: vi.fn(),
  cancelFlash: vi.fn(),
  getFlashProgress: vi.fn(),
  onFlashProgress: vi.fn(),
  listFactoryAccounts: vi.fn(),
  loginFactory: vi.fn(),
  requestEnrollment: vi.fn(),
  getEngineStatus: vi.fn(),
  saveFileDialog: vi.fn(),
  openFileDialog: vi.fn(),
  writeTextFile: vi.fn(),
  readTextFile: vi.fn(),
  exportHistoryXlsx: vi.fn(),
  importHistoryXlsx: vi.fn(),
}));

// La vista SSH vive montada todo el tiempo (para no perder el scrollback del
// terminal al cambiar de pestaña), así que su efecto de suscripción corre en
// cada test, incluso los que no tocan SSH para nada. Sin este mock, esas
// suscripciones invocarían el `listen()` real de Tauri fuera de un runtime
// de Tauri y tirarían cada test abajo con un rechazo sin capturar.
vi.mock('./services/ssh', () => ({
  sshConnect: vi.fn(),
  sshWrite: vi.fn(),
  sshResize: vi.fn(),
  sshDisconnect: vi.fn(),
  sshForgetHostKey: vi.fn(),
  onSshOutput: vi.fn(async () => () => {}),
  onSshExit: vi.fn(async () => () => {}),
}));

import {
  importHistoryXlsx,
  listFactoryAccounts,
  loginFactory,
  onFlashProgress,
  openFileDialog,
  readTextFile,
  refreshDevices,
  requestEnrollment,
  resolveBundle,
  saveFileDialog,
  selectImage,
  startFlash,
  validateConfig,
  writeTextFile,
} from './services/tauri';
import { rowsToCsv, entriesToRows } from './services/historyIO';
import { sshConnect } from './services/ssh';

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

let emitirProgreso: (p: FlashProgress) => void = () => {};

beforeEach(() => {
  // La cuenta de fábrica persiste entre arranques: sin limpiar, una prueba
  // dejaría la suya puesta en la siguiente.
  localStorage.clear();
  vi.mocked(listFactoryAccounts).mockResolvedValue([]);
  vi.mocked(onFlashProgress).mockImplementation(async (handler) => {
    emitirProgreso = handler;
    return () => {};
  });
  vi.mocked(refreshDevices).mockResolvedValue([dispositivo]);
  vi.mocked(resolveBundle).mockResolvedValue(bundle);
  vi.mocked(selectImage).mockResolvedValue(imagen);
  vi.mocked(validateConfig).mockResolvedValue(true);
  vi.mocked(loginFactory).mockResolvedValue('token-de-sesion');
  vi.mocked(requestEnrollment).mockResolvedValue('clave-de-un-solo-uso');
  vi.mocked(startFlash).mockResolvedValue({
    bytes_written: 100,
    total_bytes: 100,
    speed_mbps: 0,
    eta_seconds: 0,
    status: 'done',
    message: 'Flasheo, instalación y provisión completados exitosamente',
  });
});

describe('App', () => {
  it('arranca con la fabricación bloqueada y dice qué falta primero', async () => {
    render(<App />);
    const boton = await screen.findByRole('button', { name: /iniciar fabricación/i });
    expect(boton).toBeDisabled();
    expect(screen.getByTestId('blocking-reason')).toHaveTextContent(/imagen/i);
  });

  it('se suscribe a los eventos de progreso del proceso elevado', async () => {
    render(<App />);
    await waitFor(() => expect(onFlashProgress).toHaveBeenCalled());
  });

  it('refleja en vivo el progreso que publica el escritor', async () => {
    render(<App />);
    await waitFor(() => expect(onFlashProgress).toHaveBeenCalled());

    emitirProgreso({
      bytes_written: 256 * 1024 * 1024,
      total_bytes: 1024 * 1024 * 1024,
      speed_mbps: 30,
      eta_seconds: 60,
      status: 'running',
      message: 'Escribiendo imagen descomprimida...',
    });

    const barra = await screen.findByRole('progressbar');
    expect(barra).toHaveAttribute('aria-valuenow', '25');
    expect(screen.getByRole('status')).toHaveTextContent(/escribiendo imagen/i);
  });

  it('nunca usa alert() del navegador para los errores', async () => {
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    vi.mocked(resolveBundle).mockRejectedValue('No hay bundle para esa arquitectura');

    render(<App />);
    await waitFor(() => expect(onFlashProgress).toHaveBeenCalled());
    expect(alertSpy).not.toHaveBeenCalled();
    alertSpy.mockRestore();
  });

  it('el motivo de bloqueo se anuncia como región viva', async () => {
    render(<App />);
    const motivo = await screen.findByTestId('blocking-reason');
    expect(motivo).toHaveAttribute('role', 'status');
  });

  it('la aplicación se identifica y declara el entorno', async () => {
    render(<App />);
    expect(await screen.findByRole('banner')).toHaveTextContent(/SIGIL Flash/);
    expect(screen.getByRole('banner')).toHaveTextContent(/fabricación/i);
  });

  it('presenta los cuatro pasos de fabricación', async () => {
    render(<App />);
    const nav = await screen.findByRole('navigation', { name: /pasos/i });
    expect(nav).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /imagen/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /credencial/i })).toBeInTheDocument();
  });

  // El usuario del dispositivo lo crea el instalador; el servidor no lo conoce.
  // Ofrecerlo como cuenta de fábrica sólo produce un 401 que el operario no
  // puede diagnosticar, porque el propio panel le ofrece guardar la contraseña
  // bajo ese nombre equivocado.
  it('la cuenta de fábrica no arranca con el usuario del dispositivo', async () => {
    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    const campo = screen.getByLabelText(/cuenta de fábrica/i);
    expect(campo).not.toHaveValue('sigil');
    expect(campo).toHaveValue('fabrica');
  });

  // Un nombre que este PC no tiene guardado produce un error que parece del
  // servidor. Si el keyring tiene exactamente una cuenta, esa es la respuesta.
  it('adopta la única cuenta que el keyring tiene guardada', async () => {
    vi.mocked(listFactoryAccounts).mockResolvedValue(['fabrica@sigil.local']);

    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    await waitFor(() =>
      expect(screen.getByLabelText(/cuenta de fábrica/i)).toHaveValue('fabrica@sigil.local')
    );
  });

  it('con varias cuentas guardadas no adivina cuál toca', async () => {
    vi.mocked(listFactoryAccounts).mockResolvedValue(['fabrica@sigil.local', 'operario']);

    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    expect(screen.getByLabelText(/cuenta de fábrica/i)).toHaveValue('fabrica');
  });

  it('la elección del operario gana sobre lo que diga el keyring', async () => {
    localStorage.setItem('sigil-flash.factory-account', 'operario-elegido');
    vi.mocked(listFactoryAccounts).mockResolvedValue(['fabrica@sigil.local']);

    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    expect(screen.getByLabelText(/cuenta de fábrica/i)).toHaveValue('operario-elegido');
    expect(listFactoryAccounts).not.toHaveBeenCalled();
  });

  it('un keyring que no responde no impide teclear la cuenta', async () => {
    vi.mocked(listFactoryAccounts).mockRejectedValue(new Error('keyring bloqueado'));

    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    const campo = screen.getByLabelText(/cuenta de fábrica/i);
    expect(campo).toHaveValue('fabrica');
    await userEvent.clear(campo);
    await userEvent.type(campo, 'a-mano');
    expect(campo).toHaveValue('a-mano');
  });

  it('la cuenta de fábrica sobrevive al reinicio de la estación', async () => {
    const { unmount } = render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    const campo = screen.getByLabelText(/cuenta de fábrica/i);
    await userEvent.clear(campo);
    await userEvent.type(campo, 'fabrica@sigil.local');
    unmount();

    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));
    expect(screen.getByLabelText(/cuenta de fábrica/i)).toHaveValue('fabrica@sigil.local');
  });

  it('un almacenamiento inutilizable no impide fabricar', async () => {
    const getItem = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('almacenamiento bloqueado');
    });
    const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('almacenamiento bloqueado');
    });

    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /credencial/i }));

    const campo = screen.getByLabelText(/cuenta de fábrica/i);
    expect(campo).toHaveValue('fabrica');
    await userEvent.clear(campo);
    await userEvent.type(campo, 'otra-cuenta');
    expect(campo).toHaveValue('otra-cuenta');

    getItem.mockRestore();
    setItem.mockRestore();
  });

  describe('historial de fabricaciones', () => {
    const configFabricado: DeviceConfig = {
      hostname: 'sigil-device-07',
      username: 'sigil',
      sshEnabled: true,
      rpiModel: 'raspberry-pi-zero-2-w',
      serialNumber: 'SIG-EMOD-000007-0826',
      serverUrl: 'https://sigil-server.sphinx-pickerel.ts.net',
    };

    it('arranca en la vista de flasheo con el historial vacío', async () => {
      render(<App />);
      const tabHistorial = await screen.findByRole('tab', { name: /historial/i });
      expect(screen.getByRole('tab', { name: /flasheo/i })).toHaveAttribute('aria-selected', 'true');
      expect(tabHistorial).toHaveAttribute('aria-selected', 'false');
      expect(tabHistorial).toHaveTextContent('0');

      await userEvent.click(tabHistorial);
      expect(
        await screen.findByText(/todavía no se ha completado ninguna fabricación/i)
      ).toBeInTheDocument();
    });

    it('muestra en el historial una fabricación ya registrada, sin secretos', async () => {
      const entrada = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: { ...configFabricado, password: 'super-secreta', apiKey: 'clave-de-un-solo-uso' },
        progress: {
          bytes_written: imagen.size,
          total_bytes: imagen.size,
          speed_mbps: 40,
          eta_seconds: 0,
          status: 'done',
          message: 'Flasheo, instalación y provisión completados exitosamente',
        },
      });
      localStorage.setItem(CLAVE_HISTORIAL, JSON.stringify(agregarEntradaHistorial([], entrada)));

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /historial/i }));

      // Con la vista SSH montada de fondo (ver App.tsx), el mismo hostname
      // puede aparecer también como sugerencia ahí: las búsquedas de texto
      // de este bloque se acotan a la región del historial a propósito.
      const historial = await screen.findByRole('region', { name: /historial de fabricaciones/i });
      expect(await within(historial).findByText('sigil-device-07')).toBeInTheDocument();
      expect(within(historial).getByText('SIG-EMOD-000007-0826')).toBeInTheDocument();
      expect(within(historial).getByText(imagen.name)).toBeInTheDocument();
      expect(within(historial).getByText('Completado')).toBeInTheDocument();
      expect(screen.queryByText(/super-secreta/)).not.toBeInTheDocument();
      expect(screen.queryByText(/clave-de-un-solo-uso/)).not.toBeInTheDocument();

      // Volver a Flasheo restaura el flujo de trabajo normal.
      await userEvent.click(screen.getByRole('tab', { name: /flasheo/i }));
      expect(await screen.findByRole('button', { name: /iniciar fabricación/i })).toBeInTheDocument();
    });

    const progresoOk: FlashProgress = {
      bytes_written: imagen.size,
      total_bytes: imagen.size,
      speed_mbps: 40,
      eta_seconds: 0,
      status: 'done',
      message: 'Flasheo, instalación y provisión completados exitosamente',
    };

    it('los botones de exportar están deshabilitados sin historial, importar no', async () => {
      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /historial/i }));

      expect(screen.getByRole('button', { name: /exportar csv/i })).toBeDisabled();
      expect(screen.getByRole('button', { name: /exportar excel/i })).toBeDisabled();
      expect(screen.getByRole('button', { name: /importar/i })).toBeEnabled();
    });

    it('exporta el historial a CSV en la ruta que elige el operario', async () => {
      const entrada = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: configFabricado,
        progress: progresoOk,
      });
      localStorage.setItem(CLAVE_HISTORIAL, JSON.stringify(agregarEntradaHistorial([], entrada)));
      vi.mocked(saveFileDialog).mockResolvedValue('/home/operario/historial.csv');

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /historial/i }));
      await userEvent.click(screen.getByRole('button', { name: /exportar csv/i }));

      await waitFor(() => expect(writeTextFile).toHaveBeenCalledTimes(1));
      const [path, contenido] = vi.mocked(writeTextFile).mock.calls[0];
      expect(path).toBe('/home/operario/historial.csv');
      expect(contenido).toBe(rowsToCsv(entriesToRows([entrada])));
    });

    it('cancelar el diálogo de guardar no escribe ningún archivo', async () => {
      const entrada = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: configFabricado,
        progress: progresoOk,
      });
      localStorage.setItem(CLAVE_HISTORIAL, JSON.stringify(agregarEntradaHistorial([], entrada)));
      vi.mocked(saveFileDialog).mockResolvedValue(null);

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /historial/i }));
      await userEvent.click(screen.getByRole('button', { name: /exportar csv/i }));

      await waitFor(() => expect(saveFileDialog).toHaveBeenCalled());
      expect(writeTextFile).not.toHaveBeenCalled();
    });

    it('importa un CSV y lo fusiona con el historial existente', async () => {
      const existente = construirEntradaHistorial({
        startedAt: new Date(Date.now() - 60_000).toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: configFabricado,
        progress: progresoOk,
      });
      localStorage.setItem(CLAVE_HISTORIAL, JSON.stringify(agregarEntradaHistorial([], existente)));

      const importada = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: { ...configFabricado, hostname: 'sigil-device-99', serialNumber: 'SIG-EMOD-000099-0826' },
        progress: progresoOk,
      });
      vi.mocked(openFileDialog).mockResolvedValue('/home/operario/importado.csv');
      vi.mocked(readTextFile).mockResolvedValue(rowsToCsv(entriesToRows([importada])));

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /historial/i }));
      await userEvent.click(screen.getByRole('button', { name: /importar/i }));

      const historial = await screen.findByRole('region', { name: /historial de fabricaciones/i });
      expect(await within(historial).findByText('sigil-device-99')).toBeInTheDocument();
      expect(within(historial).getByText('sigil-device-07')).toBeInTheDocument();
      expect(screen.getByRole('tab', { name: /historial/i })).toHaveTextContent('2');
    });

    it('importa un .xlsx llamando al lector de Excel en vez de leer texto', async () => {
      const importada = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: configFabricado,
        progress: progresoOk,
      });
      vi.mocked(openFileDialog).mockResolvedValue('/home/operario/importado.xlsx');
      vi.mocked(importHistoryXlsx).mockResolvedValue(entriesToRows([importada]));

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /historial/i }));
      await userEvent.click(screen.getByRole('button', { name: /importar/i }));

      const historial = await screen.findByRole('region', { name: /historial de fabricaciones/i });
      expect(await within(historial).findByText('sigil-device-07')).toBeInTheDocument();
      expect(readTextFile).not.toHaveBeenCalled();
    });
  });

  describe('conexión SSH', () => {
    it('la pestaña SSH muestra el selector de dispositivo, sin nada guardado todavía', async () => {
      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /^ssh$/i }));

      const vista = await screen.findByRole('region', { name: /conexión ssh/i });
      expect(within(vista).getByText(/sin dispositivos guardados todavía/i)).toBeInTheDocument();
      expect(within(vista).getByLabelText(/host o ip/i)).toBeInTheDocument();
      expect(within(vista).getByLabelText(/^usuario$/i)).toBeInTheDocument();
      // Usuario canónico de los equipos que fabrica esta estación, precargado.
      expect(within(vista).getByLabelText(/^usuario$/i)).toHaveValue('sigil');
    });

    it('conectar desde el formulario manual llama a ssh_connect y guarda el destino', async () => {
      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /^ssh$/i }));
      const vista = await screen.findByRole('region', { name: /conexión ssh/i });

      await userEvent.type(within(vista).getByLabelText(/host o ip/i), '192.168.1.50');
      await userEvent.click(within(vista).getByRole('button', { name: /^conectar$/i }));

      await waitFor(() =>
        expect(sshConnect).toHaveBeenCalledWith('192.168.1.50', 22, 'sigil', expect.any(Number), expect.any(Number))
      );
      expect(await within(vista).findByText('192.168.1.50')).toBeInTheDocument();
    });

    it('una conexión fallida no deja el destino anterior pegado en la cabecera', async () => {
      vi.mocked(sshConnect).mockRejectedValueOnce(new Error('Connection refused'));

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /^ssh$/i }));
      const vista = await screen.findByRole('region', { name: /conexión ssh/i });

      await userEvent.type(within(vista).getByLabelText(/host o ip/i), '192.168.1.99');
      await userEvent.click(within(vista).getByRole('button', { name: /^conectar$/i }));

      await waitFor(() => expect(sshConnect).toHaveBeenCalled());
      expect(within(vista).getByText('Sin conectar')).toBeInTheDocument();
      expect(within(vista).queryByText(/192\.168\.1\.99/)).not.toBeInTheDocument();
    });

    it('sugiere dispositivos ya fabricados en esta estación y conecta a su nombre .local', async () => {
      const entrada = construirEntradaHistorial({
        startedAt: new Date().toISOString(),
        image: imagen,
        device: dispositivo,
        bundle,
        config: {
          hostname: 'sigil-device-12',
          username: 'sigil',
          sshEnabled: true,
          serialNumber: 'SIG-EMOD-000012-0826',
        },
        progress: {
          bytes_written: imagen.size,
          total_bytes: imagen.size,
          speed_mbps: 40,
          eta_seconds: 0,
          status: 'done',
          message: 'ok',
        },
      });
      localStorage.setItem(CLAVE_HISTORIAL, JSON.stringify(agregarEntradaHistorial([], entrada)));

      render(<App />);
      await userEvent.click(await screen.findByRole('tab', { name: /^ssh$/i }));
      const vista = await screen.findByRole('region', { name: /conexión ssh/i });

      const sugerencia = await within(vista).findByRole('button', { name: /sigil-device-12/i });
      await userEvent.click(sugerencia);

      await waitFor(() =>
        expect(sshConnect).toHaveBeenCalledWith(
          'sigil-device-12.local',
          22,
          'sigil',
          expect.any(Number),
          expect.any(Number)
        )
      );
    });
  });
});
