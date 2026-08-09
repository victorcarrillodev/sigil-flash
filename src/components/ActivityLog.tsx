import React, { useEffect, useRef } from 'react';

export type LogLevel = 'info' | 'warn' | 'error';

export interface LogEntry {
  id: number;
  time: string;
  level: LogLevel;
  message: string;
}

interface ActivityLogProps {
  entries: LogEntry[];
}

/** El nivel se lee, no solo se colorea: mismo principio que en StepRail. */
const LEVEL_LABEL: Record<LogLevel, string> = {
  info: 'Información',
  warn: 'Aviso',
  error: 'Error',
};

export const ActivityLog: React.FC<ActivityLogProps> = ({ entries }) => {
  const listRef = useRef<HTMLOListElement>(null);

  // Consola de solo lectura: cada entrada nueva se ve sin desplazar a mano.
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [entries.length]);

  return (
    <div className="log-console">
      <div className="log-console-head">
        <span>Registro de actividad</span>
        <span className="log-count">{entries.length}</span>
      </div>
      <ol className="log-list" ref={listRef} aria-label="Registro de actividad de la estación">
        {entries.length === 0 ? (
          <li className="log-empty">Sin actividad todavía.</li>
        ) : (
          entries.map((entry) => (
            <li key={entry.id} className={`log-entry log-${entry.level}`}>
              <span className="log-time mono">{entry.time}</span>
              <span className="visually-hidden">{LEVEL_LABEL[entry.level]}: </span>
              <span className="log-message">{entry.message}</span>
            </li>
          ))
        )}
      </ol>
    </div>
  );
};
