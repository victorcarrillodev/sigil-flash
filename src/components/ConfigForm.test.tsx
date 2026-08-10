import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { ConfigForm } from './ConfigForm';
import { DeviceConfig } from '../types/models';

const base: DeviceConfig = {
  hostname: 'sigil-device',
  username: 'sigil',
  serialNumber: 'SN-2026-0001',
  sshEnabled: false,
  rpiModel: 'raspberry-pi-zero-2-w',
  serverUrl: 'https://sigil-server.example',
};

const renderForm = (config: Partial<DeviceConfig> = {}) => {
  const onChange = vi.fn();
  render(<ConfigForm config={{ ...base, ...config }} onChange={onChange} />);
  return onChange;
};

describe('ConfigForm', () => {
  it('cada control se alcanza por su etiqueta', () => {
    renderForm();
    expect(screen.getByLabelText(/número de serie/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/hostname/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/PIN del panel/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/modelo/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/acceso remoto/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/URL del servidor/i)).toBeInTheDocument();
  });

  it('el usuario canónico no se puede editar', () => {
    renderForm();
    const usuario = screen.getByLabelText(/usuario canónico/i);
    expect(usuario).toHaveValue('sigil');
    expect(usuario).toBeDisabled();
  });

  it('marca el campo inválido con aria-invalid y describe el error tras pasar por él', async () => {
    renderForm({ serialNumber: 'serie con espacios' });
    const serie = screen.getByLabelText(/número de serie/i);
    await userEvent.click(serie);
    await userEvent.tab();
    expect(serie).toHaveAttribute('aria-invalid', 'true');
    expect(serie).toHaveAccessibleDescription(/\[A-Za-z0-9._-\]/);
  });

  it('no adelanta el error antes de que el operario pase por el campo', () => {
    renderForm({ serialNumber: '' });
    expect(screen.getByLabelText(/número de serie/i)).toHaveAttribute('aria-invalid', 'false');
  });

  it('un campo correcto no se marca como inválido aunque se lo toque', async () => {
    renderForm();
    const serie = screen.getByLabelText(/número de serie/i);
    await userEvent.click(serie);
    await userEvent.tab();
    expect(serie).toHaveAttribute('aria-invalid', 'false');
  });

  it('la contraseña solo aparece cuando el acceso remoto está activo', async () => {
    const { rerender } = render(<ConfigForm config={base} onChange={vi.fn()} />);
    expect(screen.queryByLabelText(/contraseña de administración/i)).not.toBeInTheDocument();

    rerender(<ConfigForm config={{ ...base, sshEnabled: true }} onChange={vi.fn()} />);
    expect(screen.getByLabelText(/contraseña de administración/i)).toBeInTheDocument();
  });

  it('propaga cada edición al modelo', async () => {
    const onChange = renderForm();
    await userEvent.type(screen.getByLabelText(/hostname/i), 'X');
    expect(onChange).toHaveBeenCalledWith(expect.objectContaining({ hostname: 'sigil-deviceX' }));
  });

  it('los secretos se escriben ocultos', () => {
    renderForm({ sshEnabled: true, password: 'secreta' });
    expect(screen.getByLabelText(/PIN del panel/i)).toHaveAttribute('type', 'password');
    expect(screen.getByLabelText(/contraseña de administración/i)).toHaveAttribute('type', 'password');
    expect(screen.getByLabelText(/contraseña WiFi/i)).toHaveAttribute('type', 'password');
  });

  // La estación escribe tarjetas para equipos que todavía no existen, así que
  // no puede conocer su MAC. Un campo que el operario nunca puede rellenar solo
  // produce un error de validación sin salida.
  it('no pide la MAC del equipo que se fabrica', () => {
    renderForm();
    expect(screen.queryByLabelText(/dirección MAC/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/deviceId/i)).not.toBeInTheDocument();
  });

  it('ofrece exactamente los modelos soportados', () => {
    renderForm();
    const opciones = screen.getAllByRole('option').map((o) => (o as HTMLOptionElement).value);
    expect(opciones).toEqual([
      'raspberry-pi-5',
      'raspberry-pi-4b',
      'raspberry-pi-3b-plus',
      'raspberry-pi-3b',
      'raspberry-pi-zero-2-w',
      'raspberry-pi-zero-w',
      'raspberry-pi-1',
    ]);
  });
});
