import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CredentialPanel } from './CredentialPanel';
import { DeviceConfig } from '../types/models';

vi.mock('../services/tauri', () => ({
  loginFactory: vi.fn(),
  requestEnrollment: vi.fn(),
}));

import { loginFactory, requestEnrollment } from '../services/tauri';

const base: DeviceConfig = {
  hostname: 'sigil-device',
  username: 'sigil',
  serialNumber: 'SN-2026-0001',
  sshEnabled: false,
  serverUrl: 'https://sigil-server.example',
};

beforeEach(() => {
  vi.mocked(loginFactory).mockReset();
  vi.mocked(requestEnrollment).mockReset();
});

describe('CredentialPanel', () => {
  it('no se puede pedir la credencial antes de autenticarse', () => {
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);
    expect(screen.getByRole('button', { name: /solicitar credencial/i })).toBeDisabled();
  });

  it('autentica contra el servidor y habilita la solicitud', async () => {
    vi.mocked(loginFactory).mockResolvedValue('token-de-sesion');
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /solicitar credencial/i })).toBeEnabled()
    );
    expect(loginFactory).toHaveBeenCalledWith('https://sigil-server.example', 'sigil');
  });

  // La estación no conoce la MAC del equipo que se fabrica: la credencial se
  // pide sin ligar y el número de serie es lo único que la identifica.
  it('pide la credencial sin MAC y a nombre del número de serie', async () => {
    vi.mocked(loginFactory).mockResolvedValue('token-de-sesion');
    vi.mocked(requestEnrollment).mockResolvedValue('clave-de-un-solo-uso');
    const onEnrollmentKey = vi.fn();

    render(
      <CredentialPanel
        config={base}
        enrollmentReady={false}
        onEnrollmentKey={onEnrollmentKey}
      />
    );

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /solicitar credencial/i })).toBeEnabled()
    );
    await userEvent.click(screen.getByRole('button', { name: /solicitar credencial/i }));

    await waitFor(() => expect(onEnrollmentKey).toHaveBeenCalledWith('clave-de-un-solo-uso'));
    expect(requestEnrollment).toHaveBeenCalledWith(
      'https://sigil-server.example',
      'token-de-sesion',
      undefined,
      'SN-2026-0001'
    );
  });

  it('traduce el fallo del keyring en una alerta accionable', async () => {
    vi.mocked(loginFactory).mockRejectedValue(
      "Falta 'secret-tool' en este PC de fabricación. Instale el paquete libsecret-tools"
    );
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));

    const alerta = await screen.findByRole('alert');
    expect(alerta).toHaveTextContent(/libsecret-tools/);
  });

  it('cuando el servidor rechaza la cuenta, ofrece la orden exacta que la arregla', async () => {
    vi.mocked(loginFactory).mockRejectedValue(
      "El servidor rechazó la cuenta de fábrica 'sigil' (código 401).\n" +
        'La contraseña guardada en el keyring no es la de esa cuenta.\n' +
        "  secret-tool store --label='SIGIL Factory' service sigil-factory username sigil"
    );
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));

    // La orden va en su propio bloque de código, no perdida dentro del párrafo.
    const remedio = await screen.findByTestId('remedy-command');
    expect(remedio).toHaveTextContent(
      "secret-tool store --label='SIGIL Factory' service sigil-factory username sigil"
    );
    expect(remedio.tagName.toLowerCase()).toBe('code');
  });

  it('permite copiar la orden sin tener que seleccionarla a mano', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    vi.mocked(loginFactory).mockRejectedValue(
      "  secret-tool store --label='SIGIL Factory' service sigil-factory username sigil"
    );
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));
    await userEvent.click(await screen.findByRole('button', { name: /copiar/i }));

    expect(writeText).toHaveBeenCalledWith(
      "secret-tool store --label='SIGIL Factory' service sigil-factory username sigil"
    );
  });

  it('un fallo que no se arregla con una orden no inventa un remedio', async () => {
    vi.mocked(loginFactory).mockRejectedValue(
      'El servidor de fabricación falló al autenticar (código 502).'
    );
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));

    expect(await screen.findByRole('alert')).toHaveTextContent(/502/);
    expect(screen.queryByTestId('remedy-command')).not.toBeInTheDocument();
  });

  it('tras corregir la contraseña se puede reintentar sin reiniciar la aplicación', async () => {
    vi.mocked(loginFactory)
      .mockRejectedValueOnce("  secret-tool store --label='SIGIL Factory' service sigil-factory username sigil")
      .mockResolvedValueOnce('token-de-sesion');

    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);

    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));
    await screen.findByRole('alert');

    await userEvent.click(screen.getByRole('button', { name: /reintentar/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /solicitar credencial/i })).toBeEnabled()
    );
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('la cuenta de fábrica es independiente del usuario canónico del equipo', async () => {
    vi.mocked(loginFactory).mockResolvedValue('token-de-sesion');
    render(
      <CredentialPanel
        config={base}
        account="operario-fabrica"
        enrollmentReady={false}
        onEnrollmentKey={vi.fn()}
        onAccountChange={vi.fn()}
      />
    );

    expect(screen.getByLabelText(/cuenta de fábrica/i)).toHaveValue('operario-fabrica');
    await userEvent.click(screen.getByRole('button', { name: /autenticar/i }));
    // Se autentica con la cuenta del servidor, no con el usuario del dispositivo.
    expect(loginFactory).toHaveBeenCalledWith('https://sigil-server.example', 'operario-fabrica');
  });

  it('el nombre de la cuenta se puede corregir sin salir del panel', async () => {
    const onAccountChange = vi.fn();
    render(
      <CredentialPanel
        config={base}
        enrollmentReady={false}
        onEnrollmentKey={vi.fn()}
        onAccountChange={onAccountChange}
      />
    );

    const campo = screen.getByLabelText(/cuenta de fábrica/i);
    await userEvent.clear(campo);
    await userEvent.type(campo, 'operario');
    expect(onAccountChange).toHaveBeenCalled();
  });

  it('nunca pide la contraseña de fábrica por pantalla', () => {
    render(<CredentialPanel config={base} enrollmentReady={false} onEnrollmentKey={vi.fn()} />);
    expect(screen.queryByLabelText(/contraseña/i)).not.toBeInTheDocument();
    expect(screen.queryAllByRole('textbox').map((i) => i.getAttribute('type'))).not.toContain(
      'password'
    );
  });

  it('confirma la credencial obtenida y dice qué pasará con ella', () => {
    render(<CredentialPanel config={base} enrollmentReady onEnrollmentKey={vi.fn()} />);
    expect(screen.getByText(/credencial obtenida/i)).toBeInTheDocument();
    expect(screen.getByText(/primer arranque/i)).toBeInTheDocument();
  });

  // El panel no debe mencionar una MAC que la estación nunca puede aportar.
  it('no habla de ligar a una MAC', () => {
    render(<CredentialPanel config={base} enrollmentReady onEnrollmentKey={vi.fn()} />);
    expect(screen.queryByText(/MAC/i)).not.toBeInTheDocument();
  });
});
