use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FlashProgress {
    pub bytes_written: u64,
    pub total_bytes: u64,
    pub speed_mbps: f64,
    pub eta_seconds: f64,
    /// Estados posibles: idle | running | verifying | done | error | cancelled
    pub status: String,
    pub message: String,
}

impl FlashProgress {
    pub fn idle() -> Self {
        Self {
            bytes_written: 0,
            total_bytes: 0,
            speed_mbps: 0.0,
            eta_seconds: 0.0,
            status: "idle".to_string(),
            message: "Listo para flashear".to_string(),
        }
    }
}
