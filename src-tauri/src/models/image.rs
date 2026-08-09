use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImageInfo {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub sha256: Option<String>,
}
