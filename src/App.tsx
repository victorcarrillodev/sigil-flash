import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BundlePair, Device, DeviceConfig, FlashProgress, ImageInfo } from './types/models';
import { ImageSelector } from './components/ImageSelector';
import { DeviceSelector } from './components/DeviceSelector';
import { ConfigForm } from './components/ConfigForm';
import { CredentialPanel } from './components/CredentialPanel';
import { FlashProgressView } from './components/FlashProgressView';
import { StepRail } from './components/StepRail';
import { ContextPanel } from './components/ContextPanel';
import { ActivityLog, LogEntry, LogLevel } from './components/ActivityLog';
import { buildPreflight, currentStepId, StepId } from './services/preflight';
import { formatBytes } from './services/format';
import {
  cancelFlash,
  listFactoryAccounts,
  onFlashProgress,
  rebuildPayloads,
  resolveBundle,
  startFlash,
  validateConfig,
} from './services/tauri';

const CONFIG_INICIAL: DeviceConfig = {
  hostname: 'sigil-device',
  username: 'sigil',
  serialNumber: '',
  sshEnabled: false,
  rpiModel: 'raspberry-pi-zero-2-w',
  serverUrl: 'https://sigil-server.sphinx-pickerel.ts.net',
};

// La cuenta del servidor de fabricación se recuerda entre arranques: es un dato
// de la estación, no del equipo que se fabrica, y volver a teclearla en cada
// sesión es la vía rápida a un 401 por un carácter mal puesto.
const CLAVE_CUENTA_FABRICA = 'sigil-flash.factory-account';

// El alias canónico que el backend resuelve a la cuenta con rol FACTORY
// (`FACTORY_USERNAME` en su entorno). Nunca el usuario del dispositivo: ese es
// del sistema operativo que se instala y el servidor no lo conoce. Es solo el
// punto de partida: si el keyring ya tiene una cuenta guardada, manda esa.
const CUENTA_FABRICA_POR_DEFECTO = 'fabrica';

const leerCuentaDeFabrica = (): string | null => {
  try {
    return localStorage.getItem(CLAVE_CUENTA_FABRICA);
  } catch {
    return null;
  }
};

export const App: React.FC = () => {
  const [image, setImage] = useState<ImageInfo | null>(null);
  const [bundle, setBundle] = useState<BundlePair | null>(null);
  const [bundleError, setBundleError] = useState<string | null>(null);
  const [device, setDevice] = useState<Device | null>(null);
  const [config, setConfig] = useState<DeviceConfig>(CONFIG_INICIAL);
  const [flashing, setFlashing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<FlashProgress | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [manualStep, setManualStep] = useState<StepId | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const logSeq = useRef(0);
  const prevProgressStatus = useRef<FlashProgress['status']>('idle');

  // Historial de acciones y errores para el operario, no para depuración: cada
  // línea es una frase que explica qué pasó, no un volcado técnico. Se acota a
  // 200 líneas para que una sesión larga no crezca sin límite.
  const pushLog = useCallback((level: LogLevel, message: string) => {
    logSeq.current += 1;
    const entry: LogEntry = {
      id: logSeq.current,
      time: new Date().toLocaleTimeString('es-ES'),
      level,
      message,
    };
    setLogs((prev) => {
      const next = [...prev, entry];
      return next.length > 200 ? next.slice(next.length - 200) : next;
    });
  }, []);

  // Cuenta del servidor de fabricación. Deliberadamente fuera de DeviceConfig:
  // el usuario del dispositivo es fijo, el del servidor no tiene por qué serlo,
  // y DeviceConfig viaja dentro de la imagen — la cuenta de fábrica no puede.
  const [factoryAccount, setFactoryAccount] = useState(
    () => leerCuentaDeFabrica() ?? CUENTA_FABRICA_POR_DEFECTO
  );

  // Sin elección previa del operario, manda el keyring: proponer un nombre que
  // este PC no tiene guardado solo produce un error que parece del servidor.
  // Con varias cuentas guardadas no hay forma de adivinar cuál toca, así que se
  // deja el alias canónico y que el operario elija.
  useEffect(() => {
    if (leerCuentaDeFabrica()) return;
    let cancelado = false;
    listFactoryAccounts()
      .then((cuentas) => {
        if (!cancelado && cuentas.length === 1) setFactoryAccount(cuentas[0]);
      })
      .catch(() => {
        // El keyring es una comodidad para prellenar el campo, no un requisito.
      });
    return () => {
      cancelado = true;
    };
  }, []);

  const actualizarCuentaDeFabrica = useCallback((cuenta: string) => {
    setFactoryAccount(cuenta);
    try {
      localStorage.setItem(CLAVE_CUENTA_FABRICA, cuenta);
    } catch {
      // Un webview sin almacenamiento persistente no debe impedir fabricar: la
      // cuenta sigue siendo editable, solo no sobrevive al reinicio.
    }
  }, []);

  const preflight = useMemo(
    () => buildPreflight({ image, bundle, bundleError, device, config, flashing }),
    [image, bundle, bundleError, device, config, flashing]
  );

  const activeStep = manualStep ?? currentStepId(preflight.steps);
  const showProgress = progress !== null && progress.status !== 'idle';

  // El escritor privilegiado publica su estado y el backend lo reemite: la
  // barra avanza durante toda la escritura, no solo al terminar.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    onFlashProgress((p) => {
      setProgress(p);
      // Solo se registra el cambio de fase, no cada evento de bytes escritos:
      // eso llegaría varias veces por segundo y ahogaría el registro.
      if (p.status !== prevProgressStatus.current) {
        prevProgressStatus.current = p.status;
        const level: LogLevel = p.status === 'error' ? 'error' : p.status === 'cancelled' ? 'warn' : 'info';
        pushLog(level, p.message || `Fase de fabricación: ${p.status}`);
      }
    }).then((fn) => {
      unlisten = fn;
    });
    return () => unlisten?.();
  }, [pushLog]);

  // La imagen decide el par bundle/payload. Sin par no se fabrica.
  useEffect(() => {
    if (!image) {
      setBundle(null);
      setBundleError(null);
      return;
    }
    let cancelled = false;
    resolveBundle(image.name)
      .then((pair) => {
        if (cancelled) return;
        setBundle(pair);
        setBundleError(null);
        pushLog('info', `Bundle resuelto: ${pair.contract_name} · ${pair.architecture}`);
      })
      .catch((err) => {
        if (cancelled) return;
        setBundle(null);
        setBundleError(String(err));
        pushLog('error', `Error al resolver el bundle: ${String(err)}`);
      });
    return () => {
      cancelled = true;
    };
  }, [image, pushLog]);

  const handleStartFlash = useCallback(async () => {
    if (!image || !device) return;
    setFailure(null);
    pushLog('info', `Fabricación iniciada: ${image.name} → ${device.path}`);
    try {
      await validateConfig(config);
      setFlashing(true);
      const result = await startFlash(image.path, device.path, config);
      setProgress(result);
      if (result.status === 'error') {
        setFailure(result.message);
        pushLog('error', result.message);
      }
    } catch (err) {
      setFailure(String(err));
      pushLog('error', String(err));
    } finally {
      setFlashing(false);
    }
  }, [config, device, image, pushLog]);

  const handleCancel = useCallback(async () => {
    pushLog('warn', 'Cancelando fabricación…');
    try {
      await cancelFlash();
    } catch (err) {
      setFailure(String(err));
      pushLog('error', String(err));
    }
  }, [pushLog]);

  const handleRebuildPayloads = useCallback(async () => {
    setBusy(true);
    setFailure(null);
    pushLog('info', 'Regenerando payloads…');
    try {
      await rebuildPayloads();
      if (image) setBundle(await resolveBundle(image.name));
      pushLog('info', 'Payloads regenerados');
    } catch (err) {
      setFailure(String(err));
      pushLog('error', String(err));
    } finally {
      setBusy(false);
    }
  }, [image, pushLog]);

  const handleImageSelected = useCallback(
    (img: ImageInfo | null) => {
      setImage(img);
      pushLog(
        'info',
        img ? `Imagen seleccionada: ${img.name} (${formatBytes(img.size)})` : 'Imagen deseleccionada'
      );
    },
    [pushLog]
  );

  const handleDeviceSelected = useCallback(
    (dev: Device | null) => {
      setDevice(dev);
      pushLog(
        'info',
        dev ? `Dispositivo destino: ${dev.model} (${dev.path}, ${dev.size})` : 'Dispositivo deseleccionado'
      );
    },
    [pushLog]
  );

  const blockingReason = flashing
    ? 'Fabricando: escritura e instalación en curso'
    : preflight.blockers[0] ?? 'Todo listo para fabricar';

  const stepPanel = () => {
    switch (activeStep) {
      case 'image':
        return (
          <ImageSelector
            selectedImage={image}
            onImageSelected={handleImageSelected}
            bundle={bundle}
            bundleError={bundleError}
            onRebuildPayloads={handleRebuildPayloads}
            busy={busy}
          />
        );
      case 'device':
        return <DeviceSelector selectedDevice={device} onDeviceSelected={handleDeviceSelected} />;
      case 'config':
        return <ConfigForm config={config} onChange={setConfig} />;
      case 'credential':
        return (
          <CredentialPanel
            config={config}
            account={factoryAccount}
            onAccountChange={actualizarCuentaDeFabrica}
            enrollmentReady={!!config.apiKey}
            onEnrollmentKey={(key) => setConfig((prev) => ({ ...prev, apiKey: key }))}
            onLog={pushLog}
          />
        );
    }
  };

  return (
    <div className="app">
      <header className="app-bar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">
            ◈
          </span>
          <span className="brand-name">SIGIL Flash</span>
        </div>
        <p className="brand-tagline">Estación de fabricación offline</p>
        <span className="env-badge">Entorno de fabricación autorizado</span>
      </header>

      <div className="app-body">
        <ContextPanel image={image} bundle={bundle} device={device} config={config} />

        <aside className="sidebar">
          <StepRail steps={preflight.steps} activeId={activeStep} onSelect={setManualStep} />

          <div className="launch">
            <button
              type="button"
              className="button button-launch"
              onClick={handleStartFlash}
              disabled={!preflight.canFlash}
            >
              Iniciar fabricación
            </button>
          </div>
        </aside>

        <main className="content">
          {showProgress && <FlashProgressView progress={progress} onCancel={handleCancel} />}
          {!showProgress && stepPanel()}
          {failure && (
            <p className="message-error" role="alert">
              {failure}
            </p>
          )}
        </main>
      </div>

      <footer className="app-foot">
        <div className="status-row">
          {/* Dos regiones vivas anunciando a la vez se pisan: durante la
              fabricación manda el mensaje del escritor, no este resumen. */}
          <p
            className="blocking-reason"
            data-testid="blocking-reason"
            role={showProgress ? undefined : 'status'}
          >
            <span className={`dot ${preflight.canFlash ? 'dot-ready' : 'dot-blocked'}`} aria-hidden="true" />
            {blockingReason}
          </p>
          <span className="app-version">SIGIL Flash v1.0.0</span>
        </div>

        {preflight.blockers.length > 0 && (
          <ul className="blocker-list">
            {preflight.blockers.slice(0, 3).map((b) => (
              <li key={b}>{b}</li>
            ))}
          </ul>
        )}

        {preflight.warnings.map((w) => (
          <p className="message-warn" key={w}>
            {w}
          </p>
        ))}

        <ActivityLog entries={logs} />
      </footer>
    </div>
  );
};

export default App;
