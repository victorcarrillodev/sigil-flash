import React from 'react';

export type AppView = 'flash' | 'history' | 'ssh';

interface ViewTabsProps {
  active: AppView;
  onChange: (view: AppView) => void;
  historyCount: number;
}

const FlashIcon: React.FC = () => (
  <svg
    viewBox="0 0 24 24"
    width="16"
    height="16"
    fill="none"
    stroke="currentColor"
    strokeWidth="2.2"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
  >
    <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" />
  </svg>
);

const HistoryIcon: React.FC = () => (
  <svg
    viewBox="0 0 24 24"
    width="16"
    height="16"
    fill="none"
    stroke="currentColor"
    strokeWidth="2.2"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
  >
    <circle cx="12" cy="13" r="8" />
    <polyline points="12 9 12 13 15 15" />
    <path d="M5 3 3 5" />
    <path d="M19 3l2 2" />
  </svg>
);

const TerminalIcon: React.FC = () => (
  <svg
    viewBox="0 0 24 24"
    width="16"
    height="16"
    fill="none"
    stroke="currentColor"
    strokeWidth="2.2"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
  >
    <rect x="3" y="4" width="18" height="16" rx="2" />
    <polyline points="7 9 10.5 12 7 15" />
    <line x1="12.5" y1="15" x2="17" y2="15" />
  </svg>
);

/** Conmutador entre la vista de trabajo, la bitácora y la terminal SSH: tres
 *  vistas completas de la aplicación, no pasos de un mismo flujo — por eso
 *  usa el patrón ARIA de pestañas y no el `aria-current="step"` del StepRail. */
export const ViewTabs: React.FC<ViewTabsProps> = ({ active, onChange, historyCount }) => (
  <div className="view-tabs" role="tablist" aria-label="Vistas de la aplicación">
    <button
      type="button"
      role="tab"
      aria-selected={active === 'flash'}
      className={`view-tab${active === 'flash' ? ' view-tab-active' : ''}`}
      onClick={() => onChange('flash')}
    >
      <FlashIcon />
      <span>Flasheo</span>
    </button>
    <button
      type="button"
      role="tab"
      aria-selected={active === 'history'}
      className={`view-tab${active === 'history' ? ' view-tab-active' : ''}`}
      onClick={() => onChange('history')}
    >
      <HistoryIcon />
      <span>Historial</span>
      <span className="view-tab-badge">{historyCount}</span>
    </button>
    <button
      type="button"
      role="tab"
      aria-selected={active === 'ssh'}
      className={`view-tab${active === 'ssh' ? ' view-tab-active' : ''}`}
      onClick={() => onChange('ssh')}
    >
      <TerminalIcon />
      <span>SSH</span>
    </button>
  </div>
);
