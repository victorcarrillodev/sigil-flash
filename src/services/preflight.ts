import { BundlePair, Device, DeviceConfig, ImageInfo } from '../types/models';
import { validateConfigLocally, validateModelArchitecture } from './validation';

/**
 * Estado de fabricación derivado en un solo sitio. La interfaz no decide por
 * su cuenta si se puede flashear: pregunta aquí, y aquí se explica en una
 * frase accionable qué falta. El backend y el proceso elevado repiten estas
 * comprobaciones por su cuenta; esta es la primera de las tres.
 */

export const STEP_IDS = ['image', 'device', 'config', 'credential'] as const;
export type StepId = (typeof STEP_IDS)[number];

export type StepState = 'pending' | 'active' | 'complete' | 'blocked';

export interface PreflightStep {
  id: StepId;
  title: string;
  state: StepState;
  detail: string | null;
}

export interface PreflightInput {
  image: ImageInfo | null;
  bundle: BundlePair | null;
  bundleError: string | null;
  device: Device | null;
  config: DeviceConfig;
  flashing: boolean;
}

export interface Preflight {
  steps: PreflightStep[];
  blockers: string[];
  warnings: string[];
  canFlash: boolean;
}

const TITLES: Record<StepId, string> = {
  image: 'Imagen y bundle',
  device: 'Dispositivo destino',
  config: 'Configuración',
  credential: 'Credencial de fábrica',
};

export function buildPreflight(input: PreflightInput): Preflight {
  const { image, bundle, bundleError, device, config, flashing } = input;

  const blockers: string[] = [];
  const warnings: string[] = [];

  // ── Paso 1: imagen y su par bundle/payload ────────────────────────────────
  let imageState: StepState;
  let imageDetail: string | null = null;

  if (!image) {
    imageState = 'active';
    blockers.push('Seleccione una imagen oficial de Raspberry Pi OS');
  } else if (bundleError) {
    imageState = 'blocked';
    imageDetail = image.name;
    blockers.push(bundleError);
  } else if (!bundle) {
    imageState = 'active';
    imageDetail = image.name;
    blockers.push('Resolviendo el bundle de la imagen seleccionada...');
  } else {
    imageState = 'complete';
    imageDetail = `${bundle.contract_name} · ${bundle.architecture}`;
  }

  // Modelo contra arquitectura de la imagen. Se comprueba en cuanto hay bundle
  // y modelo, sin esperar al resto: una combinación imposible produce una
  // tarjeta que no arranca, y descubrirlo al final cuesta una fabricación
  // entera. El backend lo repite por su cuenta.
  const modelArchError = validateModelArchitecture(config.rpiModel, bundle?.architecture);
  if (modelArchError) {
    imageState = 'blocked';
    blockers.push(modelArchError);
  }

  // ── Paso 2: dispositivo destino ───────────────────────────────────────────
  let deviceState: StepState;
  if (!device) {
    deviceState = imageState === 'complete' ? 'active' : 'pending';
    blockers.push('Seleccione la microSD o el disco extraíble de destino');
  } else {
    deviceState = 'complete';
  }

  // ── Paso 3: configuración del dispositivo ─────────────────────────────────
  const configErrors = validateConfigLocally(config);
  let configState: StepState;
  if (configErrors.length > 0) {
    const prevStepsReady = imageState === 'complete' && deviceState === 'complete';
    configState = prevStepsReady ? 'blocked' : 'pending';
    blockers.push(...configErrors);
  } else {
    configState = 'complete';
  }

  // ── Paso 4: credencial de enrolamiento ────────────────────────────────────
  let credentialState: StepState;
  if (!config.apiKey) {
    const prevStepsReady = imageState === 'complete' && deviceState === 'complete' && configState === 'complete';
    credentialState = prevStepsReady ? 'active' : 'pending';
    blockers.push(
      'Solicite la credencial de enrolamiento: sin ella el equipo no podría enrolarse en el primer arranque'
    );
  } else {
    credentialState = 'complete';
  }

  const steps: PreflightStep[] = [
    { id: 'image', title: TITLES.image, state: imageState, detail: imageDetail },
    { id: 'device', title: TITLES.device, state: deviceState, detail: device ? device.path : null },
    {
      id: 'config',
      title: TITLES.config,
      state: configState,
      detail: config.serialNumber || null,
    },
    {
      id: 'credential',
      title: TITLES.credential,
      state: credentialState,
      detail: config.apiKey ? 'Obtenida' : null,
    },
  ];

  return {
    steps,
    blockers,
    warnings,
    canFlash: blockers.length === 0 && !flashing,
  };
}

/** El paso que el operario debe atender ahora mismo. */
export function currentStepId(steps: PreflightStep[]): StepId {
  const pending = steps.find((s) => s.state === 'blocked' || s.state === 'active');
  return pending ? pending.id : steps[steps.length - 1].id;
}
