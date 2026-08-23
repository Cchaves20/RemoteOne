use std::time::Duration;

use deskside_agent::client::{self, AgentIdentity, StreamConfig};
use deskside_agent::config::{resolve, Config};
use deskside_agent::identity::load_or_create_device_id;
use deskside_agent::platform::{self, Platform};
use deskside_agent::{device_id_path, load_config, setup, DEFAULT_BACKEND_URL};

const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const HEARTBEAT_SECS: u64 = 10;
// A regra da espera entre tentativas mora em `client::proxima_espera`, com a
// explicação e os testes. Aqui só se aplica.

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
Deskside Agent — controla este computador pelo celular.

  deskside-agent                    roda o agente (o que acontece ao dar
                                     dois cliques no executável)
  deskside-agent install [URL]      instala: passa a subir junto com o
                                     Windows, oculto, e aparece em
                                     \"Aplicativos instalados\"
  deskside-agent uninstall          desfaz a instalação
  deskside-agent status             onde está instalado e para onde aponta

A URL é a do backend (ex.: wss://seu-servidor/ws/agent). Sem ela, vale a que
já estiver configurada e, na primeira instalação, o servidor do Deskside -
então instalar sem argumento nenhum já funciona. Veja para onde aponta com
`deskside-agent status`.

Não precisa de administrador: a instalação é da sua conta de usuário.";

/// Lê um número da configuração (ambiente ou arquivo), com padrão.
fn cfg_u32(file: &Config, name: &str, default: u32) -> u32 {
    resolve(file, name)
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Lê um liga/desliga da configuração.
///
/// Aceita as escritas que alguém usaria à mão num arquivo de texto. Valor
/// irreconhecível cai no padrão em vez de virar `false`: um erro de digitação
/// não pode desligar em silêncio o que mantém o computador alcançável.
fn cfg_bool(file: &Config, name: &str, default: bool) -> bool {
    match resolve(file, name) {
        None => default,
        Some(v) => match v.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "sim" | "yes" | "on" => true,
            "0" | "false" | "nao" | "não" | "no" | "off" => false,
            outro => {
                eprintln!("{name}: não entendi \"{outro}\"; mantendo o padrão ({default})");
                default
            }
        },
    }
}

/// O laço de reconexão do agente, já dentro do runtime do `tokio`.
///
/// Separado da `main` porque a `main` agora pertence à interface: a biblioteca
/// de janelas exige a thread principal, e o `tokio` não exige nada. Ver o
/// cabeçalho de `gui.rs`.
async fn laco_de_conexao(
    url: String,
    identity: AgentIdentity,
    stream: StreamConfig,
    keep_awake: bool,
    auto_apresentacao: bool,
    estado: deskside_agent::gui::Compartilhado,
) {
    // A agenda nasce aqui, e não dentro de `client::run`: ela precisa
    // sobreviver às reconexões. Um Wi-Fi que troca de rede às 17:59 não pode
    // levar junto as dezoito horas.
    let agenda = deskside_agent::agenda::Compartilhada::default();
    tokio::spawn(client::vigiar_agenda(agenda.clone(), estado.clone()));

    // O modo apresentação também vive fora da conexão: uma apresentação não
    // pode parar de ser detectada porque o Wi-Fi trocou de rede.
    let apresentacao = deskside_agent::apresentacao::Compartilhado::new(
        std::sync::Mutex::new(deskside_agent::apresentacao::Modo::novo(auto_apresentacao)),
    );
    tokio::spawn(client::vigiar_apresentacao(apresentacao.clone()));

    let compartilhados = client::Compartilhados {
        estado: estado.clone(),
        agenda,
        apresentacao,
    };

    let mut espera = client::RECONEXAO_MINIMA;

    loop {
        // `stream` é clonado a cada tentativa: a config carrega a lista de
        // servidores STUN, então não é mais `Copy`.
        let erro = client::run(
            &url,
            &identity,
            Duration::from_secs(HEARTBEAT_SECS),
            stream.clone(),
            keep_awake,
            &compartilhados,
        )
        .await
        .err();

        // Lido **antes** de marcar como desconectado: é a única forma de saber
        // se esta volta chegou a conectar. `run` devolve `Err` nos dois casos —
        // "não consegui conectar" e "conectei e caiu depois" —, e tratar os dois
        // igual faria a espera crescer numa conexão que estava funcionando.
        let conectou = estado.lock().map(|s| s.conectado).unwrap_or(false);

        if let Some(e) = erro {
            eprintln!("Conexão perdida: {e}");
            // A janela mostra o motivo. "Sem conexão" sozinho manda a pessoa
            // reiniciar o computador à toa.
            if let Ok(mut s) = estado.lock() {
                s.conectado = false;
                s.ultimo_erro = Some(e.to_string());
            }
        }

        espera = client::proxima_espera(espera, conectou);
        // No diário e não em `println!`: com o agente oculto, é esta linha que
        // conta quantas tentativas houve antes de a conexão pegar.
        deskside_agent::diario(&format!(
            "reconectando em {}s",
            espera.as_secs()
        ));
        tokio::time::sleep(espera).await;
    }
}

/// Pergunta se é para instalar, e instala. `true` = instalou e pode sair.
///
/// O `install` já sobe a cópia instalada no fim, então este processo não tem
/// mais o que fazer.
fn oferecer_instalacao() -> bool {
    use std::io::Write;

    println!();
    println!("Deskside {AGENT_VERSION}");
    println!();
    println!("Instalar neste computador? Ele passa a subir junto com o Windows,");
    println!("oculto, e aparece em \"Aplicativos instalados\".");
    print!("[S/n] ");
    let _ = std::io::stdout().flush();

    let mut resposta = String::new();
    // **`Ok(0)` é o caso que importa.** Significa fim de entrada: ninguém para
    // responder. Acontece quando o agente sobe pela tarefa agendada, sem
    // console. Tratar isso como "Enter vazio" instalaria sozinho, em silêncio,
    // toda vez que a máquina liga - o oposto do que a pergunta existe para
    // garantir.
    let quer = match std::io::stdin().read_line(&mut resposta) {
        Ok(0) | Err(_) => false,
        Ok(_) => setup::quer_instalar(&resposta),
    };
    if !quer {
        println!();
        println!("Sem instalar. O agente vai rodar agora, e para até esta janela fechar.");
        println!("Para instalar depois: deskside-agent.exe install");
        return false;
    }

    match setup::install(None) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("Não consegui instalar: {e}");
            println!("O agente vai rodar assim mesmo, sem instalar.");
            false
        }
    }
}

fn main() {
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

    // A **primeira** linha do diário, antes de qualquer outra coisa. Ela é a
    // metade que faltava para responder "por que o agente demora a ficar
    // disponível depois de ligar o computador?": comparada com a linha de
    // "conectado", separa as duas causas possíveis.
    //
    // Se esta linha sai em `boot+40s`, o tempo foi gasto **antes** de o agente
    // existir — é o mecanismo que o inicia no logon, e nada de rede ajuda. Se
    // sai cedo e a de "conectado" sai tarde, é rede ou servidor. Sem esta
    // medida, escolher entre as duas seria adivinhação.
    deskside_agent::diario(&format!("agente {AGENT_VERSION} iniciando"));

    // Dois cliques no arquivo baixado: oferece instalar antes de sair rodando.
    //
    // `args.is_empty()` é o que separa "cliquei no ícone" de "chamei pelo
    // terminal": quem digita `deskside-agent run` pediu para rodar, não para
    // instalar, e perguntar ali seria atrapalhar quem sabe o que está fazendo.
    if args.is_empty() && setup::deve_oferecer_instalacao() && oferecer_instalacao() {
        return;
    }

    // Uma instância só por usuário. Sem isto, clicar no atalho do Menu
    // Iniciar com o agente já rodando subiria um segundo agente com o mesmo
    // `device_id`: os dois conectam, e o backend entrega os comandos a um
    // deles por sorteio. O sintoma seria controle remoto pela metade, sem
    // erro nenhum explicando.
    //
    // `_guarda` e não `_`: o sublinhado sozinho descartaria o guarda na hora,
    // liberando o nome de volta - o oposto do que se quer.
    let _guarda = match deskside_agent::instance::reivindicar() {
        deskside_agent::instance::Start::JaRodando => {
            println!("O Deskside já está rodando neste computador.");
            return;
        }
        deskside_agent::instance::Start::Primeira(g) => g,
    };

    // Antes de ler qualquer configuração: quem vem da versão RemoteOne tem
    // tudo na pasta antiga, incluindo o `device_id`. Sem isto o computador
    // apareceria no aplicativo como uma máquina nova, pedindo pareamento, e a
    // antiga ficaria na lista como um fantasma que nunca mais fica online.
    deskside_agent::migrar_configuracao_antiga();

    let plat = platform::current();
    let cfg = load_config();
    let url = resolve(&cfg, "DESKSIDE_BACKEND_URL")
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
        secret_path: Some(deskside_agent::agent_secret_path()),
    };

    // Parâmetros de transmissão (ajustáveis sem recompilar).
    let default = StreamConfig::default();
    let stream = StreamConfig {
        fps: cfg_u32(&cfg, "DESKSIDE_STREAM_FPS", default.fps),
        max_width: cfg_u32(&cfg, "DESKSIDE_STREAM_MAX_WIDTH", default.max_width),
        quality: cfg_u32(&cfg, "DESKSIDE_STREAM_QUALITY", default.quality as u32) as u8,
        video_bitrate: cfg_u32(&cfg, "DESKSIDE_VIDEO_BITRATE", default.video_bitrate),
        video_fps: cfg_u32(&cfg, "DESKSIDE_VIDEO_FPS", default.video_fps),
        video_max_width: cfg_u32(&cfg, "DESKSIDE_VIDEO_MAX_WIDTH", default.video_max_width),
        // Lista separada por vírgulas; vazio desliga o STUN (só rede local).
        ice_servers: match resolve(&cfg, "DESKSIDE_ICE_SERVERS") {
            None => default.ice_servers.clone(),
            Some(list) => list
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
        },
    };

    // Ligado por padrão, e é uma decisão de produto: o motivo de existir é
    // funcionar em qualquer máquina sem ninguém configurar nada. Desligado por
    // padrão, o recurso só serviria a quem já sabia que ele existe.
    let keep_awake = cfg_bool(&cfg, "DESKSIDE_KEEP_AWAKE", true);

    // Ao contrário do "manter pronto", **desligado** por padrão. Silenciar
    // notificações sozinho, sem ninguém ter pedido, faria a pessoa perder uma
    // mensagem sem entender por quê - e um recurso que some com avisos precisa
    // ter sido escolhido.
    let auto_apresentacao = cfg_bool(&cfg, "DESKSIDE_PRESENTATION_AUTO", false);

    println!(
        "Deskside Agent {AGENT_VERSION} — sistema: {}",
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
    println!(
        "Manter o computador pronto: {}",
        if keep_awake {
            "sim (solta sozinho ao cair para a bateria)"
        } else {
            "não"
        }
    );
    deskside_agent::diario(&format!("agente de pé; conectando a {url}"));

    let estado = deskside_agent::gui::compartilhar(deskside_agent::gui::Estado {
        hostname: identity.hostname.clone(),
        device_id: device_id.clone(),
        versao: AGENT_VERSION.to_string(),
        backend: url.clone(),
        conectado: false,
        ultimo_erro: None,
        keep_awake,
        segurando: false,
        aviso: None,
        cancelar: None,
        desinstalar: false,
        desparear_ok: false,
    });

    // O agente sobe **antes** da interface e independe dela. Se a janela não
    // abrir - sessão sem desktop, driver gráfico recusando -, o computador
    // continua alcançável. O contrário seria uma troca péssima: perder o
    // produto inteiro por causa da tela que mostra o produto.
    let do_agente = estado.clone();
    std::thread::Builder::new()
        .name("deskside-agente".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("Não consegui criar o runtime do agente: {e}");
                    return;
                }
            };
            rt.block_on(laco_de_conexao(
                url,
                identity,
                stream,
                keep_awake,
                auto_apresentacao,
                do_agente,
            ));
        })
        .expect("não consegui criar a thread do agente");

    // Daqui não se volta: a interface fica com a thread principal até alguém
    // escolher Sair no ícone ao lado do relógio.
    deskside_agent::gui::rodar(estado);
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
        let cfg = Config::parse("DESKSIDE_VIDEO_FPS=24\n");
        assert_eq!(cfg_u32(&cfg, "DESKSIDE_VIDEO_FPS", 30), 24);
        // Chave ausente ou ilegível cai no padrão em vez de zerar o valor.
        assert_eq!(cfg_u32(&cfg, "NAO_EXISTE", 30), 30);
        let ruim = Config::parse("DESKSIDE_VIDEO_FPS=trinta\n");
        assert_eq!(cfg_u32(&ruim, "DESKSIDE_VIDEO_FPS", 30), 30);
    }
}
