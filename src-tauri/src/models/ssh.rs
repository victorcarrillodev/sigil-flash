use serde::Serialize;

/// Estado final de una sesión SSH que terminó por sí sola (el operario cerró
/// sesión, la red cayó, el host rechazó la autenticación...). Un cierre que
/// el propio operario pidió con "Desconectar" no emite esto: ya lo sabe.
#[derive(Debug, Clone, Serialize)]
pub struct SshExitInfo {
    pub code: Option<i32>,
    pub message: String,
}
