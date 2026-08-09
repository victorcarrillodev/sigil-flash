import React, { useState } from 'react';
import { DeviceConfig } from '../types/models';
import { loginFactory, requestEnrollment } from '../services/tauri';
import { LogLevel } from './ActivityLog';

interface CredentialPanelProps {
  config: DeviceConfig;
  enrollmentReady: boolean;
  onEnrollmentKey: (key: string) => void;
  /** Cuenta de fábrica del SERVIDOR. No es el usuario canónico del equipo. */
  account?: string;
  onAccountChange?: (account: string) => void;
  /** Opcional: para que el error o el éxito quede también en el registro de actividad. */
  onLog?: (level: LogLevel, message: string) => void;
}

/**
 * La contraseña de fábrica nunca pasa por aquí: el backend la lee del keyring
 * del sistema y la usa solo para el login HTTPS. Como el operario no puede
 * teclearla, un rechazo del servidor lo dejaría sin salida; por eso el panel
 * extrae la orden exacta que arregla el problema y la ofrece para copiar.
 */
export function extractRemedyCommand(message: string): string | null {
  const line = message
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.startsWith('secret-tool store'));
  return line ?? null;
}

export const CredentialPanel: React.FC<CredentialPanelProps> = ({
  config,
  enrollmentReady,
  onEnrollmentKey,
  account: accountProp,
  onAccountChange,
  onLog,
}) => {
  const [token, setToken] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const serverUrl = config.serverUrl || '';
  // El usuario del dispositivo es fijo ('sigil'); la cuenta del servidor no
  // tiene por qué llamarse igual.
  const account = accountProp ?? config.username;
  const remedy = error ? extractRemedyCommand(error) : null;

  const handleLogin = async () => {
    setBusy(true);
    setError(null);
    setCopied(false);
    try {
      const sessionToken = await loginFactory(serverUrl, account);
      setToken(sessionToken);
      onLog?.('info', `Autenticado en el servidor de fábrica como «${account}»`);
    } catch (err) {
      setError(String(err));
      setToken(null);
      onLog?.('error', String(err));
    } finally {
      setBusy(false);
    }
  };

  const handleRequestKey = async () => {
    if (!token) return;
    setBusy(true);
    setError(null);
    try {
      // Sin device_id: la estación no conoce la MAC del equipo que se fabrica
      // —la tarjeta se escribe antes de que exista el hardware—, así que la
      // credencial sale sin ligar. El servidor lo admite salvo que corra con
      // ENROLLMENT_REQUIRE_BINDING.
      const key = await requestEnrollment(serverUrl, token, undefined, config.serialNumber || undefined);
      onEnrollmentKey(key);
      onLog?.('info', 'Credencial de enrolamiento obtenida');
    } catch (err) {
      setError(String(err));
      onLog?.('error', String(err));
    } finally {
      setBusy(false);
    }
  };

  const handleCopy = async () => {
    if (!remedy) return;
    try {
      await navigator.clipboard.writeText(remedy);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  return (
    <section className="panel">
      <div className="panel-head">
        <h2 className="panel-title">Credencial de fábrica</h2>
        {enrollmentReady && <span className="pill pill-done">Obtenida</span>}
      </div>

      <p className="panel-lead">
        La contraseña de la cuenta de fábrica vive solo en el keyring del sistema. La aplicación
        nunca la muestra, ni la escribe en disco, ni la pasa por la línea de órdenes.
      </p>

      <div className="field">
        <label className="field-label" htmlFor="factory-account">
          Cuenta de fábrica
        </label>
        <input
          id="factory-account"
          type="text"
          className="input"
          value={account}
          onChange={(e) => onAccountChange?.(e.target.value)}
          readOnly={!onAccountChange}
          aria-describedby="factory-account-hint"
        />
        <p className="field-hint" id="factory-account-hint">
          Es la cuenta del servidor de fabricación, no el usuario del dispositivo. Debe coincidir
          con el <code>username</code> con el que guardó la contraseña en el keyring.
        </p>
      </div>

      <ol className="credential-steps">
        <li>
          <div className="credential-step-text">
            <strong>Autenticar contra el servidor</strong>
            <span>El backend lee el keyring y obtiene un token de sesión de vida corta.</span>
          </div>
          <button
            type="button"
            className="button"
            onClick={handleLogin}
            disabled={busy || !serverUrl}
          >
            {error ? 'Reintentar' : token ? 'Renovar sesión' : 'Autenticar'}
          </button>
        </li>
        <li>
          <div className="credential-step-text">
            <strong>Solicitar credencial de un solo uso</strong>
            <span>Se emite a nombre del número de serie de esta fabricación.</span>
          </div>
          <button
            type="button"
            className="button button-primary"
            onClick={handleRequestKey}
            disabled={busy || !token || !config.serialNumber}
          >
            Solicitar credencial
          </button>
        </li>
      </ol>

      <p className={`credential-state ${enrollmentReady ? 'state-ok' : 'state-pending'}`}>
        {enrollmentReady
          ? 'Credencial obtenida: se canjea en el primer arranque y se borra.'
          : 'Sin credencial: el dispositivo no podría enrolarse en el primer arranque.'}
      </p>

      {error && (
        <div className="failure">
          <p className="message-error" role="alert">
            {error
              .split('\n')
              .filter((l) => !l.trim().startsWith('secret-tool store'))
              .join(' ')
              .trim()}
          </p>

          {remedy && (
            <div className="remedy">
              <p className="remedy-lead">Ejecute esto en una terminal y vuelva a intentarlo:</p>
              <div className="remedy-row">
                <code className="remedy-command" data-testid="remedy-command">
                  {remedy}
                </code>
                <button type="button" className="button button-ghost" onClick={handleCopy}>
                  {copied ? 'Copiado' : 'Copiar'}
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </section>
  );
};
