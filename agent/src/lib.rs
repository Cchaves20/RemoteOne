//! Núcleo do agente desktop do RemoteOne.
//!
//! A lógica portável (pareamento, protocolo, identidade, cliente) vive nesta
//! biblioteca e é testada em Windows, Linux e macOS pela CI. O binário
//! (`main.rs`) é apenas uma casca fina por cima dela.

pub mod adaptive;
pub mod apps;
pub mod audio;
pub mod awake;
pub mod capture;
pub mod client;
pub mod clipboard;
pub mod config;
pub mod datachannel;
pub mod files;
pub mod foreground;
pub mod gui;
pub mod h264;
pub mod identity;
pub mod instance;
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

/// Registra uma linha no diário do agente.
///
/// Existe porque o agente instalado roda **sem console**: sobe pelo `wscript`,
/// oculto, e todo `println!`/`eprintln!` cai no vazio. Enquanto foi só um
/// programa de terminal isso não incomodou; com janela e bandeja, passou a
/// haver falha que só acontece na máquina instalada - e sem registro nenhum a
/// investigação vira adivinhação.
///
/// Sem data e sem níveis: o valor está em existir, e um formato elaborado só
/// adiaria a primeira linha útil. Falha ao gravar é ignorada de propósito - um
/// diário que derruba o programa que ele deveria explicar seria o pior dos
/// dois mundos.
pub fn diario(linha: &str) {
    use std::io::Write;
    println!("{linha}");
    let caminho = config_dir().join("agent.log");
    if let Some(pai) = caminho.parent() {
        let _ = std::fs::create_dir_all(pai);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&caminho)
    {
        let _ = writeln!(f, "{linha}");
    }
}

/// Grava a configuração, criando a pasta se preciso.
///
/// Existe porque agora há dois lugares que escrevem aqui: o `install`, que
/// guarda a URL do backend, e o agente em execução, quando o app liga ou
/// desliga o "manter pronto". Uma escolha feita no telefone precisa sobreviver
/// ao próximo login — senão ela vale até a máquina reiniciar e ninguém entende
/// por que voltou sozinha.
pub fn save_config(cfg: &config::Config) -> Result<(), String> {
    let caminho = config_path();
    if let Some(pai) = caminho.parent() {
        let _ = std::fs::create_dir_all(pai);
    }
    std::fs::write(&caminho, cfg.to_text())
        .map_err(|e| format!("não consegui gravar {}: {e}", caminho.display()))
}
