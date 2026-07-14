use std::fmt;

use serde::{Deserialize, Serialize};

/// Strict manufacturing provision contract accepted by the engine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provision {
    #[serde(rename = "_schema_version")]
    pub schema_version: String,
    pub serial_number: String,
    pub model: String,
    pub model_version: String,
    pub batch: String,
    pub capabilities: Capabilities,
}

/// Declared physical hardware. This metadata never participates in authentication.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    pub i2s_dac: bool,
}

/// A complete customization plan with labeled sections.
pub struct Plan {
    pub title: String,
    pub sections: Vec<PlanSection>,
}

/// A named section within a plan, containing lines of text.
pub struct PlanSection {
    pub title: String,
    pub lines: Vec<String>,
}

/// Result of a validation check.
pub struct ValidationResult {
    pub valid: bool,
    pub items: Vec<ValidationItem>,
}

/// A single validation finding.
pub struct ValidationItem {
    pub severity: Severity,
    pub message: String,
}

/// Severity level for validation items.
#[derive(Debug, Clone, PartialEq)]
pub enum Severity {
    Error,
    Warning,
    Info,
}

impl fmt::Display for Severity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Severity::Error => write!(f, "ERROR"),
            Severity::Warning => write!(f, "WARNING"),
            Severity::Info => write!(f, "INFO"),
        }
    }
}

/// Engine metadata and capabilities.
pub struct EngineStatus {
    pub name: String,
    pub version: &'static str,
    pub description: &'static str,
    pub phase: &'static str,
    pub capabilities: Vec<&'static str>,
    pub core_packages: &'static [&'static str],
    pub optional_packages: &'static [&'static str],
    pub services_enable: &'static [&'static str],
    pub services_disable: &'static [&'static str],
}

// ═══════════════════════════════════════════════════════════════════════
// Behavior Model Constants
// ═══════════════════════════════════════════════════════════════════════

/// Core apt packages required for Sigil OS (always installed).
pub const CORE_PACKAGES: &[&str] = &[
    "python3",
    "python3-flask",
    "python3-bluez",
    "network-manager",
    "bluez",
    "bluetooth",
    "pulseaudio",
    "pulseaudio-utils",
    "pulseaudio-module-bluetooth",
    "alsa-utils",
    "mpg123",
    "hostapd",
    "dnsmasq",
    "wireless-tools",
    "rfkill",
    "iw",
    "sudo",
    "curl",
    "firmware-brcm80211",
    "wireless-regdb",
    "raspi-utils",
    "python3-pip",
];

/// Optional packages (factory/debug only, disabled by default).
pub const OPTIONAL_PACKAGES: &[&str] = &["openssh-server"];

/// Services to enable in the customized image.
pub const SERVICES_ENABLE: &[&str] = &[
    "NetworkManager",
    "bluetooth-panel",
    "bt-connect",
    "radio-stream",
    "sigil-leds",
    "wifi-fallback",
];

/// Services to disable in the customized image.
pub const SERVICES_DISABLE: &[&str] = &["hostapd", "dnsmasq"];

/// Services to unmask before disable (in case base image masks them).
pub const SERVICES_UNMASK: &[&str] = &["hostapd", "dnsmasq"];

/// Files and directories to copy from payload into rootfs.
pub const CONFIG_COPIES: &[&str] = &[
    "panel/ -> /home/sigil/",
    "scripts/ -> /usr/local/bin/",
    "services/ -> /etc/systemd/system/",
    "conf/bluetooth-main.conf -> /etc/bluetooth/main.conf",
    "conf/pulse-daemon.conf -> /etc/pulse/daemon.conf",
    "conf/dnsmasq.conf -> /etc/dnsmasq.conf",
    "conf/hostapd.conf -> /etc/hostapd/hostapd.conf",
    "conf/sigil-network.sudoers -> /etc/sudoers.d/sigil-network",
    "conf/99-sigil-mac-fixed.conf -> /etc/NetworkManager/conf.d/99-sigil-mac-fixed.conf",
];

/// Boot config.txt changes for DAC PCM5102.
pub const BOOT_CONFIG_CHANGES: &[&str] = &[
    "detect /boot/firmware/config.txt or /boot/config.txt",
    "when capabilities.i2s_dac=true: change dtparam=audio=on to dtparam=audio=off",
    "when capabilities.i2s_dac=true: add dtoverlay=hifiberry-dac if missing",
    "otherwise: remove dtoverlay=hifiberry-dac and persist SIGIL_I2S_DAC_PRESENT=0",
];

/// User creation parameters.
pub const USER_NAME: &str = "sigil";
pub const USER_UID: &str = "1001";
pub const USER_SHELL: &str = "/bin/bash";
pub const USER_HOME: &str = "/home/sigil";
pub const USER_GROUP: &str = "sudo";

/// Groups the sigil user is added to.
pub const USER_GROUPS: &[&str] = &[
    "bluetooth",
    "audio",
    "pulse-access",
    "netdev",
    "gpio",
    "i2c",
    "spi",
];

/// State directories to create in the rootfs.
pub const STATE_DIRECTORIES: &[&str] = &["/var/lib/wifi-manager", "/var/lib/sigil", "/etc/sigil"];

/// State files with owner:group and mode.
pub const STATE_FILES: &[(&str, &str, &str)] = &[
    ("/home/sigil/preferred_bt.txt", "sigil:sigil", "644"),
    ("/home/sigil/now_playing.txt", "sigil:sigil", "644"),
];

/// Log files with owner:group and mode.
pub const LOG_FILES: &[(&str, &str, &str)] = &[
    ("/var/log/bt-connect.log", "sigil:sigil", "644"),
    ("/var/log/radio-stream.log", "sigil:sigil", "644"),
    ("/var/log/wifi-fallback.log", "sigil:sigil", "644"),
    ("/var/log/wifi-manager.log", "sigil:sigil", "644"),
];

/// Responsibilities that firstboot must handle (not the flasher).
pub const FIRSTBOOT_RESPONSIBILITIES: &[&str] = &[
    "generate machine-id",
    "derive hostname from serial or cpu_serial",
    "atomically persist manufacturing identity in /etc/sigil/device.conf",
    "persist capabilities.i2s_dac in /etc/sigil/audio.conf",
    "create /etc/sigil/panel.env with real secret",
    "apply sigil_provision.json and remove from boot",
    "verify ownership and permissions",
    "clean up provision file from boot partition",
];

/// Items deferred to runtime/firstboot (documented for clarity).
pub const DEFERRED_ITEMS: &[(&str, &str)] = &[
    (
        "user lingering (loginctl enable-linger)",
        "runtime/firstboot",
    ),
    ("dhcpcd denyinterfaces wlan0", "runtime if dhcpcd present"),
];
