import React from 'react';
import { FlashHistoryEntry } from '../services/history';
import { formatBytes, formatDuration } from '../services/format';
import { ActivityLog, LogEntry } from './ActivityLog';

interface HistoryViewProps {
  entries: FlashHistoryEntry[];
  onExportCsv: () => void;
  onExportXlsx: () => void;
  onImport: () => void;
  logs: LogEntry[];
}

/** Mismo criterio de traducción que en FlashProgressView y ActivityLog: el
 *  estado interno no es texto de producto. */
const STATUS_LABEL: Record<FlashHistoryEntry['status'], string> = {
  done: 'Completado',
  error: 'Error',
  cancelled: 'Cancelado',
};

function formatFecha(iso: string): string {
  const fecha = new Date(iso);
  if (Number.isNaN(fecha.getTime())) return iso;
  return fecha.toLocaleString('es-ES', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export const HistoryView: React.FC<HistoryViewProps> = ({
  entries,
  onExportCsv,
  onExportXlsx,
  onImport,
  logs,
}) => (
  <section className="history-view" aria-label="Historial de fabricaciones">
    <div className="history-head">
      <div className="panel-title-group">
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.2"
          strokeLinecap="round"
          strokeLinejoin="round"
          className="panel-title-icon"
          aria-hidden="true"
        >
          <circle cx="12" cy="13" r="8" />
          <polyline points="12 9 12 13 15 15" />
          <path d="M5 3 3 5" />
          <path d="M19 3l2 2" />
        </svg>
        <h2 className="panel-title">Historial de fabricaciones</h2>
      </div>

      <div className="history-toolbar">
        <button type="button" className="button button-small" onClick={onImport}>
          Importar…
        </button>
        <button
          type="button"
          className="button button-small"
          onClick={onExportCsv}
          disabled={entries.length === 0}
        >
          Exportar CSV
        </button>
        <button
          type="button"
          className="button button-small"
          onClick={onExportXlsx}
          disabled={entries.length === 0}
        >
          Exportar Excel
        </button>
      </div>

      <span className="step-rail-badge">{entries.length}</span>
    </div>

    {entries.length === 0 ? (
      <div className="empty-state">
        <p>Todavía no se ha completado ninguna fabricación en esta estación.</p>
      </div>
    ) : (
      <ol className="history-list">
        {entries.map((entry) => (
          <li key={entry.id} className="history-entry">
            <div className="history-entry-head">
              <span className={`pill pill-${entry.status}`}>{STATUS_LABEL[entry.status]}</span>
              <div className="history-entry-title">
                <span className="history-entry-hostname">{entry.config.hostname || '—'}</span>
                {entry.config.serialNumber && (
                  <span className="history-entry-serial mono">{entry.config.serialNumber}</span>
                )}
              </div>
              <span className="history-entry-time">{formatFecha(entry.finishedAt)}</span>
            </div>

            <div className="summary-grid">
              <div className="summary-item">
                <span className="summary-key">Imagen</span>
                <span className="summary-value mono">{entry.image.name}</span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Dispositivo</span>
                <span className="summary-value">
                  {entry.device.model} · {entry.device.size}
                </span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Ruta</span>
                <span className="summary-value mono">{entry.device.path}</span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Modelo de placa</span>
                <span className="summary-value">{entry.config.rpiModel ?? '—'}</span>
              </div>
              {entry.bundle && (
                <div className="summary-item">
                  <span className="summary-key">Arquitectura</span>
                  <span className="summary-value mono">{entry.bundle.architecture}</span>
                </div>
              )}
              <div className="summary-item">
                <span className="summary-key">SSH</span>
                <span className="summary-value">
                  {entry.config.sshEnabled ? 'Activado' : 'Desactivado'}
                </span>
              </div>
              <div className="summary-item">
                <span className="summary-key">WiFi</span>
                <span className="summary-value">{entry.config.wifiSsid ?? 'Sin configurar'}</span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Servidor</span>
                <span className="summary-value mono">{entry.config.serverUrl ?? '—'}</span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Escrito</span>
                <span className="summary-value mono">
                  {formatBytes(entry.bytesWritten)}
                  {entry.totalBytes > 0 && (
                    <span className="metric-total"> / {formatBytes(entry.totalBytes)}</span>
                  )}
                </span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Duración</span>
                <span className="summary-value mono">{formatDuration(entry.durationSeconds)}</span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Iniciado</span>
                <span className="summary-value mono">{formatFecha(entry.startedAt)}</span>
              </div>
            </div>

            {entry.status === 'error' && (
              <p className="message-error" role="alert">
                {entry.message}
              </p>
            )}
            {entry.status === 'cancelled' && <p className="message-warn">{entry.message}</p>}
          </li>
        ))}
      </ol>
    )}

    {/* Único rastro visible de "exportar"/"importar": esta vista no tiene su
        propio panel de estado, y el pie de la vista de Flasheo no se
        renderiza aquí. Sin esto, un fallo de exportación (o el éxito) pasa
        en silencio mientras el operario está en esta pestaña. */}
    <ActivityLog entries={logs} />
  </section>
);
