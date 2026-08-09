import React from 'react';
import { FlashProgress } from '../types/models';
import { formatBytes, formatDuration, formatSpeed, percentOf } from '../services/format';

interface FlashProgressViewProps {
  progress: FlashProgress | null;
  onCancel: () => void;
}

/** El estado interno del escritor no es texto de producto: se traduce. */
const STATUS_LABEL: Record<FlashProgress['status'], string> = {
  idle: 'En espera',
  running: 'Escribiendo',
  verifying: 'Verificando e instalando',
  done: 'Completado',
  error: 'Error',
  cancelled: 'Cancelado',
};

export const FlashProgressView: React.FC<FlashProgressViewProps> = ({ progress, onCancel }) => {
  if (!progress || progress.status === 'idle') {
    return null;
  }

  const percent = percentOf(progress.bytes_written, progress.total_bytes);
  const isRunning = progress.status === 'running' || progress.status === 'verifying';
  const isError = progress.status === 'error' || progress.status === 'cancelled';

  return (
    <section className={`panel progress-panel progress-${progress.status}`}>
      <div className="panel-head">
        <h2 className="panel-title">Fabricación en curso</h2>
        <span className={`pill pill-${progress.status}`}>{STATUS_LABEL[progress.status]}</span>
      </div>

      <div className="progress-figure">
        <span className="progress-percent">{percent}</span>
        <span className="progress-percent-unit">%</span>
      </div>

      <div
        className="progress-track"
        role="progressbar"
        aria-label="Progreso de la fabricación"
        aria-valuenow={percent}
        aria-valuemin={0}
        aria-valuemax={100}
      >
        <div className="progress-fill" style={{ width: `${percent}%` }} />
      </div>

      {isError ? (
        <p className="progress-message message-error" role="alert">
          {progress.message}
        </p>
      ) : (
        <p className="progress-message" role="status">
          {progress.message}
        </p>
      )}

      <dl className="progress-metrics">
        <div>
          <dt>Escrito</dt>
          <dd>
            {formatBytes(progress.bytes_written)}
            {progress.total_bytes > 0 && (
              <span className="metric-total"> / {formatBytes(progress.total_bytes)}</span>
            )}
          </dd>
        </div>
        <div>
          <dt>Velocidad</dt>
          <dd>{formatSpeed(progress.speed_mbps)}</dd>
        </div>
        <div>
          <dt>Tiempo restante</dt>
          <dd>{formatDuration(progress.eta_seconds)}</dd>
        </div>
      </dl>

      {isRunning && (
        <div className="progress-actions">
          <p className="hint">
            Cancelar deja la tarjeta a medio escribir: habrá que repetir la fabricación completa.
          </p>
          <button type="button" className="button button-danger" onClick={onCancel}>
            Cancelar fabricación
          </button>
        </div>
      )}
    </section>
  );
};
