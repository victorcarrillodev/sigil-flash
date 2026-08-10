import { invoke } from '@tauri-apps/api/core';
import { listen, UnlistenFn } from '@tauri-apps/api/event';

export const SSH_OUTPUT_EVENT = 'ssh-output';
export const SSH_EXIT_EVENT = 'ssh-exit';

export interface SshExitInfo {
  code: number | null;
  message: string;
}

export async function sshConnect(
  host: string,
  port: number,
  username: string,
  cols: number,
  rows: number
): Promise<void> {
  return invoke<void>('ssh_connect', { host, port, username, cols, rows });
}

/** Texto tecleado o pegado en la terminal: siempre UTF-8 válido porque sale
 *  de xterm.js, así que viaja como string y no como bytes. */
export async function sshWrite(data: string): Promise<void> {
  return invoke<void>('ssh_write', { data });
}

export async function sshResize(cols: number, rows: number): Promise<void> {
  return invoke<void>('ssh_resize', { cols, rows });
}

export async function sshDisconnect(): Promise<void> {
  return invoke<void>('ssh_disconnect');
}

export async function sshForgetHostKey(host: string, port: number): Promise<void> {
  return invoke<void>('ssh_forget_host_key', { host, port });
}

/** Salida cruda del pty: no se garantiza texto UTF-8 alineado a los cortes
 *  de lectura del lado Rust, así que viaja como bytes y es xterm.js —no este
 *  módulo— quien la decodifica con su propio parser de flujo UTF-8. */
export async function onSshOutput(handler: (bytes: Uint8Array) => void): Promise<UnlistenFn> {
  return listen<number[]>(SSH_OUTPUT_EVENT, (event) => handler(new Uint8Array(event.payload)));
}

export async function onSshExit(handler: (info: SshExitInfo) => void): Promise<UnlistenFn> {
  return listen<SshExitInfo>(SSH_EXIT_EVENT, (event) => handler(event.payload));
}
