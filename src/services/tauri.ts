import { invoke } from '@tauri-apps/api/core';
import { listen, UnlistenFn } from '@tauri-apps/api/event';
import { BundlePair, Device, DeviceConfig, FlashProgress, ImageInfo } from '../types/models';

export const PROGRESS_EVENT = 'flash-progress';

export async function listDevices(): Promise<Device[]> {
  return invoke<Device[]>('list_devices');
}

export async function refreshDevices(): Promise<Device[]> {
  return invoke<Device[]>('refresh_devices');
}

export async function selectImage(path: string): Promise<ImageInfo> {
  return invoke<ImageInfo>('select_image', { path });
}

/** Diálogo nativo del sistema: en Tauri el navegador no da rutas reales. */
export async function pickImageFile(): Promise<string | null> {
  const { open } = await import('@tauri-apps/plugin-dialog');
  const selected = await open({
    multiple: false,
    directory: false,
    filters: [{ name: 'Imagen de Raspberry Pi OS', extensions: ['img', 'xz'] }],
  });
  return typeof selected === 'string' ? selected : null;
}

export async function verifySha256(path: string, expectedSha256: string): Promise<boolean> {
  return invoke<boolean>('verify_sha256', { path, expectedSha256 });
}

export async function validateConfig(config: DeviceConfig): Promise<boolean> {
  return invoke<boolean>('validate_config', { config });
}

/** Resuelve el par bundle/payload de una imagen antes de escribir un solo byte. */
export async function resolveBundle(imageName: string, variant?: string): Promise<BundlePair> {
  return invoke<BundlePair>('resolve_bundle_for_image', { imageName, variant: variant ?? null });
}

export async function getBundleStatus(variant?: string): Promise<string> {
  return invoke<string>('get_bundle_status', { variant: variant ?? null });
}

export async function rebuildPayloads(): Promise<string> {
  return invoke<string>('rebuild_payloads_cmd');
}

export async function startFlash(
  srcImage: string,
  destDevice: string,
  config: DeviceConfig,
  variant?: string
): Promise<FlashProgress> {
  return invoke<FlashProgress>('start_flash', {
    srcImage,
    destDevice,
    config,
    variant: variant ?? null,
  });
}

export async function cancelFlash(): Promise<boolean> {
  return invoke<boolean>('cancel_flash');
}

export async function getFlashProgress(): Promise<FlashProgress | null> {
  return invoke<FlashProgress | null>('get_flash_progress');
}

/** El proceso elevado publica su estado y la GUI lo reemite como evento. */
export async function onFlashProgress(
  handler: (progress: FlashProgress) => void
): Promise<UnlistenFn> {
  return listen<FlashProgress>(PROGRESS_EVENT, (event) => handler(event.payload));
}

/** La contraseña de fábrica sale del keyring del sistema: nunca viaja por aquí. */
/** Cuentas de fábrica con contraseña guardada en este PC. Solo los nombres. */
export async function listFactoryAccounts(): Promise<string[]> {
  return invoke<string[]>('list_factory_accounts');
}

export async function loginFactory(serverUrl: string, username: string): Promise<string> {
  return invoke<string>('login_factory', { serverUrl, username });
}

export async function requestEnrollment(
  serverUrl: string,
  sessionToken: string,
  deviceId?: string,
  serialNumber?: string
): Promise<string> {
  return invoke<string>('request_enrollment', {
    serverUrl,
    sessionToken,
    deviceId: deviceId ?? null,
    serialNumber: serialNumber ?? null,
  });
}

export async function getEngineStatus(): Promise<Record<string, unknown>> {
  return invoke<Record<string, unknown>>('get_engine_status');
}

/** Diálogo nativo de guardar: como en pickImageFile, el webview no ofrece
 *  rutas reales del sistema de archivos. Devuelve null si el operario
 *  cancela, nunca una cadena vacía. */
export async function saveFileDialog(
  defaultName: string,
  filters: { name: string; extensions: string[] }[]
): Promise<string | null> {
  const { save } = await import('@tauri-apps/plugin-dialog');
  const path = await save({ defaultPath: defaultName, filters });
  return path ?? null;
}

export async function openFileDialog(
  filters: { name: string; extensions: string[] }[]
): Promise<string | null> {
  const { open } = await import('@tauri-apps/plugin-dialog');
  const selected = await open({ multiple: false, directory: false, filters });
  return typeof selected === 'string' ? selected : null;
}

export async function writeTextFile(path: string, contents: string): Promise<void> {
  return invoke<void>('write_text_file', { path, contents });
}

export async function readTextFile(path: string): Promise<string> {
  return invoke<string>('read_text_file', { path });
}

/** El libro Excel se arma en Rust: SheetJS (el único lector/escritor de xlsx
 *  maduro en npm) no tiene parche publicado ahí para su vulnerabilidad de
 *  contaminación de prototipos ni la de ReDoS. `rows` incluye la cabecera. */
export async function exportHistoryXlsx(path: string, rows: string[][]): Promise<void> {
  return invoke<void>('export_xlsx', { path, rows });
}

export async function importHistoryXlsx(path: string): Promise<string[][]> {
  return invoke<string[][]>('import_xlsx', { path });
}
