//! Exibe o código de pareamento sem depender de um terminal aberto.
//!
//! Quando o agente roda em segundo plano (tarefa agendada, sem console), o
//! `println!` do código não é visto por ninguém. Por isso também:
//!  - grava o código num arquivo (`%APPDATA%\remoteone\pairing-code.txt`);
//!  - no Windows, mostra uma janelinha (MessageBox) no desktop do usuário.

use std::path::PathBuf;

/// Anuncia o código de pareamento por vias que não exigem terminal.
pub fn announce_pairing_code(code: &str, expires_in_seconds: u64) {
    if let Some(path) = code_file_path() {
        write_code_file(&path, code, expires_in_seconds);
    }
    imp::popup(code, expires_in_seconds);
}

/// Remove o arquivo do código depois que o dispositivo é pareado (limpeza).
pub fn clear_pairing_code() {
    if let Some(path) = code_file_path() {
        let _ = std::fs::remove_file(path);
    }
}

fn write_code_file(path: &PathBuf, code: &str, expires_in_seconds: u64) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let minutes = expires_in_seconds / 60;
    let body = format!(
        "Código de pareamento do RemoteOne: {code}\n\
         Expira em {minutes} min. Informe este código no aplicativo.\n"
    );
    let _ = std::fs::write(path, body);
}

fn code_file_path() -> Option<PathBuf> {
    config_base().map(|b| b.join("remoteone").join("pairing-code.txt"))
}

/// Base de configuração, honrando REMOTEONE_CONFIG_DIR (igual ao main.rs).
fn config_base() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("REMOTEONE_CONFIG_DIR") {
        return Some(PathBuf::from(dir));
    }
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
    }
}

#[cfg(windows)]
mod imp {
    use std::process::Command;

    pub fn popup(code: &str, expires_in_seconds: u64) {
        let minutes = expires_in_seconds / 60;
        // Texto ASCII para evitar problemas de code page ao passar o argumento.
        // O `code` vem de um alfabeto fixo [A-Z2-9], sem aspas: seguro na string.
        let message =
            format!("Codigo de pareamento: {code}  (expira em {minutes} min). Informe no app.");
        let script = format!(
            "Add-Type -AssemblyName System.Windows.Forms; \
             [System.Windows.Forms.MessageBox]::Show('{message}','RemoteOne - pareamento') | Out-Null"
        );
        // Dispara e segue a vida: a janela é modal para o usuário, não para nós.
        let _ = Command::new("powershell")
            .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script])
            .spawn();
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn popup(_code: &str, _expires_in_seconds: u64) {
        // Sem GUI fora do Windows: o arquivo + o println! já bastam no dev.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_code_file_with_code_and_expiry() {
        let dir = std::env::temp_dir().join(format!("remoteone-notify-{}", std::process::id()));
        let path = dir.join("pairing-code.txt");
        write_code_file(&path, "ABC23XYZK", 600);
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("ABC23XYZK"));
        assert!(content.contains("10 min"));
        std::fs::remove_dir_all(&dir).ok();
    }
}
