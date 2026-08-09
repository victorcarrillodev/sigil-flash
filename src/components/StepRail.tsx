import React from 'react';
import { PreflightStep, StepId, StepState } from '../services/preflight';

interface StepRailProps {
  steps: PreflightStep[];
  activeId: StepId;
  onSelect: (id: StepId) => void;
}

/** El estado se lee, no solo se colorea: el color por sí solo no es un dato. */
const STATE_LABEL: Record<StepState, string> = {
  pending: 'Pendiente',
  active: 'En curso',
  complete: 'Completado',
  blocked: 'Bloqueado, requiere atención',
};

const STATE_GLYPH: Record<StepState, string | null> = {
  pending: null,
  active: null,
  complete: '✓',
  blocked: '!',
};

export const StepRail: React.FC<StepRailProps> = ({ steps, activeId, onSelect }) => (
  <nav className="step-rail" aria-label="Pasos de fabricación">
    <ol className="step-rail-list">
      {steps.map((step, index) => {
        const isActive = step.id === activeId;
        const descriptionId = `step-${step.id}-state`;
        const glyph = STATE_GLYPH[step.state];

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
                {glyph && (
                  <span className="step-glyph" aria-hidden="true">
                    {glyph}
                  </span>
                )}
              </span>
              <span className="step-body">
                <span className="step-title">{step.title}</span>
                {step.detail && <span className="step-detail">{step.detail}</span>}
              </span>
              <span id={descriptionId} className="visually-hidden">
                {STATE_LABEL[step.state]}
              </span>
            </button>
          </li>
        );
      })}
    </ol>
  </nav>
);
