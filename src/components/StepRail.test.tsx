import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { StepRail } from './StepRail';
import { PreflightStep } from '../services/preflight';

const pasos: PreflightStep[] = [
  { id: 'image', title: 'Imagen y bundle', state: 'complete', detail: 'arm64' },
  { id: 'device', title: 'Dispositivo destino', state: 'active', detail: null },
  { id: 'config', title: 'Configuración', state: 'pending', detail: null },
  { id: 'credential', title: 'Credencial de fábrica', state: 'blocked', detail: 'Sin credencial' },
];

describe('StepRail', () => {
  it('es una navegación con un elemento por paso', () => {
    render(<StepRail steps={pasos} activeId="device" onSelect={vi.fn()} />);
    const nav = screen.getByRole('navigation', { name: /pasos/i });
    expect(nav).toBeInTheDocument();
    expect(screen.getAllByRole('button')).toHaveLength(4);
  });

  it('marca el paso activo para lectores de pantalla', () => {
    render(<StepRail steps={pasos} activeId="device" onSelect={vi.fn()} />);
    const activo = screen.getByRole('button', { name: /dispositivo destino/i });
    expect(activo).toHaveAttribute('aria-current', 'step');
  });

  it('el estado de cada paso se lee, no solo se colorea', () => {
    render(<StepRail steps={pasos} activeId="device" onSelect={vi.fn()} />);
    expect(screen.getByRole('button', { name: /imagen y bundle/i })).toHaveAccessibleDescription(
      /completado/i
    );
    expect(screen.getByRole('button', { name: /credencial/i })).toHaveAccessibleDescription(
      /pendiente|bloquead/i
    );
  });

  it('permite saltar a un paso concreto', async () => {
    const onSelect = vi.fn();
    render(<StepRail steps={pasos} activeId="device" onSelect={onSelect} />);
    await userEvent.click(screen.getByRole('button', { name: /configuración/i }));
    expect(onSelect).toHaveBeenCalledWith('config');
  });

  it('numera los pasos para que el operario pueda referirse a ellos', () => {
    render(<StepRail steps={pasos} activeId="image" onSelect={vi.fn()} />);
    ['1', '2', '3', '4'].forEach((n) => {
      expect(screen.getByText(n)).toBeInTheDocument();
    });
  });
});
