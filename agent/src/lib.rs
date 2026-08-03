//! Núcleo do agente desktop do RemoteOne.
//!
//! A lógica portável (pareamento, protocolo, identidade, cliente) vive nesta
//! biblioteca e é testada em Windows, Linux e macOS pela CI. O binário
//! (`main.rs`) é apenas uma casca fina por cima dela.

pub mod adaptive;
pub mod apps;
pub mod audio;
pub mod capture;
pub mod client;
pub mod clipboard;
pub mod config;
pub mod datachannel;
pub mod files;
pub mod foreground;
pub mod h264;
pub mod identity;
pub mod injector;
pub mod input;
pub mod notify;
pub mod pairing;
pub mod platform;
pub mod power;
pub mod protocol;
pub mod setup;
pub mod system_info;
pub mod webrtc;
pub mod wol;

use std::path::PathBuf;

/// Backend padrão quando ninguém configurou nada: o da própria máquina.
pub const DEFAULT_BACKEND_URL: &str = "ws://127.0.0.1:8000/ws/agent";

/// Diretório onde ficam o `device_id` e a configuração.
///
/// `%APPDATA%\remoteone` no Windows, `~/.config/remoteone` no restante.
/// Deliberadamente **fora** da pasta de instalação: reinstalar ou atualizar não
/// pode obrigar a parear o computador de novo.
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("REMOTEONE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(platform_config_dir)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("remoteone")
}

/// Diretório de configuração do sistema, sem dependência externa.
fn platform_config_dir() -> Option<PathBuf> {
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
    }
}

pub fn device_id_path() -> PathBuf {
    config_dir().join("device_id")
}

pub fn config_path() -> PathBuf {
    config_dir().join("agent.conf")
}

/// A configuração gravada. Arquivo ausente é o caso normal da primeira
/// execução, e vira configuração vazia — não erro.
pub fn load_config() -> config::Config {
    match std::fs::read_to_string(config_path()) {
        Ok(texto) => config::Config::parse(&texto),
        Err(_) => config::Config::new(),
    }
}
