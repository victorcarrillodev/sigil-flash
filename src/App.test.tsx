import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from './App';
import { BundlePair, Device, FlashProgress, ImageInfo } from './types/models';

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
}));

import {
  listFactoryAccounts,
  loginFactory,
  onFlashProgress,
  refreshDevices,
  requestEnrollment,
  resolveBundle,
  selectImage,
  startFlash,
  validateConfig,
} from './services/tauri';

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
});
