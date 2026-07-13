import { useState, useCallback, useRef, useEffect, useMemo } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import {
  EngineResult,
  EngineLine,
  engineStatus,
  engineBinaryPath,
  engineBuildPayload,
  enginePlan,
  engineValidate,
  engineApply,
  engineWriteProvision,
  ProvisionDocument,
} from "../services/engineService";

// ── Local types ───────────────────────────────────────────────────────────────

type LogStream = "stdout" | "stderr" | "ui-info" | "ui-error" | "ui-success";

interface LogLine {
  stream: LogStream;
  text: string;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const MAX_LOG_LINES = 500;

// ── Helpers ───────────────────────────────────────────────────────────────────

function appendEngineLines(
  prev: LogLine[],
  lines: EngineLine[]
): LogLine[] {
  const next = [
    ...prev,
    ...lines.map((l) => ({ stream: l.stream as LogStream, text: l.text })),
  ];
  return next.slice(-MAX_LOG_LINES);
}

function logColor(stream: LogStream): string {
  switch (stream) {
    case "stderr":
      return "#f59e0b";
    case "ui-error":
      return "#ef4444";
    case "ui-success":
      return "#10b981";
    case "ui-info":
      return "var(--text-muted)";
    default:
      return "#10b981";
  }
}

function uiLine(stream: LogStream, text: string): LogLine {
  return { stream, text };
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function EnginePanel() {
  // Engine detection
  const [enginePath, setEnginePath] = useState("");
  const [engineAvailable, setEngineAvailable] = useState<boolean | null>(null);

  // Input paths
  const [baseImage, setBaseImage] = useState("");
  const [sha256, setSha256] = useState("");
  const [payload, setPayload] = useState("");
  const [provision, setProvision] = useState("");
  const [targetDevice, setTargetDevice] = useState("");

  // Manufacturing identity (never includes credentials).
  const [serialNumber, setSerialNumber] = useState("");
  const [productModel, setProductModel] = useState("Sigil-Streamer");
  const [modelVersion, setModelVersion] = useState("v1");
  const [batch, setBatch] = useState("");
  const [i2sDac, setI2sDac] = useState(false);
  const [savedProvisionJson, setSavedProvisionJson] = useState("");

  const provisionDocument = useMemo<ProvisionDocument>(() => ({
    _schema_version: "1.0",
    serial_number: serialNumber.trim(),
    model: productModel.trim(),
    model_version: modelVersion.trim(),
    batch: batch.trim(),
    capabilities: { i2s_dac: i2sDac },
  }), [serialNumber, productModel, modelVersion, batch, i2sDac]);

  const provisionJson = useMemo(
    () => JSON.stringify(provisionDocument, null, 2),
    [provisionDocument]
  );
  const provisionErrors = useMemo(() => {
    const errors: string[] = [];
    const safe = /^[A-Za-z0-9][A-Za-z0-9 ._+:/-]{0,63}$/;
    const serialSafe = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
    if (!serialSafe.test(provisionDocument.serial_number)) errors.push("serial_number es obligatorio y debe usar caracteres seguros.");
    if (!safe.test(provisionDocument.model)) errors.push("model es obligatorio y debe usar caracteres seguros.");
    if (!safe.test(provisionDocument.model_version) || provisionDocument.model_version.length > 32) errors.push("model_version es obligatorio (máximo 32 caracteres seguros).");
    if (!safe.test(provisionDocument.batch)) errors.push("batch es obligatorio y debe usar caracteres seguros.");
    if (typeof provisionDocument.capabilities.i2s_dac !== "boolean") errors.push("capabilities.i2s_dac debe ser booleano.");
    return errors;
  }, [provisionDocument]);

  // Execution state
  const [busy, setBusy] = useState(false);
  const [logLines, setLogLines] = useState<LogLine[]>([
    uiLine("ui-info", "Panel del Motor SIGIL listo. Detecta el motor para empezar."),
  ]);
  const [lastResult, setLastResult] = useState<EngineResult | null>(null);

  const logEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll log to bottom
  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logLines]);

  // ── Log helpers ─────────────────────────────────────────────────────────────

  const addLog = useCallback((stream: LogStream, text: string) => {
    setLogLines((prev) => [...prev.slice(-(MAX_LOG_LINES - 1)), uiLine(stream, text)]);
  }, []);

  const applyResult = useCallback(
    (result: EngineResult, label: string) => {
      setLastResult(result);
      setLogLines((prev) => {
        const withEngine = appendEngineLines(prev, result.lines);
        const statusLine = uiLine(
          result.success ? "ui-success" : "ui-error",
          `[${label}] exit ${result.exit_code} — ${result.success ? "CORRECTO" : "FALLIDO"}${
            result.was_dry_run ? " (dry-run)" : ""
          }`
        );
        return [...withEngine, statusLine].slice(-MAX_LOG_LINES);
      });
    },
    []
  );

  // ── Param builder ────────────────────────────────────────────────────────────

  const buildParams = useCallback(
    () => ({
      base_image: baseImage,
      base_image_sha256: sha256.trim().toLowerCase(),
      payload,
      provision: provision || null,
      target_device: targetDevice.trim() || null,
      dry_run: true,
    }),
    [baseImage, sha256, payload, provision, targetDevice]
  );

  const requireParams = useCallback(() => {
    if (!baseImage) { addLog("ui-error", "Selecciona la imagen base primero."); return false; }
    if (!sha256.trim()) { addLog("ui-error", "Introduce el SHA-256 esperado."); return false; }
    if (!payload) { addLog("ui-error", "Selecciona el directorio del payload."); return false; }
    if (provisionErrors.length > 0) { addLog("ui-error", provisionErrors[0]); return false; }
    if (!provision) { addLog("ui-error", "Guarda el provision JSON antes de continuar."); return false; }
    if (savedProvisionJson !== provisionJson) { addLog("ui-error", "La identidad cambió; vuelve a guardar el provision JSON."); return false; }
    return true;
  }, [baseImage, sha256, payload, provision, provisionErrors, savedProvisionJson, provisionJson, addLog]);

  // ── Actions ──────────────────────────────────────────────────────────────────

  const detectEngine = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    addLog("ui-info", "Detectando motor flasher-rs…");
    try {
      const path = await engineBinaryPath();
      setEnginePath(path);
      const result = await engineStatus();
      setEngineAvailable(result.success);
      applyResult(result, "status");
      addLog(
        result.success ? "ui-success" : "ui-error",
        result.success
          ? `Motor disponible en: ${path}`
          : "Motor no disponible. Ejecuta 'cargo build' en sigil-hardware/flasher-rs."
      );
    } catch (err) {
      setEngineAvailable(false);
      addLog("ui-error", `Error al detectar motor: ${String(err)}`);
      addLog("ui-info", "Solución: define SIGIL_HARDWARE_ROOT apuntando al repo sigil-hardware y reinicia la app.");
    } finally {
      setBusy(false);
    }
  }, [busy, addLog, applyResult]);

  const buildPayload = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    addLog("ui-info", "Generando payload SIGIL vía build-flasher-payload.sh…");
    try {
      const result = await engineBuildPayload();
      applyResult(result, "build-payload");
      if (result.success) {
        addLog("ui-success", "Payload generado. Selecciónalo en el campo de payload arriba.");
      }
    } catch (err) {
      addLog("ui-error", `Error al generar payload: ${String(err)}`);
    } finally {
      setBusy(false);
    }
  }, [busy, addLog, applyResult]);

  const runPlan = useCallback(async () => {
    if (busy || !requireParams()) return;
    setBusy(true);
    addLog("ui-info", "Generando plan (dry-run)…");
    try {
      const result = await enginePlan(buildParams());
      applyResult(result, "plan");
    } catch (err) {
      addLog("ui-error", `Error en plan: ${String(err)}`);
    } finally {
      setBusy(false);
    }
  }, [busy, requireParams, buildParams, addLog, applyResult]);

  const runValidate = useCallback(async () => {
    if (busy || !requireParams()) return;
    setBusy(true);
    addLog("ui-info", "Validando entradas con el motor…");
    try {
      const result = await engineValidate(buildParams());
      applyResult(result, "validate");
    } catch (err) {
      addLog("ui-error", `Error en validate: ${String(err)}`);
    } finally {
      setBusy(false);
    }
  }, [busy, requireParams, buildParams, addLog, applyResult]);

  const runDryRun = useCallback(async () => {
    if (busy || !requireParams()) return;
    setBusy(true);
    addLog("ui-info", "⚠️ Ejecutando DRY-RUN — no se escribirá ninguna SD.");
    try {
      const result = await engineApply(buildParams());
      applyResult(result, "apply --dry-run");
      if (result.success && result.was_dry_run) {
        addLog("ui-success", "Dry-run completado. Ningún archivo fue modificado.");
      }
    } catch (err) {
      addLog("ui-error", `Error en dry-run: ${String(err)}`);
    } finally {
      setBusy(false);
    }
  }, [busy, requireParams, buildParams, addLog, applyResult]);

  // ── File pickers ─────────────────────────────────────────────────────────────

  const pickImage = useCallback(async () => {
    const sel = await open({
      multiple: false,
      filters: [{ name: "Imágenes de disco", extensions: ["img", "xz"] }],
    });
    if (typeof sel === "string") setBaseImage(sel);
  }, []);

  const pickPayload = useCallback(async () => {
    const sel = await open({ multiple: false, directory: true });
    if (typeof sel === "string") setPayload(sel);
  }, []);

  const saveProvision = useCallback(async () => {
    if (provisionErrors.length > 0) {
      addLog("ui-error", provisionErrors.join(" "));
      return;
    }
    const destination = await save({
      defaultPath: provision || "sigil_provision.json",
      filters: [{ name: "JSON", extensions: ["json"] }],
    });
    if (typeof destination !== "string") return;
    setBusy(true);
    try {
      const writtenPath = await engineWriteProvision(destination, provisionDocument);
      setProvision(writtenPath);
      setSavedProvisionJson(provisionJson);
      addLog("ui-success", `Provision no secreto guardado: ${writtenPath}`);
    } catch (error) {
      addLog("ui-error", `No se pudo guardar provision: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  }, [provisionErrors, provision, provisionDocument, provisionJson, addLog]);

  const pickTarget = useCallback(async () => {
    const sel = await open({
      multiple: false,
      filters: [{ name: "Archivo de fixture", extensions: ["img", "bin", "raw"] }],
    });
    if (typeof sel === "string") setTargetDevice(sel);
  }, []);

  // ── Render ───────────────────────────────────────────────────────────────────

  const resultBg = lastResult === null
    ? "var(--bg-deep)"
    : lastResult.success
      ? "var(--success-bg)"
      : "var(--danger-bg)";

  const resultColor = lastResult === null
    ? "var(--text-muted)"
    : lastResult.success
      ? "var(--success)"
      : "var(--danger)";

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>

      {/* ── Safety banner ──────────────────────────────────────────────────── */}
      <div style={{
        padding: "10px 14px",
        borderRadius: "var(--radius-md)",
        background: "var(--warning-bg)",
        border: "1px solid var(--warning)",
        display: "flex", alignItems: "center", gap: 10,
        flexShrink: 0,
      }}>
        <span style={{ fontSize: 18 }}>⚠️</span>
        <div>
          <span style={{ fontSize: 13, fontWeight: 800, color: "var(--warning)" }}>
            Validación / Dry-run — no se escribirá ninguna tarjeta SD.
          </span>
          <p style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>
            El motor flasher-rs sólo soporta validación y simulación. La escritura real en hardware no está implementada.
          </p>
        </div>
      </div>

      {/* ── Engine status row ───────────────────────────────────────────────── */}
      <div className="card" style={{ padding: "14px 16px", display: "flex", flexDirection: "column", gap: 10 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span style={{ fontSize: 13, fontWeight: 700, color: "var(--text-primary)" }}>
            🔧 Motor flasher-rs
          </span>
          <span style={{
            fontSize: 11, fontWeight: 800, padding: "2px 10px",
            borderRadius: "var(--radius-full)",
            background: engineAvailable === null ? "var(--bg-deep)"
              : engineAvailable ? "var(--success-bg)" : "var(--danger-bg)",
            color: engineAvailable === null ? "var(--text-muted)"
              : engineAvailable ? "var(--success)" : "var(--danger)",
          }}>
            {engineAvailable === null ? "NO DETECTADO" : engineAvailable ? "DISPONIBLE" : "NO DISPONIBLE"}
          </span>
        </div>

        <div style={{
          padding: "8px 12px",
          borderRadius: "var(--radius-sm)",
          background: "var(--bg-deep)",
          boxShadow: "var(--shadow-inset-sm)",
          fontFamily: "var(--font-mono)",
          fontSize: 11,
          color: "var(--text-muted)",
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
        }}>
          {enginePath || "(ruta no detectada)"}
        </div>

        <button
          id="btn-detect-engine"
          className="btn btn-secondary"
          onClick={detectEngine}
          disabled={busy}
          style={{ alignSelf: "flex-start" }}
        >
          {busy ? "⏳ Detectando…" : "🔍 Detectar motor"}
        </button>

        {engineAvailable === false && (
          <p style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>
            Si el motor no se encuentra, define la variable de entorno{" "}
            <code style={{ fontFamily: "var(--font-mono)", color: "var(--accent)" }}>SIGIL_HARDWARE_ROOT</code>
            {" "}apuntando al directorio <em>sigil-hardware</em> y reinicia la aplicación.
          </p>
        )}
      </div>

      {/* ── Input paths ─────────────────────────────────────────────────────── */}
      <div className="card" style={{ padding: "14px 16px", display: "flex", flexDirection: "column", gap: 12 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: "0.05em" }}>
          Entradas del Motor
        </span>

        {/* Base image */}
        <div className="form-group">
          <label className="form-label">Imagen Base (.img / .img.xz)</label>
          <div style={{ display: "flex", gap: 6 }}>
            <input
              id="input-base-image"
              type="text"
              className="form-input"
              style={{ flex: 1, fontSize: 12 }}
              value={baseImage}
              onChange={(e) => setBaseImage(e.target.value)}
              placeholder="/ruta/a/imagen.img.xz"
              disabled={busy}
            />
            <button className="btn btn-secondary" onClick={pickImage} disabled={busy} style={{ padding: "8px 12px", flexShrink: 0 }}>
              📂
            </button>
          </div>
        </div>

        {/* SHA-256 */}
        <div className="form-group">
          <label className="form-label">SHA-256 Esperado (64 hex)</label>
          <input
            id="input-sha256"
            type="text"
            className="form-input"
            style={{ fontSize: 12, fontFamily: "var(--font-mono)" }}
            value={sha256}
            onChange={(e) => setSha256(e.target.value)}
            placeholder="acff736ca7945e3b305f07cda4abdb870910e..."
            disabled={busy}
            maxLength={64}
          />
        </div>

        {/* Payload directory */}
        <div className="form-group">
          <label className="form-label">Directorio del Payload SIGIL</label>
          <div style={{ display: "flex", gap: 6 }}>
            <input
              id="input-payload"
              type="text"
              className="form-input"
              style={{ flex: 1, fontSize: 12 }}
              value={payload}
              onChange={(e) => setPayload(e.target.value)}
              placeholder="/ruta/al/payload"
              disabled={busy}
            />
            <button className="btn btn-secondary" onClick={pickPayload} disabled={busy} style={{ padding: "8px 12px", flexShrink: 0 }}>
              📂
            </button>
          </div>
        </div>

        {/* Strict manufacturing provision */}
        <div className="form-group" style={{ gap: 8 }}>
          <label className="form-label">Identidad de fabricación (Obligatoria)</label>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
            <input id="input-serial-number" className="form-input" value={serialNumber} onChange={(e) => setSerialNumber(e.target.value)} placeholder="serial_number · SIGIL-000001" disabled={busy} />
            <input id="input-model" className="form-input" value={productModel} onChange={(e) => setProductModel(e.target.value)} placeholder="model · Sigil-Streamer" disabled={busy} />
            <input id="input-model-version" className="form-input" value={modelVersion} onChange={(e) => setModelVersion(e.target.value)} placeholder="model_version · v1" disabled={busy} />
            <input id="input-batch" className="form-input" value={batch} onChange={(e) => setBatch(e.target.value)} placeholder="batch · 2026-01" disabled={busy} />
          </div>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "var(--text-primary)" }}>
            <input id="input-i2s-dac" type="checkbox" checked={i2sDac} onChange={(e) => setI2sDac(e.target.checked)} disabled={busy} />
            capabilities.i2s_dac (DAC físico declarado)
          </label>
          {provisionErrors.length > 0 && (
            <div style={{ color: "var(--danger)", fontSize: 10 }}>
              {provisionErrors.map((error) => <div key={error}>• {error}</div>)}
            </div>
          )}
          <label className="form-label">Vista previa del provision</label>
          <pre id="provision-preview" style={{ margin: 0, padding: 10, maxHeight: 210, overflow: "auto", borderRadius: "var(--radius-sm)", background: "var(--bg-deep)", color: "var(--text-muted)", fontSize: 10, fontFamily: "var(--font-mono)", whiteSpace: "pre-wrap" }}>
            {provisionJson}
          </pre>
          <div style={{ display: "flex", gap: 6 }}>
            <input id="input-provision" type="text" className="form-input" style={{ flex: 1, fontSize: 12 }} value={provision} readOnly placeholder="Guarda sigil_provision.json" />
            <button id="btn-save-provision" className="btn btn-secondary" onClick={saveProvision} disabled={busy || provisionErrors.length > 0} style={{ padding: "8px 12px", flexShrink: 0 }}>
              Guardar JSON
            </button>
          </div>
          <p style={{ fontSize: 10, color: "var(--text-muted)", marginTop: 2 }}>
            Solo identidad no secreta. El token nunca se incluye en este archivo.
          </p>
        </div>

        {/* Target device (regular file for dry-run) */}
        <div className="form-group">
          <label className="form-label">Archivo Destino (Fixture para Dry-Run)</label>
          <div style={{ display: "flex", gap: 6 }}>
            <input
              id="input-target"
              type="text"
              className="form-input"
              style={{ flex: 1, fontSize: 12 }}
              value={targetDevice}
              onChange={(e) => setTargetDevice(e.target.value)}
              placeholder="/tmp/dummy_target.img"
              disabled={busy}
            />
            <button className="btn btn-secondary" onClick={pickTarget} disabled={busy} style={{ padding: "8px 12px", flexShrink: 0 }}>
              📂
            </button>
          </div>
          <p style={{ fontSize: 10, color: "var(--text-muted)", marginTop: 2 }}>
            Usa un archivo temporal regular. Nunca un dispositivo /dev/*.
          </p>
        </div>
      </div>

      {/* ── Action buttons ──────────────────────────────────────────────────── */}
      <div className="card" style={{ padding: "14px 16px", display: "flex", flexDirection: "column", gap: 10 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: "0.05em" }}>
          Acciones
        </span>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
          <button
            id="btn-build-payload"
            className="btn btn-secondary"
            onClick={buildPayload}
            disabled={busy}
          >
            📦 Generar Payload
          </button>
          <button
            id="btn-validate"
            className="btn btn-secondary"
            onClick={runValidate}
            disabled={busy || !baseImage || !sha256 || !payload}
          >
            ✅ Validar Entradas
          </button>
          <button
            id="btn-plan"
            className="btn btn-secondary"
            onClick={runPlan}
            disabled={busy || !baseImage || !sha256 || !payload}
          >
            📋 Mostrar Plan
          </button>
          <button
            id="btn-dry-run"
            className="btn btn-primary"
            onClick={runDryRun}
            disabled={busy || !baseImage || !sha256 || !payload}
            style={{ gridColumn: "1 / -1" }}
          >
            {busy ? "⏳ Ejecutando…" : "🧪 Ejecutar Dry-Run"}
          </button>
        </div>
        <p style={{ fontSize: 11, color: "var(--text-muted)", textAlign: "center", marginTop: 2 }}>
          ⚠️ Validación / Dry-run — no se escribirá ninguna tarjeta SD.
        </p>
      </div>

      {/* ── Last result badge ───────────────────────────────────────────────── */}
      {lastResult !== null && (
        <div style={{
          padding: "10px 14px",
          borderRadius: "var(--radius-md)",
          background: resultBg,
          display: "flex", alignItems: "center", justifyContent: "space-between",
          flexShrink: 0,
        }}>
          <span style={{ fontSize: 13, fontWeight: 700, color: resultColor }}>
            {lastResult.success
              ? (lastResult.was_dry_run ? "✓ Dry-run completado" : "✓ Correcto")
              : "✗ El motor retornó errores"}
          </span>
          <span style={{
            fontFamily: "var(--font-mono)", fontSize: 11,
            padding: "2px 8px", borderRadius: "var(--radius-full)",
            background: "var(--bg-deep)", color: "var(--text-muted)",
          }}>
            exit {lastResult.exit_code}
            {lastResult.was_dry_run ? " · dry-run" : ""}
          </span>
        </div>
      )}

      {/* ── Output console ──────────────────────────────────────────────────── */}
      <div className="card" style={{ padding: "14px", display: "flex", flexDirection: "column", gap: 8, minHeight: 180 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span style={{ fontSize: 11, fontWeight: 700, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Salida del motor
          </span>
          <div style={{ display: "flex", gap: 6 }}>
            <span style={{
              fontSize: 11, padding: "2px 8px",
              borderRadius: "var(--radius-full)",
              background: "var(--bg-deep)", color: "var(--text-muted)",
            }}>
              {logLines.length} líneas
            </span>
            <button
              className="btn btn-secondary"
              onClick={() => setLogLines([])}
              disabled={busy}
              style={{ padding: "2px 10px", fontSize: 11 }}
            >
              Limpiar
            </button>
          </div>
        </div>

        <div style={{
          flex: 1,
          background: "var(--bg-deep)",
          boxShadow: "var(--shadow-inset)",
          borderRadius: "var(--radius-md)",
          padding: "10px",
          fontFamily: "var(--font-mono)",
          fontSize: 11,
          overflowY: "auto",
          maxHeight: 280,
          display: "flex",
          flexDirection: "column",
          gap: 2,
        }}>
          {logLines.map((line, i) => (
            <div key={i} style={{ display: "flex", gap: 8, lineHeight: 1.5, wordBreak: "break-word" }}>
              <span style={{ color: "var(--text-muted)", flexShrink: 0, fontSize: 10 }}>
                {line.stream === "stderr" ? "[ERR]" : line.stream.startsWith("ui") ? "[APP]" : "[OUT]"}
              </span>
              <span style={{ color: logColor(line.stream), flex: 1 }}>{line.text}</span>
            </div>
          ))}
          <div ref={logEndRef} />
        </div>
      </div>

    </div>
  );
}
