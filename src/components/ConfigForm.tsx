import React, { useState } from 'react';
import { DeviceConfig } from '../types/models';
import {
  SUPPORTED_MODELS,
  generarContrasenaSegura,
  validateHostname,
  validatePanelPin,
  validatePassword,
  validateSerialNumber,
  validateServerUrl,
  validateWifi,
} from '../services/validation';
import { StepChecklist } from './StepChecklist';

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

const HelpCircleIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <circle cx="12" cy="12" r="10" />
    <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3" />
    <line x1="12" y1="17" x2="12.01" y2="17" />
  </svg>
);

const EyeIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
    <circle cx="12" cy="12" r="3" />
  </svg>
);

const EyeOffIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24" />
    <line x1="1" y1="1" x2="23" y2="23" />
  </svg>
);

const RefreshIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
    <polyline points="23 4 23 10 17 10" />
    <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
  </svg>
);

/** Etiqueta con tooltip de ayuda y error; los textos descriptivos van en el icono de interrogación para no descompensar las alturas de los campos. */
const Field: React.FC<FieldProps> = ({ id, label, hint, error, children }) => {
  const errorId = error ? `${id}-error` : undefined;

  return (
    <div className={`field${error ? ' field-invalid' : ''}`}>
      <label className="field-label" htmlFor={id}>
        <span>{label}</span>
        {hint && (
          <span
            className="field-tooltip"
            title={hint}
            tabIndex={0}
            role="img"
            aria-label={hint}
          >
            <HelpCircleIcon />
          </span>
        )}
      </label>
      {children({ id, 'aria-invalid': !!error, 'aria-describedby': errorId })}
      {error && (
        <p className="field-error" id={errorId}>
          {error}
        </p>
      )}
    </div>
  );
};

export const ConfigForm: React.FC<ConfigFormProps> = ({ config, onChange }) => {
  const set = <K extends keyof DeviceConfig>(field: K, value: DeviceConfig[K]) =>
    onChange({ ...config, [field]: value });

  const [showPassword, setShowPassword] = useState(false);

  const handleSshToggle = (checked: boolean) => {
    if (checked && (!config.password || config.password.trim() === '')) {
      const nuevaClave = generarContrasenaSegura();
      onChange({ ...config, sshEnabled: true, password: nuevaClave });
    } else {
      onChange({ ...config, sshEnabled: checked });
    }
  };

  const [touched, setTouched] = useState<Partial<Record<keyof DeviceConfig, boolean>>>({});
  const markTouched = (field: keyof DeviceConfig) => setTouched((t) => (t[field] ? t : { ...t, [field]: true }));

  const serialError = touched.serialNumber
    ? config.serialNumber
      ? validateSerialNumber(config.serialNumber)
      : 'El número de serie es obligatorio'
    : null;
  const hostnameError = touched.hostname ? validateHostname(config.hostname) : null;
  const pinError = touched.panelPin && config.panelPin ? validatePanelPin(config.panelPin) : null;
  const passwordError = touched.password && config.password ? validatePassword(config.password) : null;
  const wifiError = touched.wifiSsid ? validateWifi(config.wifiSsid, config.wifiPassword) : null;
  const urlError = touched.serverUrl && config.serverUrl ? validateServerUrl(config.serverUrl) : null;

  // Igual que el step-rail pero adentro del paso: qué de lo obligatorio aquí
  // falta todavía. La contraseña solo cuenta si SSH está activo — si no, el
  // campo ni se muestra.
  const checklistItems = [
    {
      label: 'Número de serie',
      done: !!config.serialNumber && !validateSerialNumber(config.serialNumber),
    },
    { label: 'Hostname válido', done: !validateHostname(config.hostname) },
    ...(config.sshEnabled
      ? [
          {
            label: 'Contraseña de administración',
            done: !!config.password && !validatePassword(config.password),
          },
        ]
      : []),
    { label: 'URL del servidor', done: !!config.serverUrl },
  ];

  return (
    <section className="panel">
      <div className="panel-head">
        <div className="panel-title-group">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="panel-title-icon" aria-hidden="true">
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
          <h2 className="panel-title">Configuración del dispositivo</h2>
        </div>
      </div>

      <div className="panel-body">
        <div className="panel-checklist-col">
          <StepChecklist items={checklistItems} />
        </div>

        <div className="panel-main-col panel-main-col-tight">
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
              onBlur={() => markTouched('serialNumber')}
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
              onBlur={() => markTouched('hostname')}
            />
          )}
        </Field>

        <Field
          id="cfg-username"
          label="Usuario canónico"
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
              onBlur={() => markTouched('panelPin')}
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
              onBlur={() => markTouched('serverUrl')}
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
                onBlur={() => markTouched('wifiSsid')}
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
            onChange={(e) => handleSshToggle(e.target.checked)}
          />
          <label htmlFor="cfg-ssh">Habilitar acceso remoto SSH (perfil de diagnóstico)</label>
        </div>
        <p className="field-hint">
          Activa el perfil de paquetes de diagnóstico en el bundle y exige contraseña.
        </p>

        {config.sshEnabled && (
          <Field
            id="cfg-password"
            label="Contraseña de administración"
            error={passwordError}
            hint="Se prellena automáticamente con una clave segura. Puedes usar el icono de ojo para verla o el de refresco para generar una nueva."
          >
            {(aria) => (
              <div className="input-group">
                <input
                  {...aria}
                  className="input"
                  type={showPassword ? 'text' : 'password'}
                  value={config.password || ''}
                  placeholder="Contraseña segura"
                  onChange={(e) => set('password', e.target.value)}
                  onBlur={() => markTouched('password')}
                />
                <button
                  type="button"
                  className="input-btn"
                  title={showPassword ? 'Ocultar contraseña' : 'Mostrar contraseña'}
                  onClick={() => setShowPassword((v) => !v)}
                >
                  {showPassword ? <EyeOffIcon /> : <EyeIcon />}
                </button>
                <button
                  type="button"
                  className="input-btn"
                  title="Generar nueva contraseña segura"
                  onClick={() => set('password', generarContrasenaSegura())}
                >
                  <RefreshIcon />
                </button>
              </div>
            )}
          </Field>
        )}
      </fieldset>
        </div>
      </div>
    </section>
  );
};
