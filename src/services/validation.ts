import { DeviceConfig } from '../types/models';

/**
 * Primera de las tres validaciones. Las mismas reglas viven en el backend de
 * la GUI y en el proceso elevado: los dos lados de la frontera de privilegio
 * no se confían mutuamente, así que la redundancia es deliberada.
 */

export const CANONICAL_USERNAME = 'sigil';

/** Modelos con Linux. Los microcontroladores se rechazan aquí. */
export const SUPPORTED_MODELS = [
  'raspberry-pi-5',
  'raspberry-pi-4b',
  'raspberry-pi-3b-plus',
  'raspberry-pi-3b',
  'raspberry-pi-zero-2-w',
  'raspberry-pi-zero-w',
  'raspberry-pi-1',
] as const;

/**
 * Arquitecturas de imagen que cada placa puede arrancar.
 *
 * Espejo de `architectures_for_board` en Rust. Se duplica a propósito: el
 * backend vuelve a comprobarlo y no confía en la interfaz, pero el operario
 * merece saberlo antes de empezar y no al pulsar fabricar. Una ARM1176 no
 * ejecuta aarch64; la Pi 5 no tiene kernel de 32 bits publicado.
 */
export const ARCHITECTURES_BY_MODEL: Record<string, readonly string[]> = {
  'raspberry-pi-5': ['arm64'],
  'raspberry-pi-4b': ['arm64', 'armhf'],
  'raspberry-pi-3b-plus': ['arm64', 'armhf'],
  'raspberry-pi-3b': ['arm64', 'armhf'],
  'raspberry-pi-zero-2-w': ['arm64', 'armhf'],
  'raspberry-pi-zero-w': ['armhf'],
  'raspberry-pi-1': ['armhf'],
};

export function validateModelArchitecture(
  model?: string | null,
  architecture?: string | null
): string | null {
  if (!model || !architecture) return null;
  const allowed = ARCHITECTURES_BY_MODEL[model];
  if (!allowed || allowed.includes(architecture)) return null;
  return `El modelo ${model} no arranca imágenes ${architecture}: necesita ${allowed.join(
    ' o '
  )}. Elija la imagen que corresponde a esta placa.`;
}

export function validateHostname(hostname: string): string | null {
  if (hostname.length < 1 || hostname.length > 63) {
    return 'El hostname debe tener entre 1 y 63 caracteres';
  }
  if (hostname.startsWith('-') || hostname.endsWith('-')) {
    return 'El hostname no puede comenzar ni terminar con guion';
  }
  if (!/^[A-Za-z0-9-]+$/.test(hostname)) {
    return 'El hostname solo permite caracteres alfanuméricos y guiones';
  }
  return null;
}

export function validatePanelPin(pin: string): string | null {
  if (/\s/.test(pin)) {
    return 'El PIN del panel no puede contener espacios';
  }
  if (pin.length < 6 || pin.length > 12) {
    return 'El PIN del panel debe tener entre 6 y 12 dígitos';
  }
  if (!/^[0-9]+$/.test(pin)) {
    return 'El PIN del panel debe contener únicamente dígitos';
  }

  const digits = [...pin].map(Number);
  if (digits.every((d) => d === digits[0])) {
    return 'El PIN no puede ser una serie de dígitos repetidos';
  }
  if (digits.every((d, i) => i === 0 || d === (digits[i - 1] + 1) % 10)) {
    return 'El PIN no puede ser una secuencia ascendente continua';
  }
  if (digits.every((d, i) => i === 0 || digits[i - 1] === (d + 1) % 10)) {
    return 'El PIN no puede ser una secuencia descendente continua';
  }
  return null;
}

export function validatePassword(password: string): string | null {
  if (password.length < 6 || password.length > 128) {
    return 'La contraseña debe tener entre 6 y 128 caracteres';
  }
  if (/[\r\n\0]/.test(password)) {
    return 'La contraseña no puede contener saltos de línea ni caracteres nulos';
  }
  return null;
}

/** Genera una contraseña segura aleatoria de 14 caracteres con alta complejidad. */
export function generarContrasenaSegura(): string {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%&*';
  const randomArray = new Uint8Array(14);
  if (typeof window !== 'undefined' && window.crypto && window.crypto.getRandomValues) {
    window.crypto.getRandomValues(randomArray);
  } else {
    for (let i = 0; i < 14; i++) {
      randomArray[i] = Math.floor(Math.random() * 256);
    }
  }
  let pass = '';
  for (let i = 0; i < 14; i++) {
    pass += chars[randomArray[i] % chars.length];
  }
  return pass;
}

export function validateSerialNumber(serial: string): string | null {
  if (serial.length < 1 || serial.length > 64) {
    return 'El número de serie debe tener entre 1 y 64 caracteres';
  }
  if (!/^[A-Za-z0-9._-]+$/.test(serial)) {
    return 'El número de serie solo admite [A-Za-z0-9._-]';
  }
  return null;
}

export const CLAVE_CONTADOR_SERIE = 'sigil-flash.serial-counter';

export function obtenerContadorSerie(): number {
  try {
    const val = localStorage.getItem(CLAVE_CONTADOR_SERIE);
    if (val) {
      const num = parseInt(val, 10);
      if (!isNaN(num) && num > 0) return num;
    }
  } catch {
    // Entorno sin localStorage
  }
  return 1;
}

export function generarNumeroDeSerie(
  contador: number = obtenerContadorSerie(),
  fecha: Date = new Date()
): string {
  const contadorPadded = String(contador).padStart(6, '0');
  const mesPadded = String(fecha.getMonth() + 1).padStart(2, '0');
  const anoDosDigitos = String(fecha.getFullYear()).slice(-2);
  return `SIG-EMOD-${contadorPadded}-${mesPadded}${anoDosDigitos}`;
}

export function incrementarYObtenerSiguienteSerie(fecha: Date = new Date()): string {
  const actual = obtenerContadorSerie();
  const siguiente = actual + 1;
  try {
    localStorage.setItem(CLAVE_CONTADOR_SERIE, String(siguiente));
  } catch {
    // Fallback
  }
  return generarNumeroDeSerie(siguiente, fecha);
}

/**
 * Normaliza a minúsculas con ':' byte a byte igual que el servidor. Si esta
 * normalización difiere, una credencial ligada nunca podrá consumirse.
 *
 * La estación ya no pide la MAC —fabrica tarjetas para equipos que todavía no
 * existen, así que no puede conocerla— y emite credenciales sin ligar. Esto se
 * conserva para el día que la MAC llegue por otra vía (un lector de etiquetas,
 * un lote importado) y haya que volver a ligarlas.
 */
export function normalizeMac(mac: string): string | null {
  const cleaned = mac.trim().replace(/-/g, ':').toLowerCase();
  const parts = cleaned.split(':');
  if (parts.length !== 6) return null;
  if (!parts.every((p) => /^[0-9a-f]{2}$/.test(p))) return null;
  return cleaned;
}

export function validateWifi(ssid?: string | null, password?: string | null): string | null {
  const hasSsid = !!ssid && ssid.length > 0;
  const hasPassword = !!password && password.length > 0;

  if (!hasSsid && !hasPassword) return null;
  if (hasSsid && !hasPassword) return 'Se indicó SSID WiFi pero falta la contraseña';
  if (!hasSsid && hasPassword) return 'Se indicó contraseña WiFi pero falta el SSID';

  if (ssid!.trim().length < 1 || ssid!.trim().length > 32) {
    return 'El SSID debe tener entre 1 y 32 caracteres';
  }
  if (password!.length < 8 || password!.length > 63) {
    return 'La clave WiFi debe tener entre 8 y 63 caracteres';
  }
  return null;
}

export function validateServerUrl(url: string): string | null {
  if (url.startsWith('https://')) return null;
  return 'La URL del servidor debe usar HTTPS. http:// solo se admite en laboratorio con SIGIL_ALLOW_INSECURE_URL=1';
}

export function validateConfigLocally(config: DeviceConfig): string[] {
  const errors: string[] = [];
  const push = (e: string | null) => {
    if (e) errors.push(e);
  };

  push(validateHostname(config.hostname));

  if (config.username !== CANONICAL_USERNAME) {
    errors.push(`El usuario canónico del producto es '${CANONICAL_USERNAME}' y no puede cambiarse`);
  }

  if (!config.serialNumber) {
    errors.push('El número de serie es obligatorio');
  } else {
    push(validateSerialNumber(config.serialNumber));
  }

  if (config.sshEnabled) {
    if (!config.password) {
      errors.push('La contraseña es obligatoria cuando el acceso remoto está activo');
    } else {
      push(validatePassword(config.password));
    }
  } else if (config.password) {
    push(validatePassword(config.password));
  }

  if (config.panelPin) push(validatePanelPin(config.panelPin));

  if (config.rpiModel && !SUPPORTED_MODELS.includes(config.rpiModel as never)) {
    errors.push(`Modelo de placa no soportado: ${config.rpiModel}`);
  }

  push(validateWifi(config.wifiSsid, config.wifiPassword));

  if (config.serverUrl) push(validateServerUrl(config.serverUrl));

  return errors;
}
