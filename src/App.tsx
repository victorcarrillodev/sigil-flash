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
import { HistoryView } from './components/HistoryView';
import { SshView } from './components/SshView';
import { AppView, ViewTabs } from './components/ViewTabs';
import { buildPreflight, currentStepId, StepId } from './services/preflight';
import { formatBytes } from './services/format';
import {
  agregarEntradaHistorial,
  construirEntradaHistorial,
  fusionarHistorial,
  FlashHistoryEntry,
  leerHistorial,
} from './services/history';
import { csvToRows, entriesToRows, rowsToCsv, rowsToEntries } from './services/historyIO';
import {
  cancelFlash,
  exportHistoryXlsx,
  importHistoryXlsx,
  listFactoryAccounts,
  onFlashProgress,
  openFileDialog,
  rebuildPayloads,
  readTextFile,
  resolveBundle,
  saveFileDialog,
  startFlash,
  validateConfig,
  writeTextFile,
} from './services/tauri';
import {
  generarContrasenaSegura,
  generarNumeroDeSerie,
  incrementarYObtenerSiguienteSerie,
} from './services/validation';

type Tema = 'dark' | 'light';

const CLAVE_TEMA = 'sigil-flash.theme';

// Sin elección previa, sigue al sistema operativo. Con una ya guardada, esa
// gana siempre — el toggle no tendría sentido si el próximo arranque la
// pisara con la preferencia del SO otra vez.
const leerTemaInicial = (): Tema => {
  try {
    const guardado = localStorage.getItem(CLAVE_TEMA);
    if (guardado === 'dark' || guardado === 'light') return guardado;
  } catch {
    // Sin almacenamiento persistente, se sigue al sistema en cada arranque.
  }
  return window.matchMedia?.('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
};

/** Ojo entre dos hexágonos superpuestos: uno relleno en degradé, el otro solo
 *  contorno. El hueco del ojo es una máscara, no blanco a mano — así se ve
 *  bien tanto en modo claro como oscuro, no solo sobre fondo blanco. */
const BrandMark: React.FC = () => (
  <svg className="brand-mark" viewBox="0 0 1000 1000" aria-hidden="true">
    <defs>
      <linearGradient id="brandGrad" x1="0%" y1="15%" x2="100%" y2="85%">
        <stop offset="0%" stopColor="#2f8f74" />
        <stop offset="100%" stopColor="#123a45" />
      </linearGradient>
      <mask id="brandEyeCut">
        <rect x="0" y="0" width="1000" height="1000" fill="#fff" />
        <path d="M250,500 L510,400 L770,500 L510,600 Z" fill="#000" />
      </mask>
    </defs>
    <path
      d="M380,200 L639.8,350 L639.8,650 L380,800 L120.2,650 L120.2,350 Z"
      fill="url(#brandGrad)"
      mask="url(#brandEyeCut)"
    />
    <path
      d="M640,200 L899.8,350 L899.8,650 L640,800 L380.2,650 L380.2,350 Z"
      fill="none"
      stroke="#123a45"
      strokeWidth="16"
    />
    <path d="M250,500 L510,400 L770,500 L510,600 Z" fill="none" stroke="#123a45" strokeWidth="12" />
    <circle cx="510" cy="500" r="52" fill="#123a45" />
  </svg>
);

const SunIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true">
    <circle cx="12" cy="12" r="4.6" fill="currentColor" />
    <g stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <line x1="12" y1="1.5" x2="12" y2="4" />
      <line x1="12" y1="20" x2="12" y2="22.5" />
      <line x1="1.5" y1="12" x2="4" y2="12" />
      <line x1="20" y1="12" x2="22.5" y2="12" />
      <line x1="4.4" y1="4.4" x2="6.1" y2="6.1" />
      <line x1="17.9" y1="17.9" x2="19.6" y2="19.6" />
      <line x1="4.4" y1="19.6" x2="6.1" y2="17.9" />
      <line x1="17.9" y1="6.1" x2="19.6" y2="4.4" />
    </g>
  </svg>
);

const MoonIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true">
    <path fill="currentColor" d="M20.7 14.9A8.5 8.5 0 1 1 9.1 3.3a8.5 8.5 0 0 0 11.6 11.6Z" />
  </svg>
);

const CONFIG_INICIAL: DeviceConfig = {
  hostname: 'sigil-device',
  username: 'sigil',
  serialNumber: generarNumeroDeSerie(),
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
  const [theme, setTheme] = useState<Tema>(leerTemaInicial);

  // El atributo en <html> es lo que el CSS lee (:root[data-theme=...]); el
  // estado de React es solo quién lo decide.
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      localStorage.setItem(CLAVE_TEMA, theme);
    } catch {
      // Sin almacenamiento persistente, el toggle sigue funcionando dentro
      // de la sesión; solo no sobrevive al reinicio.
    }
  }, [theme]);

  const alternarTema = useCallback(() => {
    setTheme((actual) => (actual === 'dark' ? 'light' : 'dark'));
  }, []);

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

  const [view, setView] = useState<AppView>('flash');
  const [history, setHistory] = useState<FlashHistoryEntry[]>(() => leerHistorial());

  // Qué se estaba fabricando cuando arrancó ESTE intento, para poder anotar
  // la entrada del historial cuando llegue el estado final: para entonces el
  // operario ya pudo haber cambiado la imagen o el dispositivo seleccionado.
  const flashSnapshot = useRef<{
    startedAt: string;
    image: ImageInfo;
    device: Device;
    bundle: BundlePair | null;
    config: DeviceConfig;
  } | null>(null);

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

        // Una sola entrada por intento: este efecto ve cada transición de
        // estado exactamente una vez (por el guardado de arriba), a
        // diferencia del `then` de startFlash, que también recibe el estado
        // final y duplicaría el registro si se enganchara ahí también.
        if (p.status === 'done' || p.status === 'error' || p.status === 'cancelled') {
          const snapshot = flashSnapshot.current;
          if (snapshot) {
            const entry = construirEntradaHistorial({ ...snapshot, progress: p });
            setHistory((prev) => agregarEntradaHistorial(prev, entry));
            flashSnapshot.current = null;
          }
        }

        if (p.status === 'done') {
          const siguienteSerie = incrementarYObtenerSiguienteSerie();
          setConfig((prev) => {
            const nuevaClaveSsh = prev.sshEnabled ? generarContrasenaSegura() : prev.password;
            return {
              ...prev,
              serialNumber: siguienteSerie,
              password: nuevaClaveSsh,
            };
          });
          pushLog('info', `Número de serie avanzado automáticamente a ${siguienteSerie}`);
          pushLog('info', 'Contraseña SSH de administración regenerada automáticamente para el siguiente equipo');
        }
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
    flashSnapshot.current = { startedAt: new Date().toISOString(), image, device, bundle, config };
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
      } else if (result.status === 'done') {
        const siguienteSerie = incrementarYObtenerSiguienteSerie();
        setConfig((prev) => {
          const nuevaClaveSsh = prev.sshEnabled ? generarContrasenaSegura() : prev.password;
          return {
            ...prev,
            serialNumber: siguienteSerie,
            password: nuevaClaveSsh,
          };
        });
        pushLog('info', `Número de serie avanzado automáticamente a ${siguienteSerie}`);
        pushLog('info', 'Contraseña SSH de administración regenerada automáticamente para el siguiente equipo');
      }
    } catch (err) {
      setFailure(String(err));
      pushLog('error', String(err));
    } finally {
      setFlashing(false);
    }
  }, [bundle, config, device, image, pushLog]);

  const handleCancel = useCallback(async () => {
    pushLog('warn', 'Cancelando fabricación…');
    try {
      await cancelFlash();
    } catch (err) {
      setFailure(String(err));
      pushLog('error', String(err));
    }
  }, [pushLog]);

  const nombreArchivoHistorial = (extension: string) =>
    `sigil-flash-historial-${new Date().toISOString().slice(0, 10)}.${extension}`;

  const handleExportHistoryCsv = useCallback(async () => {
    try {
      const path = await saveFileDialog(nombreArchivoHistorial('csv'), [
        { name: 'CSV', extensions: ['csv'] },
      ]);
      if (!path) return; // el operario cerró el diálogo sin elegir ruta
      await writeTextFile(path, rowsToCsv(entriesToRows(history)));
      pushLog('info', `Historial exportado a ${path}`);
    } catch (err) {
      // No usa setFailure: ese aviso vive en el pie de la vista de Flasheo y
      // un fallo de exportación no tiene nada que ver con si se puede
      // fabricar. El registro de actividad (visible en las dos vistas) ya
      // avisa aquí mismo.
      pushLog('error', String(err));
    }
  }, [history, pushLog]);

  const handleExportHistoryXlsx = useCallback(async () => {
    try {
      const path = await saveFileDialog(nombreArchivoHistorial('xlsx'), [
        { name: 'Excel', extensions: ['xlsx'] },
      ]);
      if (!path) return;
      await exportHistoryXlsx(path, entriesToRows(history));
      pushLog('info', `Historial exportado a ${path}`);
    } catch (err) {
      pushLog('error', String(err));
    }
  }, [history, pushLog]);

  const handleImportHistory = useCallback(async () => {
    try {
      const path = await openFileDialog([{ name: 'Historial (CSV o Excel)', extensions: ['csv', 'xlsx'] }]);
      if (!path) return;

      const esXlsx = path.toLowerCase().endsWith('.xlsx');
      const rows = esXlsx ? await importHistoryXlsx(path) : csvToRows(await readTextFile(path));
      const { entries: importadas, skipped } = rowsToEntries(rows);

      if (importadas.length === 0) {
        pushLog('error', 'El archivo no contenía filas de historial reconocibles');
        return;
      }

      setHistory((prev) => fusionarHistorial(prev, importadas));
      pushLog(
        'info',
        `Historial importado: ${importadas.length} fabricación(es)${
          skipped > 0 ? `, ${skipped} fila(s) omitida(s) por datos incompletos` : ''
        }`
      );
    } catch (err) {
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
          <div className="brand-mark-tile">
            <BrandMark />
          </div>
          <div className="brand-text-col">
            <span className="brand-name">SIGIL Flash</span>
            <p className="brand-tagline">ESTACIÓN DE FABRICACIÓN OFFLINE</p>
          </div>
        </div>
        <span className="env-badge">Entorno de fabricación autorizado</span>
        <button
          type="button"
          className="theme-toggle"
          onClick={alternarTema}
          aria-label={theme === 'dark' ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro'}
        >
          {theme === 'dark' ? <SunIcon /> : <MoonIcon />}
        </button>
      </header>

      <ViewTabs active={view} onChange={setView} historyCount={history.length} />

      <div className="app-body">
        {view === 'history' && (
          <HistoryView
            entries={history}
            onExportCsv={handleExportHistoryCsv}
            onExportXlsx={handleExportHistoryXlsx}
            onImport={handleImportHistory}
            logs={logs}
          />
        )}

        {/* Montada siempre, oculta por CSS cuando no es la pestaña activa: a
            diferencia de Historial, la terminal SSH tiene estado propio (el
            scrollback de xterm.js) que un desmontaje destruiría sin forma de
            reconstruirlo, aunque la sesión real siga viva en el backend. */}
        <div className={`ssh-view-wrapper${view === 'ssh' ? '' : ' ssh-view-hidden'}`}>
          <SshView active={view === 'ssh'} theme={theme} history={history} />
        </div>

        {view === 'flash' && (
          <>
            <ContextPanel image={image} bundle={bundle} device={device} config={config} />

            <aside className="sidebar">
              <StepRail
                steps={preflight.steps}
                activeId={activeStep}
                onSelect={setManualStep}
                canFlash={preflight.canFlash}
                onStartFlash={handleStartFlash}
              />
            </aside>

            <div className="content-column">
              <main className="content">
                {showProgress && <FlashProgressView progress={progress} onCancel={handleCancel} />}
                {!showProgress && (
                  <div key={activeStep} className="step-panel-wrapper">
                    {stepPanel()}
                  </div>
                )}
                {failure && (
                  <p className="message-error" role="alert">
                    {failure}
                  </p>
                )}
              </main>

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
          </>
        )}
      </div>
    </div>
  );
};

export default App;
