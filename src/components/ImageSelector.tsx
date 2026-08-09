import React, { useState } from 'react';
import { BundlePair, ImageInfo } from '../types/models';
import { pickImageFile, selectImage, verifySha256 } from '../services/tauri';
import { formatBytes } from '../services/format';

interface ImageSelectorProps {
  onImageSelected: (image: ImageInfo | null) => void;
  selectedImage: ImageInfo | null;
  bundle: BundlePair | null;
  bundleError: string | null;
  onRebuildPayloads: () => void;
  busy: boolean;
}

export const ImageSelector: React.FC<ImageSelectorProps> = ({
  onImageSelected,
  selectedImage,
  bundle,
  bundleError,
  onRebuildPayloads,
  busy,
}) => {
  const [loading, setLoading] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [verification, setVerification] = useState<{ ok: boolean; text: string } | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handlePick = async () => {
    setLoading(true);
    setError(null);
    try {
      const path = await pickImageFile();
      if (!path) return;
      onImageSelected(await selectImage(path));
      setVerification(null);
    } catch (err) {
      setError(String(err));
    } finally {
      setLoading(false);
    }
  };

  const handleVerify = async () => {
    if (!selectedImage || !bundle) return;
    setVerifying(true);
    try {
      await verifySha256(selectedImage.path, bundle.base_image_sha256 || '');
      setVerification({ ok: true, text: 'SHA-256 coincide con el contrato del bundle' });
    } catch (err) {
      setVerification({ ok: false, text: String(err) });
    } finally {
      setVerifying(false);
    }
  };

  return (
    <section className="panel">
      <div className="panel-head">
        <h2 className="panel-title">Imagen base y bundle</h2>
        {bundle && <span className="pill pill-done">{bundle.architecture}</span>}
      </div>

      <p className="panel-lead">
        La imagen decide el par bundle/payload. Un payload sin su repositorio APT nunca se
        selecciona: la fabricación se bloquea antes de escribir un solo byte.
      </p>

      {selectedImage ? (
        <div className="summary-grid">
          <div className="summary-item">
            <span className="summary-key">Archivo</span>
            <span className="summary-value mono">{selectedImage.name}</span>
          </div>
          <div className="summary-item">
            <span className="summary-key">Tamaño</span>
            <span className="summary-value mono">{formatBytes(selectedImage.size)}</span>
          </div>
          {bundle && (
            <>
              <div className="summary-item">
                <span className="summary-key">Contrato</span>
                <span className="summary-value mono">{bundle.contract_name}</span>
              </div>
              <div className="summary-item">
                <span className="summary-key">Arquitectura</span>
                <span className="summary-value mono">{bundle.architecture}</span>
              </div>
            </>
          )}
        </div>
      ) : (
        <div className="empty-state">
          <p>Ninguna imagen seleccionada todavía.</p>
        </div>
      )}

      {bundleError && (
        <p className="message-error" role="alert">
          {bundleError}
        </p>
      )}

      {verification && (
        <p className={verification.ok ? 'message-ok' : 'message-error'}>{verification.text}</p>
      )}

      {error && (
        <p className="message-error" role="alert">
          {error}
        </p>
      )}

      <div className="panel-actions">
        <button type="button" className="button button-primary" onClick={handlePick} disabled={loading}>
          {loading ? 'Abriendo…' : selectedImage ? 'Elegir otro archivo' : 'Elegir archivo…'}
        </button>
        {selectedImage && bundle && (
          <button type="button" className="button" onClick={handleVerify} disabled={verifying}>
            {verifying ? 'Verificando…' : 'Verificar SHA-256'}
          </button>
        )}
        <button type="button" className="button button-ghost" onClick={onRebuildPayloads} disabled={busy}>
          Regenerar payloads
        </button>
      </div>

      <p className="hint">
        Los payloads son fotos fijas de <code>sigil-hardware/</code>: editarlo no tiene efecto hasta
        regenerarlos.
      </p>
    </section>
  );
};
