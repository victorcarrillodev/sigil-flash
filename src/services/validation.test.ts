import { describe, expect, it } from 'vitest';
import {
  normalizeMac,
  validateConfigLocally,
  validateHostname,
  validatePanelPin,
  validatePassword,
  validateSerialNumber,
  validateServerUrl,
  validateWifi,
} from './validation';
import { DeviceConfig } from '../types/models';

/**
 * Estas reglas son un espejo de services/config.rs. Si divergen, el operario
 * ve un formulario en verde y el proceso elevado aborta veinte minutos
 * después: cada caso de aquí tiene su gemelo en las pruebas de Rust.
 */

describe('validateHostname', () => {
  it('acepta un hostname válido', () => {
    expect(validateHostname('sigil-device')).toBeNull();
    expect(validateHostname('a')).toBeNull();
    expect(validateHostname('a'.repeat(63))).toBeNull();
  });

  it('rechaza los límites y los caracteres prohibidos', () => {
    expect(validateHostname('')).toMatch(/1 y 63/);
    expect(validateHostname('a'.repeat(64))).toMatch(/1 y 63/);
    expect(validateHostname('-malo')).toMatch(/guion/);
    expect(validateHostname('malo-')).toMatch(/guion/);
    expect(validateHostname('con_guion_bajo')).toMatch(/alfanuméricos/);
    expect(validateHostname('con espacio')).toMatch(/alfanuméricos/);
  });
});

describe('validatePanelPin', () => {
  it('acepta un PIN sin patrón', () => {
    expect(validatePanelPin('847392')).toBeNull();
  });

  it('rechaza longitud, no numérico, repetido, ascendente y descendente', () => {
    expect(validatePanelPin('12345')).toMatch(/6 y 12/);
    expect(validatePanelPin('1'.repeat(13))).toMatch(/6 y 12/);
    expect(validatePanelPin('abcdef')).toMatch(/dígitos/);
    expect(validatePanelPin('111111')).toMatch(/repetidos/);
    expect(validatePanelPin('123456')).toMatch(/ascendente/);
    expect(validatePanelPin('654321')).toMatch(/descendente/);
  });

  it('rechaza espacios accidentales en vez de recortarlos', () => {
    expect(validatePanelPin(' 847392')).toMatch(/espacios/);
    expect(validatePanelPin('847392 ')).toMatch(/espacios/);
    expect(validatePanelPin('847 392')).toMatch(/espacios/);
  });
});

describe('validatePassword', () => {
  it('acepta y rechaza en sus límites exactos', () => {
    expect(validatePassword('a'.repeat(5))).toMatch(/6 y 128/);
    expect(validatePassword('a'.repeat(6))).toBeNull();
    expect(validatePassword('a'.repeat(128))).toBeNull();
    expect(validatePassword('a'.repeat(129))).toMatch(/6 y 128/);
  });

  it('rechaza saltos de línea y nulos', () => {
    expect(validatePassword('con\nsalto')).toMatch(/saltos de línea/);
    expect(validatePassword('con\rretorno')).toMatch(/saltos de línea/);
    expect(validatePassword('con\0nulo')).toMatch(/saltos de línea/);
  });
});

describe('validateSerialNumber', () => {
  it('acepta el juego de caracteres del contrato', () => {
    expect(validateSerialNumber('SN-2026_0001.A')).toBeNull();
  });

  it('rechaza vacío, exceso y caracteres fuera del juego', () => {
    expect(validateSerialNumber('')).toMatch(/1 y 64/);
    expect(validateSerialNumber('a'.repeat(65))).toMatch(/1 y 64/);
    expect(validateSerialNumber('con espacio')).toMatch(/\[A-Za-z0-9._-\]/);
    expect(validateSerialNumber('con/barra')).toMatch(/\[A-Za-z0-9._-\]/);
  });
});

describe('normalizeMac', () => {
  it('normaliza a minúsculas con dos puntos', () => {
    expect(normalizeMac('AA-BB-CC-DD-EE-FF')).toBe('aa:bb:cc:dd:ee:ff');
    expect(normalizeMac('00:11:22:33:44:55')).toBe('00:11:22:33:44:55');
    expect(normalizeMac('  AA:bb:CC:dd:EE:ff  ')).toBe('aa:bb:cc:dd:ee:ff');
  });

  it('rechaza una MAC mal tecleada', () => {
    expect(normalizeMac('invalid-mac')).toBeNull();
    expect(normalizeMac('00:11:22:33:44')).toBeNull();
    expect(normalizeMac('00:11:22:33:44:ZZ')).toBeNull();
    expect(normalizeMac('001122334455')).toBeNull();
  });
});

describe('validateWifi', () => {
  it('exige ambos valores o ninguno', () => {
    expect(validateWifi(null, null)).toBeNull();
    expect(validateWifi('MiRed', 'clave-larga')).toBeNull();
    expect(validateWifi('MiRed', null)).toMatch(/falta la contraseña/);
    expect(validateWifi(null, 'clave-larga')).toMatch(/falta el SSID/);
  });

  it('respeta los límites de SSID y clave', () => {
    expect(validateWifi('a'.repeat(33), 'clave-larga')).toMatch(/1 y 32/);
    expect(validateWifi('MiRed', 'corta')).toMatch(/8 y 63/);
    expect(validateWifi('MiRed', 'a'.repeat(64))).toMatch(/8 y 63/);
  });
});

describe('validateServerUrl', () => {
  it('exige HTTPS porque por ahí viajan los secretos', () => {
    expect(validateServerUrl('https://sigil.example')).toBeNull();
    expect(validateServerUrl('http://sigil.example')).toMatch(/HTTPS/);
    expect(validateServerUrl('ftp://sigil.example')).toMatch(/HTTPS/);
  });
});

describe('validateConfigLocally', () => {
  const base: DeviceConfig = {
    hostname: 'sigil-device',
    username: 'sigil',
    serialNumber: 'SN-2026-0001',
    sshEnabled: false,
    rpiModel: 'raspberry-pi-zero-2-w',
    serverUrl: 'https://sigil.example',
  };

  it('no encuentra nada que objetar en una configuración válida', () => {
    expect(validateConfigLocally(base)).toEqual([]);
  });

  it('defiende el usuario canónico del producto', () => {
    const errores = validateConfigLocally({ ...base, username: 'pi' });
    expect(errores.some((e) => /sigil/.test(e))).toBe(true);
  });

  it('exige contraseña cuando el acceso remoto está activo', () => {
    const errores = validateConfigLocally({ ...base, sshEnabled: true });
    expect(errores.some((e) => /obligatoria/.test(e))).toBe(true);
    expect(validateConfigLocally({ ...base, sshEnabled: true, password: 'valida123' })).toEqual([]);
  });

  it('rechaza un modelo de placa fuera de la lista cerrada', () => {
    const errores = validateConfigLocally({ ...base, rpiModel: 'raspberry-pi-pico' });
    expect(errores.some((e) => /no soportado/.test(e))).toBe(true);
  });

  it('acumula todos los problemas, no solo el primero', () => {
    const errores = validateConfigLocally({
      ...base,
      hostname: '-malo-',
      serialNumber: '',
      panelPin: '111111',
    });
    expect(errores.length).toBeGreaterThanOrEqual(3);
  });
});
