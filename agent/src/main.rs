use std::path::PathBuf;
use std::time::Duration;

use remoteone_agent::client::{self, AgentIdentity, StreamConfig};
use remoteone_agent::identity::load_or_create_device_id;
use remoteone_agent::platform::{self, Platform};

const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_BACKEND_URL: &str = "ws://127.0.0.1:8000/ws/agent";
const HEARTBEAT_SECS: u64 = 10;
const RECONNECT_SECS: u64 = 5;

/// Lê uma variável de ambiente como u32, com fallback ao valor padrão.
fn env_u32(name: &str, default: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn device_id_path() -> PathBuf {
    // Guarda o id no diretório de configuração do usuário quando disponível,
    // com fallback para o diretório atual.
    let base = std::env::var_os("REMOTEONE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(dirs_config)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("remoteone").join("device_id")
}

/// Diretório de configuração multiplataforma sem dependência externa:
/// %APPDATA% no Windows, $XDG_CONFIG_HOME/~/.config no restante.
fn dirs_config() -> Option<PathBuf> {
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
    }
}

#[tokio::main]
async fn main() {
    let plat = platform::current();
    let url =
        std::env::var("REMOTEONE_BACKEND_URL").unwrap_or_else(|_| DEFAULT_BACKEND_URL.to_string());

    let device_id = load_or_create_device_id(&device_id_path())
        .expect("não foi possível ler/criar o device_id");
    let hostname = gethostname::gethostname().to_string_lossy().to_string();

    let identity = AgentIdentity {
        device_id: device_id.clone(),
        hostname,
        os: plat.os_name().to_string(),
        agent_version: AGENT_VERSION.to_string(),
    };

    // Parâmetros de transmissão (ajustáveis sem recompilar).
    let default = StreamConfig::default();
    let stream = StreamConfig {
        fps: env_u32("REMOTEONE_STREAM_FPS", default.fps),
        max_width: env_u32("REMOTEONE_STREAM_MAX_WIDTH", default.max_width),
        quality: env_u32("REMOTEONE_STREAM_QUALITY", default.quality as u32) as u8,
    };

    println!(
        "RemoteOne Agent {AGENT_VERSION} — sistema: {}",
        plat.os_name()
    );
    println!("device_id: {device_id}");
    println!(
        "Tela: {} fps, largura máx. {}px, qualidade {}",
        stream.fps, stream.max_width, stream.quality
    );
    println!("Conectando a {url} ...");

    // Laço de reconexão: se a conexão cair, espera e tenta de novo.
    loop {
        if let Err(e) =
            client::run(&url, &identity, Duration::from_secs(HEARTBEAT_SECS), stream).await
        {
            eprintln!("Conexão perdida: {e}");
        }
        println!("Reconectando em {RECONNECT_SECS}s ...");
        tokio::time::sleep(Duration::from_secs(RECONNECT_SECS)).await;
    }
}
