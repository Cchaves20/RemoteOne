use std::time::Duration;

use remoteone_agent::client::{self, AgentIdentity, StreamConfig};
use remoteone_agent::config::{resolve, Config};
use remoteone_agent::identity::load_or_create_device_id;
use remoteone_agent::platform::{self, Platform};
use remoteone_agent::{device_id_path, load_config, setup, DEFAULT_BACKEND_URL};

const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const HEARTBEAT_SECS: u64 = 10;
const RECONNECT_SECS: u64 = 5;

/// O que a linha de comando pediu.
///
/// Um `match` sobre `&str` em vez de uma biblioteca de argumentos: são quatro
/// comandos e uma opção. `clap` traria meio megabyte de binário e uma
/// dependência para resolver um problema que ainda não existe.
enum Cmd {
    Run,
    Install { backend: Option<String> },
    Uninstall,
    Status,
    Help,
}

fn parse_args(args: &[String]) -> Cmd {
    match args.first().map(String::as_str) {
        None => Cmd::Run,
        Some("install") => {
            // `install --backend URL` ou `install URL`: as duas formas, porque
            // quem digita isto uma vez na vida não vai lembrar da flag.
            let backend = args
                .iter()
                .skip(1)
                .find(|a| !a.starts_with("--"))
                .or_else(|| {
                    args.iter()
                        .position(|a| a == "--backend")
                        .and_then(|i| args.get(i + 1))
                })
                .cloned();
            Cmd::Install { backend }
        }
        Some("uninstall") | Some("remove") => Cmd::Uninstall,
        Some("status") => Cmd::Status,
        Some("run") => Cmd::Run,
        _ => Cmd::Help,
    }
}

const HELP: &str = "\
RemoteOne Agent — controla este computador pelo celular.

  remoteone-agent                    roda o agente (o que acontece ao dar
                                     dois cliques no executável)
  remoteone-agent install [URL]      instala: passa a subir junto com o
                                     Windows, oculto, e aparece em
                                     \"Aplicativos instalados\"
  remoteone-agent uninstall          desfaz a instalação
  remoteone-agent status             onde está instalado e para onde aponta

A URL é a do backend (ex.: wss://seu-servidor/ws/agent). Sem ela, vale a que
já estiver configurada, ou o servidor da própria máquina.

Não precisa de administrador: a instalação é da sua conta de usuário.";

/// Lê um número da configuração (ambiente ou arquivo), com padrão.
fn cfg_u32(file: &Config, name: &str, default: u32) -> u32 {
    resolve(file, name)
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match parse_args(&args) {
        Cmd::Help => {
            println!("{HELP}");
            return;
        }
        Cmd::Install { backend } => {
            if let Err(e) = setup::install(backend.as_deref()) {
                eprintln!("Não consegui instalar: {e}");
                std::process::exit(1);
            }
            return;
        }
        Cmd::Uninstall => {
            if let Err(e) = setup::uninstall() {
                eprintln!("Não consegui desinstalar: {e}");
                std::process::exit(1);
            }
            return;
        }
        Cmd::Status => {
            for linha in setup::status_lines(&setup::status()) {
                println!("{linha}");
            }
            return;
        }
        Cmd::Run => {}
    }

    let plat = platform::current();
    let cfg = load_config();
    let url = resolve(&cfg, "REMOTEONE_BACKEND_URL")
        .unwrap_or_else(|| DEFAULT_BACKEND_URL.to_string());

    let device_id = load_or_create_device_id(&device_id_path())
        .expect("não foi possível ler/criar o device_id");
    let hostname = gethostname::gethostname().to_string_lossy().to_string();

    // MAC da placa de rede local (para Wake-on-LAN). Best-effort: se não
    // resolver, segue sem — só o WoL fica indisponível para esta máquina.
    let mac = mac_address::get_mac_address()
        .ok()
        .flatten()
        .map(|m| m.to_string());

    let identity = AgentIdentity {
        device_id: device_id.clone(),
        hostname,
        os: plat.os_name().to_string(),
        agent_version: AGENT_VERSION.to_string(),
        mac,
    };

    // Parâmetros de transmissão (ajustáveis sem recompilar).
    let default = StreamConfig::default();
    let stream = StreamConfig {
        fps: cfg_u32(&cfg, "REMOTEONE_STREAM_FPS", default.fps),
        max_width: cfg_u32(&cfg, "REMOTEONE_STREAM_MAX_WIDTH", default.max_width),
        quality: cfg_u32(&cfg, "REMOTEONE_STREAM_QUALITY", default.quality as u32) as u8,
        video_bitrate: cfg_u32(&cfg, "REMOTEONE_VIDEO_BITRATE", default.video_bitrate),
        video_fps: cfg_u32(&cfg, "REMOTEONE_VIDEO_FPS", default.video_fps),
        video_max_width: cfg_u32(&cfg, "REMOTEONE_VIDEO_MAX_WIDTH", default.video_max_width),
        // Lista separada por vírgulas; vazio desliga o STUN (só rede local).
        ice_servers: match resolve(&cfg, "REMOTEONE_ICE_SERVERS") {
            None => default.ice_servers.clone(),
            Some(list) => list
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
        },
    };

    println!(
        "RemoteOne Agent {AGENT_VERSION} — sistema: {}",
        plat.os_name()
    );
    println!("device_id: {device_id}");
    println!(
        "Tela: {} fps, largura máx. {}px, qualidade {} (JPEG)",
        stream.fps, stream.max_width, stream.quality
    );
    println!(
        "Vídeo: H.264 a {} fps, largura máx. {}px, {} kbps, STUN: {}",
        stream.video_fps,
        stream.video_max_width,
        stream.video_bitrate / 1000,
        if stream.ice_servers.is_empty() {
            "nenhum (só rede local)".to_string()
        } else {
            stream.ice_servers.join(", ")
        }
    );
    println!("Conectando a {url} ...");

    // Laço de reconexão: se a conexão cair, espera e tenta de novo.
    loop {
        // `stream` é clonado a cada tentativa: a config carrega a lista de
        // servidores STUN, então não é mais `Copy`.
        if let Err(e) = client::run(
            &url,
            &identity,
            Duration::from_secs(HEARTBEAT_SECS),
            stream.clone(),
        )
        .await
        {
            eprintln!("Conexão perdida: {e}");
        }
        println!("Reconectando em {RECONNECT_SECS}s ...");
        tokio::time::sleep(Duration::from_secs(RECONNECT_SECS)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn sem_argumento_o_agente_roda() {
        // É o que acontece ao dar dois cliques no executável, e é o caso mais
        // comum: quem instalou não digita nada nunca mais.
        assert!(matches!(parse_args(&args(&[])), Cmd::Run));
        assert!(matches!(parse_args(&args(&["run"])), Cmd::Run));
    }

    #[test]
    fn install_aceita_a_url_com_e_sem_flag() {
        // Quem digita isto uma vez na vida não vai lembrar da flag.
        let com = parse_args(&args(&["install", "--backend", "wss://x/ws/agent"]));
        let sem = parse_args(&args(&["install", "wss://x/ws/agent"]));
        for c in [com, sem] {
            match c {
                Cmd::Install { backend } => {
                    assert_eq!(backend.as_deref(), Some("wss://x/ws/agent"))
                }
                _ => panic!("deveria ser install"),
            }
        }
    }

    #[test]
    fn install_sem_url_mantem_a_configuracao_atual() {
        // Reinstalar por cima de uma versão nova não pode apagar o servidor
        // que já estava configurado.
        match parse_args(&args(&["install"])) {
            Cmd::Install { backend } => assert!(backend.is_none()),
            _ => panic!("deveria ser install"),
        }
    }

    #[test]
    fn desinstalar_atende_pelos_dois_nomes() {
        assert!(matches!(parse_args(&args(&["uninstall"])), Cmd::Uninstall));
        assert!(matches!(parse_args(&args(&["remove"])), Cmd::Uninstall));
    }

    #[test]
    fn comando_desconhecido_mostra_a_ajuda() {
        // E não roda o agente: quem digitou errado quer saber o que existe, não
        // ficar com um processo em segundo plano que não pediu.
        assert!(matches!(parse_args(&args(&["instal"])), Cmd::Help));
        assert!(matches!(parse_args(&args(&["--help"])), Cmd::Help));
    }

    #[test]
    fn a_configuracao_do_arquivo_vale_para_os_numeros() {
        let cfg = Config::parse("REMOTEONE_VIDEO_FPS=24\n");
        assert_eq!(cfg_u32(&cfg, "REMOTEONE_VIDEO_FPS", 30), 24);
        // Chave ausente ou ilegível cai no padrão em vez de zerar o valor.
        assert_eq!(cfg_u32(&cfg, "NAO_EXISTE", 30), 30);
        let ruim = Config::parse("REMOTEONE_VIDEO_FPS=trinta\n");
        assert_eq!(cfg_u32(&ruim, "REMOTEONE_VIDEO_FPS", 30), 30);
    }
}
