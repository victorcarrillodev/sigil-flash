export interface ImageInfo {
  path: string;
  name: string;
  size: number;
  sha256?: string | null;
}

export interface Device {
  name: string;
  path: string;
  size: string;
  model: string;
  type: string;
  removable: boolean;
  transport: string;
}

export interface FlashProgress {
  bytes_written: number;
  total_bytes: number;
  speed_mbps: number;
  eta_seconds: number;
  status: 'idle' | 'running' | 'verifying' | 'done' | 'error' | 'cancelled';
  message: string;
}

export interface BundlePair {
  contract_name: string;
  repo: string;
  payload: string;
  architecture: string;
  base_image_name: string;
  base_image_sha256: string;
}

export interface DeviceConfig {
  hostname: string;
  username: string;
  password?: string | null;
  wifiSsid?: string | null;
  wifiPassword?: string | null;
  sshEnabled: boolean;
  rpiModel?: string | null;
  serialNumber?: string | null;
  sigilModel?: string | null;
  sigilModelVersion?: string | null;
  panelPin?: string | null;
  apiKey?: string | null;
  serverUrl?: string | null;
}
