//! Camada de abstração de plataforma.
//!
//! Toda chamada específica de sistema operacional (captura de tela, injeção
//! de mouse/teclado, energia, monitoramento de hardware) deve passar por
//! este trait. O restante do agente permanece portável e testável em
//! qualquer sistema, inclusive nos runners de CI.

pub trait Platform: Send + Sync {
    /// Identificador do sistema operacional ("windows", "linux", "macos").
    fn os_name(&self) -> &'static str;

    /// Indica se a captura de tela já foi implementada nesta plataforma.
    /// As próximas etapas substituem este stub pela implementação real.
    fn supports_screen_capture(&self) -> bool {
        false
    }
}

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
pub use windows::CurrentPlatform;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::CurrentPlatform;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::CurrentPlatform;

/// Retorna a implementação da plataforma em que o agente está rodando.
pub fn current() -> CurrentPlatform {
    CurrentPlatform
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_platform_reports_os_name() {
        let os = current().os_name();
        assert!(["windows", "linux", "macos"].contains(&os));
    }
}
