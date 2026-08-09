import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { FlashProgressView } from './FlashProgressView';
import { FlashProgress } from '../types/models';

const progreso = (extra: Partial<FlashProgress> = {}): FlashProgress => ({
  bytes_written: 512 * 1024 * 1024,
  total_bytes: 1024 * 1024 * 1024,
  speed_mbps: 24.5,
  eta_seconds: 75,
  status: 'running',
  message: 'Escribiendo imagen descomprimida...',
  ...extra,
});

describe('FlashProgressView', () => {
  it('expone una barra de progreso accesible con su valor real', () => {
    render(<FlashProgressView progress={progreso()} onCancel={vi.fn()} />);

    const barra = screen.getByRole('progressbar');
    expect(barra).toHaveAttribute('aria-valuenow', '50');
    expect(barra).toHaveAttribute('aria-valuemin', '0');
    expect(barra).toHaveAttribute('aria-valuemax', '100');
    expect(barra).toHaveAccessibleName();
  });

  it('anuncia el mensaje del escritor en una región viva', () => {
    render(<FlashProgressView progress={progreso()} onCancel={vi.fn()} />);
    const region = screen.getByRole('status');
    expect(region).toHaveTextContent('Escribiendo imagen descomprimida...');
  });

  it('muestra velocidad y ETA en unidades legibles, no en segundos crudos', () => {
    render(<FlashProgressView progress={progreso()} onCancel={vi.fn()} />);
    expect(screen.getByText('24,5 MB/s')).toBeInTheDocument();
    expect(screen.getByText('1 min 15 s')).toBeInTheDocument();
    expect(screen.getByText(/512,0 MB/)).toBeInTheDocument();
  });

  it('permite cancelar mientras escribe y avisa de que es destructivo', async () => {
    const onCancel = vi.fn();
    render(<FlashProgressView progress={progreso()} onCancel={onCancel} />);

    const boton = screen.getByRole('button', { name: /cancelar/i });
    await userEvent.click(boton);
    expect(onCancel).toHaveBeenCalledOnce();
  });

  it('retira el botón de cancelar cuando ya no hay nada que cancelar', () => {
    render(<FlashProgressView progress={progreso({ status: 'done' })} onCancel={vi.fn()} />);
    expect(screen.queryByRole('button', { name: /cancelar/i })).not.toBeInTheDocument();
  });

  it('un error conserva su mensaje original y se anuncia como alerta', () => {
    render(
      <FlashProgressView
        progress={progreso({
          status: 'error',
          message: 'ABORTADO: la imagen escrita es de arquitectura armhf pero el bundle es arm64.',
        })}
        onCancel={vi.fn()}
      />
    );

    const alerta = screen.getByRole('alert');
    expect(alerta).toHaveTextContent(/ABORTADO: la imagen escrita es de arquitectura armhf/);
  });

  it('el estado terminal se nombra en español, no con el literal interno', () => {
    render(<FlashProgressView progress={progreso({ status: 'done' })} onCancel={vi.fn()} />);
    expect(screen.getByText(/completado/i)).toBeInTheDocument();
    expect(screen.queryByText('DONE')).not.toBeInTheDocument();
  });

  it('no dibuja nada mientras no hay fabricación en curso', () => {
    const { container } = render(
      <FlashProgressView progress={progreso({ status: 'idle' })} onCancel={vi.fn()} />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it('durante la fase de verificación no promete un porcentaje de escritura falso', () => {
    render(
      <FlashProgressView
        progress={progreso({
          status: 'verifying',
          bytes_written: 1024 * 1024 * 1024,
          message: 'Instalando paquetes y personalizando el sistema (chroot)...',
        })}
        onCancel={vi.fn()}
      />
    );
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '100');
    expect(screen.getByText(/instalando paquetes/i)).toBeInTheDocument();
  });
});
