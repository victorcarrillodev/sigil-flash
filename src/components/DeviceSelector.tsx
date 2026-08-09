import React, { useCallback, useEffect, useState } from 'react';
import { Device } from '../types/models';
import { refreshDevices } from '../services/tauri';

interface DeviceSelectorProps {
  onDeviceSelected: (device: Device | null) => void;
  selectedDevice: Device | null;
}

export const DeviceSelector: React.FC<DeviceSelectorProps> = ({
  onDeviceSelected,
  selectedDevice,
}) => {
  const [devices, setDevices] = useState<Device[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchDevices = useCallback(async () => {
    setLoading(true);
    try {
      const found = await refreshDevices();
      setDevices(found);
      setError(null);
      // Si la unidad elegida desaparece, la selección deja de ser válida.
      if (selectedDevice && !found.some((d) => d.path === selectedDevice.path)) {
        onDeviceSelected(null);
      }
    } catch (err) {
      setError(String(err));
    } finally {
      setLoading(false);
    }
  }, [onDeviceSelected, selectedDevice]);

  useEffect(() => {
    fetchDevices();
    const interval = setInterval(fetchDevices, 3000);
    return () => clearInterval(interval);
    // El sondeo se instala una sola vez; cada disparo usa la closure vigente.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <section className="panel">
      <div className="panel-head">
        <h2 className="panel-title">Dispositivo destino</h2>
        <button type="button" className="button button-ghost" onClick={fetchDevices} disabled={loading}>
          {loading ? 'Buscando…' : 'Refrescar'}
        </button>
      </div>

      <p className="panel-lead">
        Solo aparecen unidades extraíbles. El proceso elevado vuelve a comprobar por su cuenta que
        el destino no sea el disco del sistema.
      </p>

      {error && (
        <p className="message-error" role="alert">
          {error}
        </p>
      )}

      {devices.length === 0 ? (
        <div className="empty-state">
          <p>No se detecta ninguna unidad extraíble.</p>
          <p className="hint">Inserte la microSD o el lector USB y pulse «Refrescar».</p>
        </div>
      ) : (
        <fieldset className="device-list">
          <legend className="visually-hidden">Unidades extraíbles detectadas</legend>
          {devices.map((device) => {
            const id = `device-${device.name}`;
            const checked = selectedDevice?.path === device.path;
            return (
              <div key={device.path} className={`device-option${checked ? ' device-selected' : ''}`}>
                <input
                  id={id}
                  type="radio"
                  name="target-device"
                  value={device.path}
                  checked={checked}
                  onChange={() => onDeviceSelected(device)}
                />
                <label htmlFor={id}>
                  <span className="device-model">{device.model}</span>
                  <span className="device-meta">
                    <code>{device.path}</code>
                    <span>{device.size}</span>
                    <span className="device-transport">{device.transport || 'extraíble'}</span>
                  </span>
                </label>
              </div>
            );
          })}
        </fieldset>
      )}

      {selectedDevice && (
        <p className="message-warn">
          Todo el contenido de <code>{selectedDevice.path}</code> se borrará al fabricar.
        </p>
      )}
    </section>
  );
};
