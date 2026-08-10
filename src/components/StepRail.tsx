import React from 'react';
import { PreflightStep, StepId, StepState } from '../services/preflight';

interface StepRailProps {
  steps: PreflightStep[];
  activeId: StepId;
  onSelect: (id: StepId) => void;
  canFlash?: boolean;
  onStartFlash?: () => void;
}

/** El estado se lee, no solo se colorea: el color por sí solo no es un dato. */
const STATE_LABEL: Record<StepState, string> = {
  pending: 'Pendiente',
  active: 'En curso',
  complete: 'Completado',
  blocked: 'Bloqueado, requiere atención',
};

const CheckIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
    <polyline points="20 6 9 17 4 12" />
  </svg>
);

const AlertIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round">
    <circle cx="12" cy="12" r="10" />
    <line x1="12" y1="8" x2="12" y2="12" />
    <line x1="12" y1="16" x2="12.01" y2="16" />
  </svg>
);

const ChevronRightIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className="step-arrow">
    <polyline points="9 18 15 12 9 6" />
  </svg>
);

const LockIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="button-icon">
    <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
    <path d="M7 11V7a5 5 0 0 1 10 0v4" />
  </svg>
);

const RocketIcon: React.FC = () => (
  <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="button-icon">
    <path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.71.79-1.81.2-2.55l-2.45-2.45c-.74-.59-1.84-.51-2.55.2z" />
    <path d="M12 15l-3-3 7.35-7.35c.78-.78 2.05-.78 2.83 0v0c.78.78.78 2.05 0 2.83L12 15z" />
    <path d="M9 18l3 3 7.35-7.35c.78-.78.78-2.05 0-2.83v0c-.78-.78-2.05-.78-2.83 0L9 18z" />
  </svg>
);

export const StepRail: React.FC<StepRailProps> = ({
  steps,
  activeId,
  onSelect,
  canFlash = false,
  onStartFlash,
}) => {
  const completedCount = steps.filter((s) => s.state === 'complete').length;

  return (
    <nav className="step-rail" aria-label="Pasos de fabricación">
      <div className="step-rail-head">
        <span className="step-rail-heading">Proceso de fabricación</span>
        <span className="step-rail-badge">{completedCount}/4</span>
      </div>

      <ol className="step-rail-list">
        {steps.map((step, index) => {
          const isActive = step.id === activeId;
          const descriptionId = `step-${step.id}-state`;
          const renderIcon = () => {
            if (step.state === 'complete') return <CheckIcon />;
            if (step.state === 'blocked') return <AlertIcon />;
            return null;
          };
          const iconNode = renderIcon();

          return (
            <li key={step.id}>
              <button
                type="button"
                className={`step-item step-${step.state}${isActive ? ' step-current' : ''}`}
                aria-current={isActive ? 'step' : undefined}
                aria-describedby={descriptionId}
                onClick={() => onSelect(step.id)}
              >
                <span className="step-marker">
                  <span className="step-number">{index + 1}</span>
                  {iconNode && (
                    <span className="step-glyph" aria-hidden="true">
                      {iconNode}
                    </span>
                  )}
                </span>
                <span className="step-body">
                  <span className="step-title">{step.title}</span>
                  {step.detail && <span className="step-detail">{step.detail}</span>}
                </span>
                {isActive && <ChevronRightIcon />}
                <span id={descriptionId} className="visually-hidden">
                  {STATE_LABEL[step.state]}
                </span>
              </button>
            </li>
          );
        })}
      </ol>

      {onStartFlash && (
        <div className="step-rail-launch">
          <div className="step-rail-divider" />
          <button
            type="button"
            className={`button button-launch ${canFlash ? 'button-launch-ready' : 'button-launch-disabled'}`}
            onClick={onStartFlash}
            disabled={!canFlash}
          >
            {canFlash ? <RocketIcon /> : <LockIcon />}
            <span>Iniciar fabricación</span>
          </button>
        </div>
      )}
    </nav>
  );
};
