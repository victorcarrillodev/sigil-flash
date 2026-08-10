import React from 'react';

export interface ChecklistItem {
  label: string;
  done: boolean;
}

interface StepChecklistProps {
  items: ChecklistItem[];
}

const CheckIcon: React.FC = () => (
  <svg
    viewBox="0 0 24 24"
    width="12"
    height="12"
    fill="none"
    stroke="currentColor"
    strokeWidth="3.5"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
  >
    <polyline points="20 6 9 17 4 12" />
  </svg>
);

/** Qué falta en ESTE paso, no en el flujo entero — el step-rail ya cubre eso.
 *  Ocupa el espacio que el panel dejaba vacío en pasos con poco contenido. */
export const StepChecklist: React.FC<StepChecklistProps> = ({ items }) => (
  <ul className="step-checklist" aria-label="Requisitos de este paso">
    {items.map((item) => (
      <li key={item.label} className={item.done ? 'step-checklist-done' : ''}>
        <span className="step-checklist-marker" aria-hidden="true">
          {item.done && <CheckIcon />}
        </span>
        <span className="step-checklist-label">{item.label}</span>
      </li>
    ))}
  </ul>
);
