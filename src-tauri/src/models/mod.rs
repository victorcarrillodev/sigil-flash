use serde::{Deserialize, Serialize};

/// Represents information about a system image selected for flashing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageInfo {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub sha256: Option<String>,
}

/// Represents a block storage device suitable for flashing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub name: String,
    pub path: String,
    pub size: String,
    pub model: String,
    #[serde(rename = "type")]
    pub device_type: String, // e.g. "disk", "loop"
    pub removable: bool,
    pub transport: String, // e.g. "usb", "mmc", "sata"
}

/// Progress state sent periodically over IPC to the React frontend.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlashProgress {
    pub bytes_written: u64,
    pub total_bytes: u64,
    pub speed_mbps: f64,
    pub eta_seconds: f64,
    pub status: String, // "idle" | "running" | "verifying" | "done" | "error" | "cancelled"
    pub message: String,
}

/// Manufacturing configuration consumed by the elevated image-preparation flow.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceConfig {
    pub hostname: String,
    pub username: String,
    pub password: Option<String>,
    #[serde(rename = "wifiSsid")]
    pub wifi_ssid: Option<String>,
    #[serde(rename = "wifiPassword")]
    pub wifi_password: Option<String>,
    #[serde(rename = "sshEnabled")]
    pub ssh_enabled: bool,
    #[serde(rename = "rpiModel")]
    pub rpi_model: Option<String>,
    #[serde(rename = "serialNumber")]
    pub serial_number: Option<String>,
    #[serde(rename = "deviceId", default)]
    pub device_id: Option<String>,
    #[serde(rename = "sigilModel", default)]
    pub sigil_model: Option<String>,
    #[serde(rename = "sigilModelVersion", default)]
    pub sigil_model_version: Option<String>,
    #[serde(rename = "panelPin")]
    pub panel_pin: Option<String>,
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
}
