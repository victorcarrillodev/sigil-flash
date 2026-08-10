import { FlashHistoryEntry } from './history';

/**
 * Dispositivos SSH guardados por el operario — persistidos en localStorage,
 * mismo criterio que el resto del estado de estación de larga duración
 * (cuenta de fábrica, historial). Nunca guarda contraseña ni clave privada:
 * solo identifica el destino, la autenticación la resuelve ssh mismo
 * (agente, clave por defecto, o el prompt interactivo dentro de la propia
 * terminal).
 */
export interface SshHost {
  id: string;
  label: string;
  host: string;
  port: number;
  username: string;
  lastConnectedAt: string | null;
}

export const CLAVE_SSH_HOSTS = 'sigil-flash.ssh-hosts';

const MAX_SSH_HOSTS = 50;

export function generarIdHost(host: string, port: number, username: string): string {
  return `${username}@${host.toLowerCase()}:${port}`;
}

export function leerSshHosts(): SshHost[] {
  try {
    const raw = localStorage.getItem(CLAVE_SSH_HOSTS);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function guardarEnAlmacenamiento(hosts: SshHost[]): void {
  try {
    localStorage.setItem(CLAVE_SSH_HOSTS, JSON.stringify(hosts));
  } catch {
    // Sin almacenamiento persistente, la lista sigue funcionando en esta
    // sesión; solo no sobrevive al reinicio.
  }
}

/** Da de alta o actualiza un host, por `host+puerto+usuario`: guardar el
 *  mismo destino dos veces edita la entrada existente en vez de duplicarla. */
export function guardarHost(
  hosts: SshHost[],
  entrada: { label: string; host: string; port: number; username: string }
): SshHost[] {
  const id = generarIdHost(entrada.host, entrada.port, entrada.username);
  const previo = hosts.find((h) => h.id === id);
  const actualizado: SshHost = {
    id,
    label: entrada.label.trim() || entrada.host,
    host: entrada.host,
    port: entrada.port,
    username: entrada.username,
    lastConnectedAt: previo?.lastConnectedAt ?? null,
  };
  const next = [actualizado, ...hosts.filter((h) => h.id !== id)].slice(0, MAX_SSH_HOSTS);
  guardarEnAlmacenamiento(next);
  return next;
}

/** Sube el host al frente de la lista (más recientemente usado primero) y
 *  marca cuándo. */
export function marcarConectado(hosts: SshHost[], id: string): SshHost[] {
  const objetivo = hosts.find((h) => h.id === id);
  if (!objetivo) return hosts;
  const actualizado: SshHost = { ...objetivo, lastConnectedAt: new Date().toISOString() };
  const next = [actualizado, ...hosts.filter((h) => h.id !== id)];
  guardarEnAlmacenamiento(next);
  return next;
}

export function eliminarHost(hosts: SshHost[], id: string): SshHost[] {
  const next = hosts.filter((h) => h.id !== id);
  guardarEnAlmacenamiento(next);
  return next;
}

export interface SshSuggestion {
  host: string;
  serialNumber: string | null;
  rpiModel: string | null;
}

/** Candidatos a conectar que ya se fabricaron en esta estación, más
 *  recientes primero, sin repetir hostname y sin repetir lo que ya está
 *  guardado — así el operario no tiene que teclear a mano el nombre de un
 *  equipo que la propia app acaba de flashear. */
export function sugerirHostsDesdeHistorial(
  entries: FlashHistoryEntry[],
  guardados: SshHost[]
): SshSuggestion[] {
  const yaGuardados = new Set(guardados.map((h) => h.host.toLowerCase()));
  const vistos = new Set<string>();
  const sugerencias: SshSuggestion[] = [];

  for (const entry of entries) {
    const hostname = entry.config.hostname?.trim();
    if (!hostname) continue;
    const clave = hostname.toLowerCase();
    if (vistos.has(clave) || yaGuardados.has(clave)) continue;
    vistos.add(clave);
    sugerencias.push({
      host: hostname,
      serialNumber: entry.config.serialNumber,
      rpiModel: entry.config.rpiModel,
    });
  }

  return sugerencias;
}
