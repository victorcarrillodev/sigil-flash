import React from 'react';
import { DeviceConfig } from '../types/models';
import {
  SUPPORTED_MODELS,
  validateHostname,
  validatePanelPin,
  validatePassword,
  validateSerialNumber,
  validateServerUrl,
  validateWifi,
} from '../services/validation';

interface ConfigFormProps {
  config: DeviceConfig;
  onChange: (updated: DeviceConfig) => void;
  errors?: string[];
}

const MODEL_LABELS: Record<(typeof SUPPORTED_MODELS)[number], string> = {
  'raspberry-pi-5': 'Raspberry Pi 5 — 64 bits, PCIe',
  'raspberry-pi-4b': 'Raspberry Pi 4B — 64 bits',
  'raspberry-pi-3b-plus': 'Raspberry Pi 3B+ — 64 bits',
  'raspberry-pi-3b': 'Raspberry Pi 3B — 64 bits',
  'raspberry-pi-zero-2-w': 'Raspberry Pi Zero 2 W — 64 bits',
  'raspberry-pi-zero-w': 'Raspberry Pi Zero W — 32 bits',
  'raspberry-pi-1': 'Raspberry Pi 1 — 32 bits',
};

interface FieldProps {
  id: string;
  label: string;
  hint?: string;
  error?: string | null;
  children: (aria: { id: string; 'aria-invalid': boolean; 'aria-describedby'?: string }) => React.ReactNode;
}

/** Etiqueta, pista y error viajan juntos: un campo rojo sin texto no explica nada. */
const Field: React.FC<FieldProps> = ({ id, label, hint, error, children }) => {
  const hintId = hint ? `${id}-hint` : undefined;
  const errorId = error ? `${id}-error` : undefined;
  const describedBy = [errorId, hintId].filter(Boolean).join(' ') || undefined;

  return (
    <div className={`field${error ? ' field-invalid' : ''}`}>
      <label className="field-label" htmlFor={id}>
        {label}
      </label>
      {children({ id, 'aria-invalid': !!error, 'aria-describedby': describedBy })}
      {error && (
        <p className="field-error" id={errorId}>
          {error}
        </p>
      )}
      {hint && (
        <p className="field-hint" id={hintId}>
          {hint}
        </p>
      )}
    </div>
  );
};

export const ConfigForm: React.FC<ConfigFormProps> = ({ config, onChange }) => {
  const set = <K extends keyof DeviceConfig>(field: K, value: DeviceConfig[K]) =>
    onChange({ ...config, [field]: value });

  const serialError = config.serialNumber
    ? validateSerialNumber(config.serialNumber)
    : 'El número de serie es obligatorio';
  const hostnameError = validateHostname(config.hostname);
  const pinError = config.panelPin ? validatePanelPin(config.panelPin) : null;
  const passwordError = config.password ? validatePassword(config.password) : null;
  const wifiError = validateWifi(config.wifiSsid, config.wifiPassword);
  const urlError = config.serverUrl ? validateServerUrl(config.serverUrl) : null;

  return (
    <section className="panel">
      <div className="panel-head">
        <h2 className="panel-title">Configuración del dispositivo</h2>
      </div>

      <div className="field-grid">
        <Field
          id="cfg-serial"
          label="Número de serie"
          error={serialError}
          hint="Identifica la unidad fabricada. Viaja en el documento de identidad de la imagen."
        >
          {(aria) => (
            <input
              {...aria}
              className="input"
              type="text"
              value={config.serialNumber || ''}
              placeholder="SN-2026-0001"
              onChange={(e) => set('serialNumber', e.target.value)}
            />
          )}
        </Field>

        <Field id="cfg-hostname" label="Hostname del dispositivo" error={hostnameError}>
          {(aria) => (
            <input
              {...aria}
              className="input"
              type="text"
              value={config.hostname}
              onChange={(e) => set('hostname', e.target.value)}
            />
          )}
        </Field>

        <Field
          id="cfg-username"
          label="Usuario canónico del producto"
          hint="Lo fija system-config.json de sigil-hardware: no se puede cambiar."
        >
          {(aria) => (
            <input {...aria} className="input" type="text" value={config.username} disabled readOnly />
          )}
        </Field>

        <Field
          id="cfg-model"
          label="Modelo de placa"
          hint="Determina los ajustes de arranque escritos en la partición BOOT."
        >
          {(aria) => (
            <select
              {...aria}
              className="input"
              value={config.rpiModel || 'raspberry-pi-zero-2-w'}
              onChange={(e) => set('rpiModel', e.target.value)}
            >
              {SUPPORTED_MODELS.map((model) => (
                <option key={model} value={model}>
                  {MODEL_LABELS[model]}
                </option>
              ))}
            </select>
          )}
        </Field>

        <Field
          id="cfg-pin"
          label="PIN del panel (6–12 dígitos)"
          error={pinError}
          hint="Se deriva a hash Argon2id dentro de la imagen; el texto plano no sobrevive."
        >
          {(aria) => (
            <input
              {...aria}
              className="input"
              type="password"
              value={config.panelPin || ''}
              placeholder="847392"
              onChange={(e) => set('panelPin', e.target.value)}
            />
          )}
        </Field>

        <Field
          id="cfg-url"
          label="URL del servidor central"
          error={urlError}
          hint="Por esta conexión viajan la contraseña de fabricación y la credencial grabada."
        >
          {(aria) => (
            <input
              {...aria}
              className="input"
              type="text"
              value={config.serverUrl || ''}
              onChange={(e) => set('serverUrl', e.target.value)}
            />
          )}
        </Field>
      </div>

      <fieldset className="fieldset">
        <legend>Red inalámbrica (opcional)</legend>
        <div className="field-grid">
          <Field id="cfg-ssid" label="SSID de la red WiFi" error={wifiError}>
            {(aria) => (
              <input
                {...aria}
                className="input"
                type="text"
                value={config.wifiSsid || ''}
                onChange={(e) => set('wifiSsid', e.target.value)}
              />
            )}
          </Field>

          <Field id="cfg-wifi-pass" label="Contraseña WiFi">
            {(aria) => (
              <input
                {...aria}
                className="input"
                type="password"
                value={config.wifiPassword || ''}
                onChange={(e) => set('wifiPassword', e.target.value)}
              />
            )}
          </Field>
        </div>
      </fieldset>

      <fieldset className="fieldset">
        <legend>Acceso remoto</legend>

        <div className="switch-row">
          <input
            id="cfg-ssh"
            className="switch"
            type="checkbox"
            checked={config.sshEnabled}
            onChange={(e) => set('sshEnabled', e.target.checked)}
          />
          <label htmlFor="cfg-ssh">Habilitar acceso remoto SSH (perfil de diagnóstico)</label>
        </div>
        <p className="field-hint">
          Activa el perfil de paquetes de diagnóstico en el bundle y exige contraseña.
        </p>

        {config.sshEnabled && (
          <Field id="cfg-password" label="Contraseña de administración" error={passwordError}>
            {(aria) => (
              <input
                {...aria}
                className="input"
                type="password"
                value={config.password || ''}
                onChange={(e) => set('password', e.target.value)}
              />
            )}
          </Field>
        )}
      </fieldset>
    </section>
  );
};
