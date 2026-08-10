import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Terminal, ITheme } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { FlashHistoryEntry } from '../services/history';
import {
  eliminarHost,
  generarIdHost,
  guardarHost,
  leerSshHosts,
  marcarConectado,
  SshHost,
  sugerirHostsDesdeHistorial,
} from '../services/sshHosts';
import {
  onSshExit,
  onSshOutput,
  sshConnect,
  sshDisconnect,
  sshForgetHostKey,
  sshResize,
  sshWrite,
} from '../services/ssh';
import { CANONICAL_USERNAME } from '../services/validation';

interface SshViewProps {
  /** La vista vive montada todo el tiempo (para no perder el scrollback ni
   *  la sesión al cambiar de pestaña); esto indica si es la visible ahora. */
  active: boolean;
  theme: 'dark' | 'light';
  history: FlashHistoryEntry[];
}

type ConnectionStatus = 'idle' | 'connecting' | 'connected' | 'ended';

const MONO_FONT = "'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace";

const DARK_XTERM_THEME: ITheme = {
  background: '#111723',
  foreground: '#ecf1f8',
  cursor: '#00d8f6',
  cursorAccent: '#030a14',
  selectionBackground: 'rgba(0, 216, 246, 0.35)',
  black: '#111723',
  red: '#f55873',
  green: '#10b981',
  yellow: '#f59e0b',
  blue: '#6366f1',
  magenta: '#a855f7',
  cyan: '#00d8f6',
  white: '#a8b9d0',
  brightBlack: '#7e91ac',
  brightRed: '#f87171',
  brightGreen: '#34d399',
  brightYellow: '#fbbf24',
  brightBlue: '#818cf8',
  brightMagenta: '#c084fc',
  brightCyan: '#67e8f9',
  brightWhite: '#ecf1f8',
};

const LIGHT_XTERM_THEME: ITheme = {
  background: '#cbd2e0',
  foreground: '#1e293b',
  cursor: '#2563eb',
  cursorAccent: '#ffffff',
  selectionBackground: 'rgba(37, 99, 235, 0.3)',
  black: '#1e293b',
  red: '#a81b1b',
  green: '#046345',
  yellow: '#844804',
  blue: '#4f46e5',
  magenta: '#7e22ce',
  cyan: '#0e7490',
  white: '#536073',
  brightBlack: '#334155',
  brightRed: '#dc2626',
  brightGreen: '#059669',
  brightYellow: '#b45309',
  brightBlue: '#4338ca',
  brightMagenta: '#9333ea',
  brightCyan: '#0891b2',
  brightWhite: '#1e293b',
};

const STATUS_LABEL: Record<ConnectionStatus, string> = {
  idle: 'Sin conectar',
  connecting: 'Conectando…',
  connected: 'Conectado',
  ended: 'Sesión finalizada',
};

export const SshView: React.FC<SshViewProps> = ({ active, theme, history }) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const terminalRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const statusRef = useRef<ConnectionStatus>('idle');

  const [hosts, setHosts] = useState<SshHost[]>(() => leerSshHosts());
  const [status, setStatus] = useState<ConnectionStatus>('idle');
  const [target, setTarget] = useState<{ host: string; port: number; username: string } | null>(null);

  const [formLabel, setFormLabel] = useState('');
  const [formHost, setFormHost] = useState('');
  const [formPort, setFormPort] = useState('22');
  const [formUsername, setFormUsername] = useState(CANONICAL_USERNAME);

  useEffect(() => {
    statusRef.current = status;
  }, [status]);

  // La terminal se crea una sola vez: este componente vive montado durante
  // toda la sesión de la app (oculto vía CSS entre pestañas), así que no hay
  // un remount que reconstruya el estado visual del terminal.
  useEffect(() => {
    const term = new Terminal({
      cursorBlink: true,
      convertEol: true,
      fontFamily: MONO_FONT,
      fontSize: 13,
      scrollback: 5000,
      theme: theme === 'light' ? LIGHT_XTERM_THEME : DARK_XTERM_THEME,
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    if (containerRef.current) {
      term.open(containerRef.current);
      fitAddon.fit();
    }
    term.writeln('Elija un dispositivo de la izquierda y pulse Conectar.');
    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    const dataSub = term.onData((data) => {
      if (statusRef.current === 'connected') {
        sshWrite(data).catch((err) => term.writeln(`\r\n\x1b[31m[error al enviar] ${String(err)}\x1b[0m`));
      }
    });
    const resizeSub = term.onResize(({ cols, rows }) => {
      if (statusRef.current === 'connected') {
        sshResize(cols, rows).catch(() => {
          // El siguiente tecleo fallará igual y sí se reporta; un resize
          // perdido no merece su propio aviso.
        });
      }
    });

    let unlistenOutput: (() => void) | undefined;
    let unlistenExit: (() => void) | undefined;
    onSshOutput((bytes) => term.write(bytes)).then((fn) => {
      unlistenOutput = fn;
    });
    onSshExit((info) => {
      statusRef.current = 'ended';
      setStatus('ended');
      setTarget(null);
      term.writeln(`\r\n\x1b[33m[sesión finalizada] ${info.message}\x1b[0m`);
    }).then((fn) => {
      unlistenExit = fn;
    });

    return () => {
      dataSub.dispose();
      resizeSub.dispose();
      unlistenOutput?.();
      unlistenExit?.();
      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // El contenedor mide 0×0 mientras la pestaña está oculta (display:none),
  // así que el reajuste real solo puede pasar cuando vuelve a ser visible.
  useEffect(() => {
    if (!active) return;
    fitAddonRef.current?.fit();
    const onWindowResize = () => fitAddonRef.current?.fit();
    window.addEventListener('resize', onWindowResize);
    return () => window.removeEventListener('resize', onWindowResize);
  }, [active]);

  // El tema se actualiza en caliente: no hace falta recrear la terminal ni
  // perder su scrollback solo porque el operario cambió de modo claro/oscuro.
  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.theme = theme === 'light' ? LIGHT_XTERM_THEME : DARK_XTERM_THEME;
    }
  }, [theme]);

  const handleConnect = useCallback(async (host: string, port: number, username: string, label: string) => {
    const term = terminalRef.current;
    if (!term || statusRef.current === 'connecting') return;

    statusRef.current = 'connecting';
    setStatus('connecting');
    setTarget({ host, port, username });
    term.reset();
    term.writeln(`Conectando a ${username}@${host}:${port}…`);

    try {
      await sshConnect(host, port, username, term.cols, term.rows);
      statusRef.current = 'connected';
      setStatus('connected');
      setHosts((prev) => {
        const conActual = guardarHost(prev, { label: label || host, host, port, username });
        return marcarConectado(conActual, generarIdHost(host, port, username));
      });
    } catch (err) {
      statusRef.current = 'idle';
      setStatus('idle');
      setTarget(null);
      term.writeln(`\r\n\x1b[31m[error de conexión] ${String(err)}\x1b[0m`);
    }
  }, []);

  const handleDisconnect = useCallback(async () => {
    try {
      await sshDisconnect();
    } catch (err) {
      terminalRef.current?.writeln(`\r\n\x1b[31m[error al desconectar] ${String(err)}\x1b[0m`);
    } finally {
      statusRef.current = 'idle';
      setStatus('idle');
      setTarget(null);
      terminalRef.current?.writeln('\r\n[desconectado]');
    }
  }, []);

  const handleForgetKey = useCallback(async (host: string, port: number) => {
    try {
      await sshForgetHostKey(host, port);
      terminalRef.current?.writeln(`\r\n[clave de host olvidada para ${host}:${port}. El próximo intento la vuelve a aceptar sola.]`);
    } catch (err) {
      terminalRef.current?.writeln(`\r\n\x1b[31m[no se pudo olvidar la clave] ${String(err)}\x1b[0m`);
    }
  }, []);

  const handleRemoveHost = useCallback((id: string) => {
    setHosts((prev) => eliminarHost(prev, id));
  }, []);

  const handleManualSubmit = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault();
      const host = formHost.trim();
      const username = formUsername.trim();
      const port = Number.parseInt(formPort, 10);
      if (!host || !username || !Number.isFinite(port) || port < 1 || port > 65535) return;
      handleConnect(host, port, username, formLabel.trim());
    },
    [formHost, formLabel, formPort, formUsername, handleConnect]
  );

  const suggestions = sugerirHostsDesdeHistorial(history, hosts);
  const isCurrentTarget = (h: string, p: number, u: string) =>
    target !== null && target.host === h && target.port === p && target.username === u;

  return (
    <section className="ssh-view" aria-label="Conexión SSH a dispositivos">
      <aside className="ssh-devices">
        <div className="ssh-devices-scroll">
          <span className="context-card-title">Dispositivos guardados</span>
          {hosts.length === 0 ? (
            <p className="context-empty">Sin dispositivos guardados todavía.</p>
          ) : (
            <ul className="ssh-host-list">
              {hosts.map((h) => (
                <li
                  key={h.id}
                  className={`ssh-host-item${isCurrentTarget(h.host, h.port, h.username) ? ' ssh-host-active' : ''}`}
                >
                  <button
                    type="button"
                    className="ssh-host-main"
                    onClick={() => handleConnect(h.host, h.port, h.username, h.label)}
                    disabled={status === 'connecting'}
                  >
                    <span className="ssh-host-label">{h.label}</span>
                    <span className="ssh-host-meta mono">
                      {h.username}@{h.host}:{h.port}
                    </span>
                  </button>
                  <div className="ssh-host-actions">
                    <button
                      type="button"
                      className="input-btn"
                      title="Olvidar clave de host (usar tras reflashear este equipo)"
                      onClick={() => handleForgetKey(h.host, h.port)}
                    >
                      <KeyOffIcon />
                    </button>
                    <button
                      type="button"
                      className="input-btn"
                      title="Quitar de guardados"
                      onClick={() => handleRemoveHost(h.id)}
                    >
                      <TrashIcon />
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}

          {suggestions.length > 0 && (
            <>
              <span className="context-card-title">Fabricados en esta estación</span>
              <ul className="ssh-host-list">
                {suggestions.map((s) => (
                  <li key={s.host} className="ssh-host-item">
                    <button
                      type="button"
                      className="ssh-host-main"
                      onClick={() => handleConnect(`${s.host}.local`, 22, CANONICAL_USERNAME, s.host)}
                      disabled={status === 'connecting'}
                    >
                      <span className="ssh-host-label">{s.host}</span>
                      <span className="ssh-host-meta mono">
                        {[s.rpiModel, s.serialNumber].filter(Boolean).join(' · ') || '—'}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </>
          )}

          <span className="context-card-title">Conectar a otro destino</span>
          <form className="ssh-add-form" onSubmit={handleManualSubmit}>
            <div className="field">
              <label className="field-label" htmlFor="ssh-form-host">
                Host o IP
              </label>
              <input
                id="ssh-form-host"
                className="input"
                value={formHost}
                onChange={(e) => setFormHost(e.target.value)}
                placeholder="192.168.1.50 o mi-equipo.local"
                autoComplete="off"
              />
            </div>
            <div className="ssh-form-row">
              <div className="field">
                <label className="field-label" htmlFor="ssh-form-user">
                  Usuario
                </label>
                <input
                  id="ssh-form-user"
                  className="input"
                  value={formUsername}
                  onChange={(e) => setFormUsername(e.target.value)}
                  autoComplete="off"
                />
              </div>
              <div className="field">
                <label className="field-label" htmlFor="ssh-form-port">
                  Puerto
                </label>
                <input
                  id="ssh-form-port"
                  className="input"
                  type="number"
                  min={1}
                  max={65535}
                  value={formPort}
                  onChange={(e) => setFormPort(e.target.value)}
                />
              </div>
            </div>
            <div className="field">
              <label className="field-label" htmlFor="ssh-form-label">
                Nombre para guardar (opcional)
              </label>
              <input
                id="ssh-form-label"
                className="input"
                value={formLabel}
                onChange={(e) => setFormLabel(e.target.value)}
                placeholder={formHost || 'Se usa el host si se deja vacío'}
                autoComplete="off"
              />
            </div>
            <button type="submit" className="button button-primary" disabled={status === 'connecting' || !formHost.trim()}>
              Conectar
            </button>
          </form>
        </div>
      </aside>

      <div className="ssh-terminal-col">
        <div className="ssh-terminal-head">
          <span className={`pill ssh-status-${status}`}>{STATUS_LABEL[status]}</span>
          {target && (
            <span className="ssh-target mono">
              {target.username}@{target.host}:{target.port}
            </span>
          )}
          <button
            type="button"
            className="button button-ghost ssh-disconnect-btn"
            onClick={handleDisconnect}
            disabled={status !== 'connected'}
          >
            Desconectar
          </button>
        </div>
        <div className="ssh-terminal-container" ref={containerRef} />
      </div>
    </section>
  );
};

const KeyOffIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M2 2l20 20" />
    <path d="M9.5 9.5a3 3 0 0 0 4.24 4.24" />
    <path d="M14.5 6.5A5 5 0 0 1 19 12c0 .6-.1 1.17-.28 1.7" />
    <path d="M7 12a5 5 0 0 1 4.8-5" />
  </svg>
);

const TrashIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <polyline points="3 6 5 6 21 6" />
    <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
    <path d="M10 11v6" />
    <path d="M14 11v6" />
    <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" />
  </svg>
);
