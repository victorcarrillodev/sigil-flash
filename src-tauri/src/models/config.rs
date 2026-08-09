use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
    pub model_name: Option<String>,
    #[serde(rename = "sigilModelVersion", default)]
    pub model_version: Option<String>,
    #[serde(rename = "panelPin")]
    pub panel_pin: Option<String>,
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
    #[serde(rename = "serverUrl", default)]
    pub server_url: Option<String>,
}

impl Default for DeviceConfig {
    fn default() -> Self {
        Self {
            hostname: "sigil-device".to_string(),
            username: "sigil".to_string(), // Coincide con sigil-hardware/manifests/system-config.json
            password: None,
            wifi_ssid: None,
            wifi_password: None,
            ssh_enabled: false,
            rpi_model: Some("raspberry-pi-zero-2-w".to_string()),
            serial_number: None,
            device_id: None,
            model_name: Some("SIGIL Audio Terminal".to_string()),
            model_version: Some("1.0.0".to_string()),
            panel_pin: None,
            api_key: None,
            server_url: Some("https://sigil-server.sphinx-pickerel.ts.net".to_string()),
        }
    }
}
