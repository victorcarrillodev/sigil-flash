use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Device {
    pub name: String,
    pub path: String,
    pub size: String,
    pub model: String,
    #[serde(rename = "type")]
    pub device_type: String,
    pub removable: bool,
    pub transport: String,
}
