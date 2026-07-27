//! Controle de energia do computador (desligar, reiniciar, suspender).
//!
//! Real no Windows (via `shutdown`/`rundll32`); nas demais plataformas é um
//! stub que apenas registra a intenção — assim o agente compila e roda no
//! Linux/macOS de desenvolvimento sem executar nada destrutivo.

use crate::protocol::PowerAction;

/// Executa a ação de energia solicitada.
pub fn apply(action: PowerAction) -> Result<(), String> {
    imp::apply(action)
}

#[cfg(windows)]
mod imp {
    use std::process::Command;

    use crate::protocol::PowerAction;

    pub fn apply(action: PowerAction) -> Result<(), String> {
        let status = match action {
            // /t 0 = sem contagem regressiva; /f força fechar apps travados.
            PowerAction::Shutdown => Command::new("shutdown")
                .args(["/s", "/f", "/t", "0"])
                .status(),
            PowerAction::Restart => Command::new("shutdown")
                .args(["/r", "/f", "/t", "0"])
                .status(),
            // Suspende (S3). O 2º parâmetro 0 = suspender (não hibernar).
            PowerAction::Suspend => Command::new("rundll32.exe")
                .args(["powrprof.dll,SetSuspendState", "0,1,0"])
                .status(),
        };
        match status {
            Ok(s) if s.success() => Ok(()),
            Ok(s) => Err(format!("comando de energia falhou (código {s})")),
            Err(e) => Err(format!("não foi possível executar o comando: {e}")),
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use crate::protocol::PowerAction;

    pub fn apply(action: PowerAction) -> Result<(), String> {
        println!("[power-stub] ação de energia solicitada: {action:?} (ignorada fora do Windows)");
        Ok(())
    }
}
