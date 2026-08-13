//! Cliente WebSocket que conecta o agente ao backend.
//!
//! Fluxo: conecta, envia `hello`, aguarda `welcome` e então entra em um laço
//! que envia `heartbeat` periodicamente enquanto trata as respostas do
//! servidor. A construção das mensagens (parte pura) é testável; o laço de
//! conexão em si é exercitado manualmente e pela validação ponta a ponta.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::time::{interval, MissedTickBehavior};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::protocol::{ClientMessage, ServerMessage};

/// Parâmetros da transmissão de tela (ajustáveis por variável de ambiente).
#[derive(Debug, Clone)]
pub struct StreamConfig {
    pub fps: u32,
    pub max_width: u32,
    pub quality: u8,
    /// Taxa alvo do H.264, em bits por segundo. O spike S2 mediu conteúdo de
    /// desktop entre 0,08 e 0,22 Mbps; 1,5 Mbps deixa folga larga para
    /// movimento e o controle de congestionamento reduz sozinho se precisar.
    pub video_bitrate: u32,
    /// Servidores STUN para descobrir o endereço externo (P2P). Vazio = só LAN.
    pub ice_servers: Vec<String>,
    /// Largura máxima **do vídeo**, independente da do JPEG.
    ///
    /// O custo de codificar é praticamente linear no número de pixels: medido,
    /// 1280x720 custa 37 ms por quadro e 1600x1066 custa 68 ms. Os presets do
    /// app (960, 1280, 1600) foram dimensionados pela banda do JPEG, mas no
    /// vídeo a banda sobra (0,2–0,5 Mbps medidos) e o gargalo é a CPU. Então o
    /// vídeo tem o seu próprio teto, e usa o menor entre este e o do preset.
    pub video_max_width: u32,
    /// Taxa de quadros alvo **do vídeo**, independente da do JPEG.
    ///
    /// Os presets do app (5, 10, 15 fps) foram escolhidos para caber na banda do
    /// JPEG, que gasta ~67 KB por quadro. O H.264 gasta 0,3–0,9 KB, então 30 fps
    /// por vídeo custa menos rede que 5 fps por JPEG. E taxa baixa é justamente
    /// o que faz vídeo parecer travado: sem quadros intermediários, o
    /// movimento vira uma sequência de saltos.
    pub video_fps: u32,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            fps: 60,
            max_width: 1280,
            quality: 50,
            video_bitrate: 1_500_000,
            ice_servers: vec!["stun:stun.l.google.com:19302".to_string()],
            video_max_width: 1280,
            video_fps: 30,
        }
    }
}

impl StreamConfig {
    /// Largura efetiva do vídeo: o menor entre o pedido do app e o teto próprio.
    fn video_width(&self) -> u32 {
        self.max_width.min(self.video_max_width)
    }

    /// Intervalo do caminho de vídeo, que roda mais rápido que o do JPEG.
    fn video_interval(&self) -> Duration {
        Self::interval_for(self.video_fps)
    }

    /// Os parâmetros de vídeo em vigor: o degrau da qualidade adaptativa,
    /// limitado pelos tetos configurados.
    ///
    /// A ordem importa e é sempre esta: o ajuste automático **só abaixa**. Quem
    /// pôs `DESKSIDE_VIDEO_MAX_WIDTH=800` porque a máquina é fraca não quer
    /// que uma rede boa devolva 1280 — o teto é do dono da máquina, o degrau é
    /// da rede, e a rede não manda no dono da máquina.
    fn video_params(&self, nivel: crate::adaptive::Level) -> crate::adaptive::Level {
        crate::adaptive::Level {
            width: self.video_width().min(nivel.width),
            fps: self.video_fps.clamp(1, 60).min(nivel.fps),
            bitrate: self.video_bitrate.min(nivel.bitrate),
        }
    }

    fn interval_for(fps: u32) -> Duration {
        Duration::from_millis(1000 / fps.clamp(1, 60) as u64)
    }
}

/// Ritmo do ticker quando ninguém está olhando a tela.
///
/// Lento de propósito: só serve para perceber que alguém voltou a pedir. Sem
/// isto o laço acordaria 60 vezes por segundo com o computador ocioso.
const IDLE_INTERVAL: Duration = Duration::from_millis(500);

/// Quanto tempo sem **nenhuma** resposta do servidor antes de desistir da
/// conexão e reconectar.
///
/// Existe porque um socket TCP pode morrer sem que nenhum dos lados saiba. Numa
/// máquina virtual que suspende (fechar a tampa), num Wi-Fi que troca de rede,
/// num notebook que dorme, a conexão fica meio-aberta: o agente continua
/// escrevendo `heartbeat` num socket morto, o Windows guarda em buffer e fica
/// retransmitindo, e o erro só aparece quando a retransmissão esgota - minutos
/// depois. Nesse intervalo o agente se diz conectado, o app mostra o computador
/// online, e nada funciona. Era o "cai muito ao religar o computador".
///
/// O servidor responde `Ack` a cada `heartbeat`, então três batidas sem
/// resposta nenhuma significam que o caminho de volta acabou. Três, e não uma:
/// uma batida perdida é rede ruim, e derrubar a conexão por causa dela trocaria
/// um problema por outro.
const SEM_RESPOSTA: Duration = Duration::from_secs(35);

/// De quanto em quanto tempo a qualidade adaptativa reavalia.
///
/// Dois segundos porque os relatórios de recepção chegam a cada ~1s: menos que
/// isso decidiria com uma amostra só, e uma amostra só é ruído.
const ADAPT_INTERVAL: Duration = Duration::from_secs(2);

/// O que a captura precisa entregar agora — `(largura, fps)` — ou `None` se
/// ninguém está pedindo a tela.
///
/// Existe para que a thread de captura seja função do estado, e não de eventos:
/// ela nasce, troca de tamanho e morre porque esta função mudou de resposta. Era
/// por depender de eventos que a captura vazava quando o vídeo e o JPEG paravam
/// juntos — não havia transição para observar.
fn desired_capture(
    streaming: bool,
    video: bool,
    cfg: &StreamConfig,
    nivel: crate::adaptive::Level,
    monitor: Option<u32>,
) -> Option<CaptureWanted> {
    let (width, fps) = if video {
        let p = cfg.video_params(nivel);
        (p.width, p.fps)
    } else if streaming {
        (cfg.max_width, cfg.fps.clamp(1, 60))
    } else {
        return None;
    };
    Some(CaptureWanted {
        monitor,
        width,
        fps,
    })
}

/// A captura que o estado atual pede. Trocar qualquer campo reabre a thread —
/// inclusive o monitor, que é o ponto de trocar de tela sem reconectar nada.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CaptureWanted {
    monitor: Option<u32>,
    width: u32,
    fps: u32,
}

/// Intervalo do ticker de quadros para uma captura desejada.
fn rhythm(capture: Option<CaptureWanted>) -> Duration {
    match capture {
        Some(c) => StreamConfig::interval_for(c.fps),
        None => IDLE_INTERVAL,
    }
}

/// Dados de identificação do agente, resolvidos uma vez na inicialização.
#[derive(Debug, Clone)]
pub struct AgentIdentity {
    pub device_id: String,
    pub hostname: String,
    pub os: String,
    pub agent_version: String,
    pub mac: Option<String>,
}

impl AgentIdentity {
    /// Constrói a mensagem `hello` a partir da identidade.
    pub fn hello(&self) -> ClientMessage {
        ClientMessage::Hello {
            device_id: self.device_id.clone(),
            hostname: self.hostname.clone(),
            os: self.os.clone(),
            agent_version: self.agent_version.clone(),
            mac: self.mac.clone(),
        }
    }
}

/// Conecta ao backend e mantém a sessão viva com heartbeats.
///
/// Retorna `Err` se a conexão cair; o chamador decide se tenta reconectar.
pub async fn run(
    url: &str,
    identity: &AgentIdentity,
    heartbeat: Duration,
    stream: StreamConfig,
    keep_awake: bool,
    estado: crate::gui::Compartilhado,
    agenda: crate::agenda::Compartilhada,
) -> Result<(), Box<dyn std::error::Error>> {
    let (mut ws, _response) = connect_async(url).await?;
    println!("Conectado ao backend em {url}");
    // A janela precisa saber daqui: é este o instante em que a conexão existe,
    // e nenhum outro lugar tem essa informação sem adivinhar.
    if let Ok(mut e) = estado.lock() {
        e.conectado = true;
        e.ultimo_erro = None;
    }

    // Envia o hello e aguarda o welcome.
    let hello = serde_json::to_string(&identity.hello())?;
    ws.send(Message::Text(hello)).await?;

    let mut ticker = interval(heartbeat);
    ticker.tick().await; // consome o primeiro tick imediato

    // Quando chegou a última notícia do servidor. **Qualquer** mensagem serve,
    // e não só o `Ack`: se o backend falou, o caminho de volta está de pé.
    let mut ultimo_sinal = tokio::time::Instant::now();

    // Injetor de entrada da plataforma (real no Windows, stub no restante).
    let mut injector = crate::injector::controller();

    // Manter o computador pronto para ser alcançado. Reavaliado a cada batida
    // do relógio porque a fonte de energia muda no meio da vida do agente -
    // tirar o notebook da tomada precisa soltar o pedido sem reiniciar nada.
    let mut keep_awake = keep_awake;
    let mut awake = crate::awake::Keeper::new();
    awake.set(crate::awake::should_hold(
        keep_awake,
        crate::awake::power_source(),
    ));

    // Métricas do computador. Criado agora, e não no primeiro pedido, porque a
    // leitura de referência da CPU precisa acontecer 200 ms antes da primeira
    // medida de verdade — e aqui isso não custa nada a ninguém.
    let mut monitor = crate::system_info::Monitor::new();

    // Quem está em primeiro plano, para a barra de perfis do app mostrar o
    // ícone do programa de verdade. Vive num `Arc<Mutex>` porque descobrir isso
    // pode custar um PowerShell (extração de ícone), e isso sai do laço para
    // uma thread - o laço não pode parar por 200 ms enquanto alguém digita.
    let foreground = Arc::new(std::sync::Mutex::new(crate::foreground::Watcher::new()));

    // Som do computador. O canal existe sempre (facilita o `select!`), mas só
    // recebe alguma coisa enquanto a captura estiver ligada. Limitado de
    // propósito: se a rede não acompanha, o certo é perder o quadro de som mais
    // novo, não acumular meio minuto de atraso.
    let (audio_tx, mut audio_rx) = tokio::sync::mpsc::channel::<crate::audio::Packet>(32);
    let mut audio: Option<crate::audio::Capture> = None;
    let mut audio_stats = AudioStats::default();
    // Ganho do som, compartilhado com a thread da placa. Fica fora da captura
    // de propósito: mexer no controle do telefone tem efeito na hora, sem
    // reabrir a placa de som.
    let audio_gain = Arc::new(crate::audio::Gain::new(1.0));

    // Área de transferência. O acompanhante guarda o que já foi visto; o
    // relógio só corre enquanto a sincronia automática estiver ligada - sem
    // ninguém pedindo, o agente não tem por que olhar o que se copia no
    // computador.
    let mut clipboard = crate::clipboard::Clipboard::new();
    let mut clipboard_sync = false;
    let mut clipboard_ticker = interval(Duration::from_secs(1));
    clipboard_ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

    // Transferência de arquivos. Os pedaços que saem daqui passam por um canal
    // **limitado**: é ele que segura o leitor quando a rede não acompanha. Sem
    // limite, ler um arquivo de 100 MB o carregaria inteiro na memória.
    let (file_tx, mut file_rx) = tokio::sync::mpsc::channel::<ClientMessage>(4);
    // Arquivos sendo recebidos do celular, e a próxima sequência esperada de
    // cada um. Um pedaço fora de ordem vira erro, não arquivo corrompido.
    let mut uploads: std::collections::HashMap<String, (crate::files::Incoming, u64)> =
        std::collections::HashMap::new();
    // Leituras em curso: a bandeira é como o `cancel_transfer` alcança a thread
    // que está lendo o arquivo.
    let mut reads: std::collections::HashMap<String, Arc<std::sync::atomic::AtomicBool>> =
        std::collections::HashMap::new();

    // Transmissão de tela: enquanto ativa, captura e envia frames JPEG. A
    // config é mutável porque o app pode ajustar fps/qualidade por sessão.
    let mut streaming = false;
    let mut active = stream.clone();
    let mut ticker_interval = IDLE_INTERVAL;
    let mut frame_ticker = interval(ticker_interval);
    frame_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    // Hash do último frame enviado: se a tela não mudou, não vale codificar
    // nem transmitir de novo (o app já mostra a mesma imagem).
    let mut last_frame = crate::capture::NO_FRAME;

    // Vídeo por WebRTC. O que precisa voltar ao backend (resposta SDP,
    // candidatos ICE) sai por este canal, porque o webrtc-rs chama de volta de
    // dentro das tarefas dele e quem tem o WebSocket é este laço.
    let (signal_tx, mut signal_rx) = tokio::sync::mpsc::unbounded_channel();
    // Entrada pelo canal de dados (Fase 6): chega P2P, sem passar pelo servidor.
    let (input_tx, mut input_rx) = tokio::sync::mpsc::unbounded_channel();
    // Pedidos de quadro-chave do app (RTCP). Chegam de dentro das tarefas do
    // webrtc-rs e quem tem o codificador é este laço, então passam por canal.
    let (keyframe_tx, mut keyframe_rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    // Perda de pacotes relatada pelo telefone (RTCP RR), pelo mesmo motivo.
    let (loss_tx, mut loss_rx) = tokio::sync::mpsc::unbounded_channel::<f32>();
    let mut video = crate::webrtc::Video::new(
        signal_tx,
        input_tx,
        keyframe_tx,
        loss_tx,
        stream.ice_servers.clone(),
    )
    .map_err(|e| format!("não consegui iniciar o vídeo por WebRTC: {e}"))?;
    // Descarta comandos de movimento que chegaram fora de ordem (o canal é
    // deliberadamente não ordenado; ver `datachannel.rs`).
    let mut input_order = crate::datachannel::InputOrder::new();

    // Codificador H.264, compartilhado com a thread de codificação. Precisa
    // viver entre quadros: é guardar o anterior que permite mandar só a
    // diferença. `None` até o primeiro quadro definir a resolução.
    let encoder: Arc<Mutex<Option<crate::h264::Encoder>>> = Arc::new(Mutex::new(None));

    // Relógio da transmissão de vídeo. Os timestamps do codificador e a duração
    // das amostras RTP saem daqui, medidos — não calculados a partir do fps
    // pretendido, que capturar e codificar nunca alcançam de verdade.
    let mut video_clock: Option<std::time::Instant> = None;
    let mut last_video_frame: Option<std::time::Instant> = None;
    // Se o quadro anterior foi de vídeo, para saber quando a sessão troca.
    let mut was_video = false;
    // Captura correndo à parte, para o laço só pagar a codificação. `pump_config`
    // é a largura e a taxa com que ela foi aberta: quando o desejado difere, a
    // thread é recriada.
    let mut pump: Option<crate::capture::FramePump> = None;
    let mut pump_config: Option<CaptureWanted> = None;
    // Monitor escolhido pelo app. `None` = o principal, e é onde toda sessão
    // começa; a escolha vale enquanto o agente estiver de pé.
    let mut tela: Option<u32> = None;
    // Contadores do resumo periódico: sem número, "está travado" não tem
    // como virar diagnóstico.
    let mut stats = VideoStats::default();

    // Qualidade adaptativa (Fase 4b). A escada decide o degrau; este laço só
    // lhe conta o que a rede andou fazendo e obedece ao que ela responder.
    let mut ladder = crate::adaptive::Ladder::new();
    // Pior perda vista desde a última avaliação, e quantos relatórios a
    // sustentam. A contagem importa: sem relatório nenhum, "zero perdido" não
    // é notícia boa, é ausência de notícia - e tratar as duas coisas como
    // iguais faria a qualidade subir justamente quando o caminho sumiu.
    let mut worst_loss = 0f32;
    let mut loss_reports = 0u32;
    let mut adapt_ticker = interval(ADAPT_INTERVAL);
    adapt_ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    // Parâmetros com que o codificador em uso foi criado. Mudar de degrau muda
    // fps e taxa, e nenhum dos dois se ajusta num codificador já em pé.
    let mut encoder_level: Option<crate::adaptive::Level> = None;

    loop {
        tokio::select! {
            // `biased`: as ramificações são tentadas nesta ordem, e não em
            // ordem aleatória. O som vem primeiro porque é o único trabalho
            // aqui com prazo humano - 20 ms por quadro, sem margem. Sorteando,
            // ele dividia as iterações com a codificação do vídeo (dezenas de
            // ms por quadro nesta máquina), perdia a corrida e o canal enchia:
            // era o som picotado.
            biased;

            // Quadros de som prontos, vindos da thread da placa.
            Some(pacote) = audio_rx.recv() => {
                // Esvazia tudo o que estiver esperando, não só um. Uma volta
                // do laço por quadro de 20 ms seria lenta demais quando o
                // vídeo está codificando; em lote, um despertar dá conta do
                // que se acumulou.
                let mut pacote = Some(pacote);
                while let Some(p) = pacote {
                    audio_stats.count(p.data.len());
                    video.write_audio(&p.data, p.duration).await;
                    pacote = audio_rx.try_recv().ok();
                }
                // Um número no console é a diferença entre "não ouvi nada" e
                // saber de qual lado o som parou.
                if let Some(linha) = audio_stats.report_if_due(video.wants_audio()) {
                    println!("{linha}");
                }
            }
            // O app não consegue decodificar e está pedindo um quadro-chave.
            // Vem logo depois do som porque é curto e urgente: cada volta de
            // atraso aqui é mais um pedaço de tela preta no telefone.
            Some(()) = keyframe_rx.recv() => {
                if let Some(enc) = encoder
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .as_mut()
                {
                    enc.request_keyframe();
                }
            }
            // Cópia nova no computador, quando a sincronia está ligada. A
            // verificação é barata: só lê o conteúdo se o contador do Windows
            // mudou.
            _ = clipboard_ticker.tick(), if clipboard_sync => {
                if let Some(texto) = clipboard.changed() {
                    let aviso = serde_json::to_string(
                        &ClientMessage::ClipboardChanged { text: texto },
                    )?;
                    ws.send(Message::Text(aviso)).await?;
                }
            }
            _ = ticker.tick() => {
                // A cobrança vem **antes** de mandar a próxima batida: mandar
                // primeiro adiaria a decisão em mais um ciclo, e o socket morto
                // aceita a escrita sem reclamar - é justamente por isso que ele
                // engana.
                if ultimo_sinal.elapsed() > SEM_RESPOSTA {
                    video.close_all().await;
                    let _ = audio.take();
                    return Err("servidor parou de responder".into());
                }
                let hb = serde_json::to_string(&ClientMessage::Heartbeat)?;
                ws.send(Message::Text(hb)).await?;
                // De carona no relógio que já existe: não vale um temporizador
                // próprio para ler um byte do sistema.
                awake.set(crate::awake::should_hold(
                    keep_awake,
                    crate::awake::power_source(),
                ));
                if let Ok(mut e) = estado.lock() {
                    e.keep_awake = keep_awake;
                    e.segurando = awake.holding();
                }
            }
            // Sinalização vinda do webrtc-rs (resposta SDP, candidatos locais):
            // este laço é quem tem o WebSocket, então é quem despacha.
            Some(signal) = signal_rx.recv() => {
                let message = match signal {
                    crate::webrtc::Signal::Answer { session_id, sdp } => {
                        ClientMessage::WebrtcAnswer { session_id, sdp }
                    }
                    crate::webrtc::Signal::Ice {
                        session_id, candidate, sdp_mid, sdp_mline_index,
                    } => ClientMessage::WebrtcIce {
                        session_id, candidate, sdp_mid, sdp_mline_index,
                    },
                };
                ws.send(Message::Text(serde_json::to_string(&message)?)).await?;
            }
            // Pedaços de arquivo saindo (leitura em curso numa thread própria).
            Some(message) = file_rx.recv() => {
                // O fim da leitura é o momento de esquecer a bandeira de
                // cancelamento: ela já não alcança ninguém.
                if let ClientMessage::FileDone { transfer_id, .. } = &message {
                    reads.remove(transfer_id);
                }
                ws.send(Message::Text(serde_json::to_string(&message)?)).await?;
            }
            // Entrada vinda do canal de dados: um salto direto do celular até
            // aqui, sem HTTP e sem passar pelo servidor.
            Some(envelope) = input_rx.recv() => {
                if input_order.accept(&envelope) {
                    if let Err(e) = injector.apply(&envelope.action) {
                        eprintln!("Falha ao aplicar entrada: {e}");
                    }
                }
            }
            // Um tique de quadro serve os dois caminhos. Quando há sessão de
            // WebRTC conectada, o vídeo vai por lá (banda ~100x menor, medida
            // no S2); senão, segue o JPEG, que continua sendo o fallback. Os dois
            // consomem a **mesma** captura contínua.
            // Perda relatada pelo telefone. Só se acumula aqui; quem decide é
            // o tique de reavaliação, com a janela inteira em mãos.
            Some(perda) = loss_rx.recv() => {
                if perda.is_finite() {
                    worst_loss = worst_loss.max(perda);
                    loss_reports += 1;
                }
            }
            // Reavaliação da qualidade.
            _ = adapt_ticker.tick() => {
                if video.wants_video() && loss_reports > 0 {
                    let antes = ladder.step();
                    if let Some(nivel) = ladder.observe(worst_loss, ADAPT_INTERVAL) {
                        let p = active.video_params(nivel);
                        println!(
                            "Qualidade: degrau {antes} → {} ({}px, {} fps, {:.1} Mbps \
                             alvo) — perda relatada {:.1}%",
                            ladder.step(),
                            p.width,
                            p.fps,
                            p.bitrate as f64 / 1_000_000.0,
                            worst_loss * 100.0,
                        );
                    }
                }
                worst_loss = 0.0;
                loss_reports = 0;
            }
            _ = frame_ticker.tick() => {
                let quer_video = video.wants_video();
                let desejada =
                    desired_capture(streaming, quer_video, &active, ladder.current(), tela);

                // O vídeo roda mais rápido que o JPEG e a ociosidade mais lenta
                // que os dois. Sem acertar o ritmo, o vídeo herdaria os 10 fps
                // do preset e pareceria travado por falta de quadros.
                let ritmo = rhythm(desejada);
                if ritmo != ticker_interval {
                    ticker_interval = ritmo;
                    frame_ticker = interval(ritmo);
                    frame_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
                    match desejada {
                        Some(c) => println!(
                            "Ritmo da tela: {} fps ({})",
                            c.fps,
                            if quer_video { "vídeo" } else { "JPEG" },
                        ),
                        None => println!("Ritmo da tela: ocioso"),
                    }
                }

                // Sessão de vídeo entrando ou saindo: o relógio e os contadores
                // valem por sessão, e misturar os números dos dois caminhos no
                // mesmo resumo tornaria o resumo inútil.
                if quer_video != was_video {
                    was_video = quer_video;
                    stats = VideoStats::default();
                    if quer_video {
                        video_clock = None;
                        last_video_frame = None;
                        // Sessão nova começa no topo: a rede de ontem não diz
                        // nada sobre a de agora, e começar punido entregaria
                        // menos do que esta rede aguenta.
                        ladder.reset();
                        worst_loss = 0.0;
                        loss_reports = 0;
                        let largura = active.video_width();
                        if largura < active.max_width {
                            println!(
                                "Vídeo limitado a {largura}px de largura (o preset pede \
                                 {}px). Codificar custa por pixel; ajuste com \
                                 DESKSIDE_VIDEO_MAX_WIDTH.",
                                active.max_width,
                            );
                        }
                    }
                }

                // A captura é função do estado: abre quando alguém quer a tela,
                // reabre quando a largura ou a taxa mudam, encerra quando ninguém
                // quer mais.
                if desejada != pump_config {
                    pump = None; // Drop encerra a thread antiga antes de abrir outra
                    pump_config = desejada;
                    if let Some(c) = desejada {
                        match crate::capture::FramePump::start(c.monitor, c.width, c.fps) {
                            Ok(started) => pump = Some(started),
                            Err(e) => {
                                eprintln!("Não consegui iniciar a captura: {e}");
                                pump_config = None;
                            }
                        }
                    }
                }

                // Pega o quadro mais recente já capturado. Se ainda não há nenhum
                // novo, a tela não mudou: não vale recodificar o mesmo.
                let Some(captured) = pump.as_ref().and_then(|p| p.take()) else {
                    if pump.is_some() {
                        stats.starved += 1;
                    }
                    continue;
                };
                let size = (captured.width, captured.height);
                if quer_video {
                    let started = video_clock.get_or_insert_with(std::time::Instant::now);
                    let elapsed = started.elapsed();
                    let params = active.video_params(ladder.current());
                    // Nem fps nem taxa se ajustam num codificador já em pé, e
                    // o `fits` só olha a resolução: descer de 30 para 20 fps
                    // sem mudar a largura passaria despercebido e o degrau não
                    // teria efeito algum.
                    let recriar = encoder_level != Some(params);
                    let shared = Arc::clone(&encoder);
                    let encode_started = std::time::Instant::now();
                    let encoded = tokio::task::spawn_blocking(move || {
                        let (w, h) = (captured.width, captured.height);
                        let mut slot = shared.lock().unwrap_or_else(|e| e.into_inner());
                        // Resolução nova (trocou de monitor, mudou a tela) ou
                        // degrau novo: recria em vez de remendar o atual.
                        if recriar || !slot.as_ref().is_some_and(|enc| enc.fits(w, h)) {
                            *slot = Some(crate::h264::Encoder::new(
                                w, h, params.fps, params.bitrate,
                            )?);
                        }
                        slot.as_mut()
                            .expect("acabou de ser criado")
                            .encode(&captured.rgb, w, h, elapsed)
                    })
                    .await;
                    match encoded {
                        Ok(Ok(frame)) => {
                            // Só depois de codificar de verdade: se a criação
                            // falhou, o degrau anotado tem de continuar sendo
                            // o antigo, para a próxima volta tentar de novo.
                            encoder_level = Some(params);
                            // Duração real do quadro anterior, não a pretendida:
                            // é dela que saem os timestamps RTP, e um relógio
                            // que não corresponde à realidade faz o buffer de
                            // jitter do app corrigir o tempo todo — que é
                            // exatamente a sensação de travado.
                            let now = std::time::Instant::now();
                            let duration = last_video_frame
                                .map(|previous| now.duration_since(previous))
                                .unwrap_or_else(|| active.video_interval());
                            last_video_frame = Some(now);
                            stats.record(encode_started.elapsed(), frame.data.len(), size);
                            video.write(&frame, duration).await;
                            let capture_ms =
                                pump.as_ref().and_then(|p| p.cost().take_average_ms());
                            stats.report_if_due("Vídeo", capture_ms);
                        }
                        Ok(Err(e)) => eprintln!("Falha ao codificar a tela: {e}"),
                        Err(e) => eprintln!("Falha na tarefa de vídeo: {e}"),
                    }
                } else {
                    // Codificação fora do event loop (spawn_blocking) para não
                    // travar o tratamento de comandos enquanto o JPEG é feito.
                    let quality = active.quality;
                    let previous = last_frame;
                    let encode_started = std::time::Instant::now();
                    let encoded = tokio::task::spawn_blocking(move || {
                        crate::capture::jpeg_if_changed(&captured, quality, previous)
                    })
                    .await;
                    match encoded {
                        Ok(Ok(frame)) => {
                            last_frame = frame.hash;
                            let bytes = frame.jpeg.as_ref().map_or(0, |jpeg| jpeg.len());
                            // `jpeg` vazio = tela idêntica à anterior: nada a enviar.
                            if let Some(jpeg) = frame.jpeg {
                                ws.send(Message::Binary(jpeg)).await?;
                            }
                            stats.record(encode_started.elapsed(), bytes, size);
                            let capture_ms =
                                pump.as_ref().and_then(|p| p.cost().take_average_ms());
                            stats.report_if_due("Tela", capture_ms);
                        }
                        Ok(Err(e)) => eprintln!("Falha ao codificar a tela: {e}"),
                        Err(e) => eprintln!("Falha na tarefa de captura: {e}"),
                    }
                }
            }
            incoming = ws.next() => {
                // Antes do `match`, de propósito: mensagem que este laço ignora
                // (um pong, um binário) prova a mesma coisa que uma tratada -
                // que o servidor ainda está do outro lado.
                if matches!(incoming, Some(Ok(_))) {
                    ultimo_sinal = tokio::time::Instant::now();
                }
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        match handle_server_text(
                            &text, injector.as_mut(), &mut streaming, &mut active,
                            &mut last_frame,
                        ) {
                            // A lista inteira, sempre. Quem avalia é a tarefa da
                            // agenda, que vive fora desta conexão: ela precisa
                            // sobreviver ao socket que cai.
                            Some(Action::SetSchedule { items }) => {
                                let convertidos = items
                                    .iter()
                                    .filter_map(crate::agenda::Item::do_protocolo)
                                    .collect::<Vec<_>>();
                                println!(
                                    "Agenda: {} automação(ões) agendada(s)",
                                    convertidos.len()
                                );
                                if let Ok(mut a) = agenda.lock() {
                                    a.substituir(convertidos);
                                }
                            }
                            // A transmissão começou, parou ou trocou de fps. O
                            // próximo tique já reavaliaria tudo, mas do ritmo
                            // ocioso isso levaria meio segundo: acerta agora.
                            Some(Action::RestartFrameTicker) => {
                                let ritmo = rhythm(desired_capture(
                                    streaming, video.wants_video(), &active,
                                    ladder.current(), tela,
                                ));
                                if ritmo != ticker_interval {
                                    ticker_interval = ritmo;
                                    frame_ticker = interval(ritmo);
                                    frame_ticker
                                        .set_missed_tick_behavior(MissedTickBehavior::Delay);
                                }
                            }
                            // Métricas do computador: responde com o mesmo
                            // request_id, como a lista de aplicativos.
                            Some(Action::ListMonitors { request_id }) => {
                                let reply = serde_json::to_string(
                                    &ClientMessage::MonitorList {
                                        request_id,
                                        monitors: crate::capture::monitors(),
                                        selected: tela,
                                    },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            Some(Action::SetMonitor { monitor: novo }) => {
                                if novo != tela {
                                    tela = novo;
                                    // Nada mais a fazer: a captura é função do
                                    // estado, e o próximo tique vê que o
                                    // monitor mudou e reabre a thread sozinho.
                                    match tela {
                                        Some(id) => println!("Capturando o monitor {id}"),
                                        None => println!("Capturando o monitor principal"),
                                    }
                                }
                            }
                            Some(Action::SystemInfo { request_id }) => {
                                let stats = monitor.snapshot();
                                let reply = serde_json::to_string(
                                    &ClientMessage::SystemStats { request_id, stats },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            Some(Action::ClipboardGet { request_id }) => {
                                let texto = clipboard.read().unwrap_or_default();
                                let arquivos = clipboard.files();
                                // A imagem entra só aqui, na resposta a um
                                // pedido - o aviso automático de cópia continua
                                // sendo só texto. Ver `clipboard::Clipboard`.
                                let imagem = clipboard.image();
                                let reply = serde_json::to_string(
                                    &ClientMessage::Clipboard {
                                        request_id,
                                        text: texto,
                                        files: arquivos.entries,
                                        ignored: arquivos.ignored,
                                        image: imagem.as_ref().map(|i| {
                                            use base64::Engine;
                                            base64::engine::general_purpose::STANDARD
                                                .encode(&i.bytes)
                                        }),
                                        image_mime: imagem
                                            .as_ref()
                                            .map(|i| i.mime.to_string()),
                                        image_width: imagem.as_ref().map(|i| i.width),
                                        image_height: imagem.as_ref().map(|i| i.height),
                                    },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            Some(Action::ClipboardSet { text }) => {
                                if let Err(e) = clipboard.write(&text) {
                                    eprintln!("{e}");
                                }
                            }
                            Some(Action::ClipboardSync { enabled }) => {
                                clipboard_sync = enabled;
                                println!(
                                    "Área de transferência: sincronia automática {}",
                                    if enabled { "ligada" } else { "desligada" }
                                );
                                // Ligar não deve despejar o que já estava
                                // copiado antes: marca o atual como visto.
                                if enabled {
                                    let _ = clipboard.changed();
                                }
                            }
                            Some(Action::KeepAwake { enabled }) => {
                                keep_awake = enabled;
                                awake.set(crate::awake::should_hold(
                                    enabled,
                                    crate::awake::power_source(),
                                ));
                                if let Ok(mut e) = estado.lock() {
                                    e.keep_awake = enabled;
                                    e.segurando = awake.holding();
                                }
                                // Grava para valer no próximo login. Uma falha
                                // aqui não desfaz o efeito imediato: o pedido
                                // já está de pé, só não sobreviveria a um
                                // reinício - e dizer isso é melhor que fingir
                                // que deu certo.
                                let mut cfg = crate::load_config();
                                cfg.set(
                                    "DESKSIDE_KEEP_AWAKE",
                                    if enabled { "1" } else { "0" },
                                );
                                if let Err(e) = crate::save_config(&cfg) {
                                    eprintln!("Não consegui gravar a escolha: {e}");
                                }
                            }
                            Some(Action::KeepAwakeInfo { request_id }) => {
                                let estado = ClientMessage::KeepAwakeState {
                                    request_id,
                                    enabled: keep_awake,
                                    holding: awake.holding(),
                                    source: crate::awake::power_source(),
                                };
                                let texto = serde_json::to_string(&estado)?;
                                ws.send(Message::Text(texto)).await?;
                            }
                            Some(Action::LaunchMany { request_id, itens }) => {
                                // Fora do laço: abrir quatro programas, com o
                                // intervalo entre eles e a espera pela janela de
                                // cada um, leva vários segundos. Segurar o laço
                                // por esse tempo pararia a captura de tela
                                // junto - justamente enquanto a pessoa está
                                // olhando o ambiente ser montado.
                                let quantos = itens.len();
                                println!("Abrindo {quantos} programa(s) do perfil");
                                let results = tokio::task::spawn_blocking(move || {
                                    crate::lote::abrir_todos(
                                        &itens,
                                        crate::lote::ESPERA_PADRAO,
                                        abrir_e_posicionar,
                                    )
                                })
                                .await
                                .unwrap_or_default();
                                let reply = serde_json::to_string(
                                    &ClientMessage::LaunchManyResult {
                                        request_id,
                                        results,
                                    },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            Some(Action::RunAutomation { request_id, steps }) => {
                                // Fora do laço, e aqui isso importa mais que
                                // nunca: uma automação com esperas pode levar
                                // meio minuto, e segurar o laço por esse tempo
                                // pararia a captura de tela junto.
                                let quantos = steps.len();
                                println!("Rodando automação de {quantos} passo(s)");
                                let results = tokio::task::spawn_blocking(move || {
                                    crate::automacao::executar(
                                        &steps,
                                        std::thread::sleep,
                                        executar_passo,
                                    )
                                })
                                .await
                                .unwrap_or_default();
                                let reply = serde_json::to_string(
                                    &ClientMessage::AutomationResult {
                                        request_id,
                                        results,
                                    },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            Some(Action::Brightness {
                                request_id,
                                level,
                                delta,
                            }) => {
                                // Fica no laço porque a resposta sai pelo
                                // socket. O ajuste em si custa um processo do
                                // PowerShell, então vai para uma thread de
                                // bloqueio: segurar o laço por um segundo
                                // pararia a captura de tela junto.
                                let resultado = tokio::task::spawn_blocking(move || {
                                    crate::brightness::ajustar(level, delta)
                                })
                                .await
                                .unwrap_or_else(|e| Err(format!("o ajuste não terminou: {e}")));
                                let estado = match resultado {
                                    Ok(nivel) => ClientMessage::BrightnessState {
                                        request_id,
                                        level: Some(nivel),
                                        error: None,
                                    },
                                    Err(motivo) => ClientMessage::BrightnessState {
                                        request_id,
                                        level: None,
                                        error: Some(motivo),
                                    },
                                };
                                let texto = serde_json::to_string(&estado)?;
                                ws.send(Message::Text(texto)).await?;
                            }
                            Some(Action::SetIceServers { servers }) => {
                                video.set_ice_servers(servers);
                            }
                            // Som do computador: ligar e desligar a captura.
                            Some(Action::SetAudio { enabled, gain }) => {
                                // O ganho vale mesmo com a captura já ligada:
                                // é assim que o controle do telefone mexe no
                                // volume sem cortar o som.
                                audio_gain.set(gain);
                                if !enabled {
                                    // O `Drop` da captura para a placa de som.
                                    if audio.take().is_some() {
                                        println!("Áudio: desligado");
                                    }
                                } else if audio.is_none() {
                                    match crate::audio::start(
                                        audio_tx.clone(),
                                        Arc::clone(&audio_gain),
                                    ) {
                                        Ok(captura) => {
                                            audio = Some(captura);
                                            println!("Áudio: ligado");
                                        }
                                        Err(e) => eprintln!("Áudio indisponível: {e}"),
                                    }
                                }
                            }
                            // Primeiro plano: pode custar um PowerShell na
                            // primeira vez que um programa aparece, então vai
                            // para uma thread como as outras coisas lentas.
                            Some(Action::ForegroundInfo { request_id }) => {
                                let watcher = Arc::clone(&foreground);
                                let app = tokio::task::spawn_blocking(move || {
                                    // Um `unwrap` aqui derrubaria o agente se
                                    // outra thread tivesse entrado em pânico
                                    // com o cadeado na mão; sem ícone é pior
                                    // que com, mas não é motivo para cair.
                                    watcher.lock().ok().and_then(|mut w| w.current())
                                })
                                .await
                                .unwrap_or(None);
                                let reply = serde_json::to_string(
                                    &ClientMessage::ForegroundApp { request_id, app },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            // Listar uma pasta toca o disco: sai do event loop.
                            Some(Action::ListFiles { request_id, path }) => {
                                let resultado = tokio::task::spawn_blocking(move || {
                                    crate::files::list(&path)
                                })
                                .await
                                .unwrap_or_else(|e| Err(format!("tarefa falhou: {e}")));
                                // Erro vira erro, e não pasta vazia: "sem
                                // permissão" e "não tem nada aqui" são coisas
                                // diferentes para quem está procurando algo.
                                let reply = match resultado {
                                    Ok(listing) => ClientMessage::FileList {
                                        request_id,
                                        listing: Some(listing),
                                        error: None,
                                    },
                                    Err(e) => {
                                        eprintln!("Falha ao listar pasta: {e}");
                                        ClientMessage::FileList {
                                            request_id,
                                            listing: None,
                                            error: Some(e),
                                        }
                                    }
                                };
                                ws.send(Message::Text(serde_json::to_string(&reply)?)).await?;
                            }
                            // Leitura em thread própria, publicando pedaços no
                            // canal limitado: é ele que segura o disco quando a
                            // rede não acompanha.
                            Some(Action::ReadFile { transfer_id, path }) => {
                                let parar = Arc::new(std::sync::atomic::AtomicBool::new(false));
                                reads.insert(transfer_id.clone(), Arc::clone(&parar));
                                let saida = file_tx.clone();
                                tokio::task::spawn_blocking(move || {
                                    send_file(&transfer_id, &path, &saida, &parar);
                                });
                            }
                            Some(Action::WriteBegin { transfer_id, name, size }) => {
                                let resultado = if size > crate::files::MAX_TRANSFER_BYTES {
                                    Err(format!(
                                        "arquivo maior que o limite de {} MB",
                                        crate::files::MAX_TRANSFER_BYTES / 1024 / 1024
                                    ))
                                } else {
                                    crate::files::Incoming::create(
                                        &name,
                                        crate::files::MAX_TRANSFER_BYTES,
                                    )
                                };
                                match resultado {
                                    Ok(arquivo) => {
                                        uploads.insert(transfer_id, (arquivo, 0));
                                    }
                                    Err(e) => {
                                        eprintln!("Recusei receber {name}: {e}");
                                        let reply = serde_json::to_string(&file_failed(
                                            transfer_id, e,
                                        ))?;
                                        ws.send(Message::Text(reply)).await?;
                                    }
                                }
                            }
                            Some(Action::WriteChunk { transfer_id, seq, data }) => {
                                if let Some((arquivo, esperado)) = uploads.get_mut(&transfer_id) {
                                    let erro = if seq != *esperado {
                                        // Fora de ordem: o arquivo montado aqui
                                        // não seria o que saiu do celular.
                                        Some(format!(
                                            "pedaço fora de ordem (esperava {esperado}, veio {seq})"
                                        ))
                                    } else {
                                        match decode_chunk(&data) {
                                            Ok(bytes) => match arquivo.write(&bytes) {
                                                Ok(()) => {
                                                    *esperado += 1;
                                                    None
                                                }
                                                Err(e) => Some(e),
                                            },
                                            Err(e) => Some(e),
                                        }
                                    };
                                    if let Some(e) = erro {
                                        eprintln!("Falha ao receber arquivo: {e}");
                                        if let Some((arquivo, _)) = uploads.remove(&transfer_id) {
                                            arquivo.cancel();
                                        }
                                        let reply = serde_json::to_string(&file_failed(
                                            transfer_id, e,
                                        ))?;
                                        ws.send(Message::Text(reply)).await?;
                                    }
                                }
                            }
                            Some(Action::WriteEnd { transfer_id }) => {
                                if let Some((arquivo, _)) = uploads.remove(&transfer_id) {
                                    let mensagem = match arquivo.finish() {
                                        Ok(caminho) => {
                                            println!("Arquivo recebido em {caminho}");
                                            ClientMessage::FileDone {
                                                transfer_id,
                                                ok: true,
                                                detail: Some(caminho),
                                                size: None,
                                            }
                                        }
                                        Err(e) => {
                                            eprintln!("Falha ao salvar arquivo: {e}");
                                            file_failed(transfer_id, e)
                                        }
                                    };
                                    ws.send(Message::Text(serde_json::to_string(&mensagem)?))
                                        .await?;
                                }
                            }
                            Some(Action::CancelTransfer { transfer_id }) => {
                                // Vale para os dois sentidos: a bandeira para a
                                // leitura, e o arquivo pela metade é apagado.
                                if let Some(parar) = reads.remove(&transfer_id) {
                                    parar.store(true, std::sync::atomic::Ordering::Relaxed);
                                }
                                if let Some((arquivo, _)) = uploads.remove(&transfer_id) {
                                    arquivo.cancel();
                                }
                            }
                            // Listar aplicativos pode demorar (varre o menu
                            // Iniciar / consulta processos): roda fora do event
                            // loop e responde ao backend com o mesmo request_id.
                            Some(Action::ListApps { request_id, kind }) => {
                                let apps = tokio::task::spawn_blocking(move || {
                                    crate::apps::list(kind)
                                })
                                .await
                                .unwrap_or_default();
                                let reply = serde_json::to_string(
                                    &ClientMessage::AppList { request_id, apps },
                                )?;
                                ws.send(Message::Text(reply)).await?;
                            }
                            // Negociação de vídeo. A resposta e os candidatos
                            // locais voltam pelo canal de sinalização, não aqui.
                            Some(Action::WebrtcOffer { session_id, sdp }) => {
                                if let Err(e) = video.offer(&session_id, &sdp).await {
                                    eprintln!("Falha ao negociar vídeo ({session_id}): {e}");
                                } else {
                                    // Um app que entra no meio da transmissão
                                    // precisa de um quadro-chave: sem ele, recebe
                                    // quadros que referenciam imagens que nunca
                                    // chegaram, e fica na tela preta. Vale para
                                    // toda sessão nova — inclusive a reconexão
                                    // que acontece ao trocar a qualidade no app.
                                    if let Some(enc) = encoder
                                        .lock()
                                        .unwrap_or_else(|e| e.into_inner())
                                        .as_mut()
                                    {
                                        enc.request_keyframe();
                                    }
                                    // O contador de sequência do app recomeça em
                                    // cada sessão, então o nosso também.
                                    input_order.reset();
                                    println!(
                                        "Vídeo por WebRTC negociado (sessão {session_id}) \
                                         — próximo quadro será chave"
                                    );
                                }
                            }
                            Some(Action::WebrtcIce {
                                session_id, candidate, sdp_mid, sdp_mline_index,
                            }) => {
                                let conhecida = video.candidate(
                                    &session_id, &candidate, sdp_mid, sdp_mline_index,
                                ).await;
                                if !conhecida {
                                    // Candidato atrasado de sessão encerrada:
                                    // ignorar é o certo, não é falha.
                                    println!(
                                        "Candidato ICE de sessão desconhecida \
                                         ({session_id}): ignorado"
                                    );
                                }
                            }
                            Some(Action::WebrtcClose { session_id }) => {
                                if video.close(&session_id).await {
                                    println!("Sessão de vídeo encerrada ({session_id})");
                                }
                                // Sem ninguém para ouvir, a placa de som não
                                // tem por que continuar sendo capturada.
                                if video.is_empty() && audio.take().is_some() {
                                    println!("Áudio: desligado (ninguém ouvindo)");
                                }
                            }
                            None => {}
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        println!("Conexão encerrada pelo servidor");
                        // Sem o backend não há como sinalizar: solta as sessões
                        // de vídeo em vez de deixá-las penduradas.
                        video.close_all().await;
                        // `take` e não `drop`: fora do Windows a captura é um
                        // stub sem `Drop`, e o clippy reclama do descarte.
                        let _ = audio.take();
                        return Ok(());
                    }
                    Some(Ok(_)) => {} // ping/pong/binário: ignorados por ora
                    Some(Err(e)) => {
                        video.close_all().await;
                        // `take` e não `drop`: fora do Windows a captura é um
                        // stub sem `Drop`, e o clippy reclama do descarte.
                        let _ = audio.take();
                        return Err(Box::new(e));
                    }
                }
            }
        }
    }
}

/// Resumo periódico da transmissão de vídeo.
///
/// Existe porque "está travado" não é diagnóstico. Com o ritmo real, o custo de
/// codificação e o tamanho do quadro em mãos, dá para saber se o gargalo é a
/// captura, o codificador ou a rede — em vez de trocar palpites.
#[derive(Debug)]
struct VideoStats {
    since: std::time::Instant,
    frames: u32,
    /// Tiques em que a captura ainda não tinha quadro novo: se este número é
    /// alto, o gargalo é a captura, não a codificação.
    starved: u32,
    encode_total: Duration,
    bytes: usize,
    /// Resolução em uso, para dar contexto aos milissegundos.
    size: (u32, u32),
}

impl Default for VideoStats {
    fn default() -> Self {
        Self {
            since: std::time::Instant::now(),
            frames: 0,
            starved: 0,
            encode_total: Duration::ZERO,
            bytes: 0,
            size: (0, 0),
        }
    }
}

impl VideoStats {
    const INTERVAL: Duration = Duration::from_secs(5);

    fn record(&mut self, encode: Duration, bytes: usize, size: (u32, u32)) {
        self.frames += 1;
        self.encode_total += encode;
        self.bytes += bytes;
        self.size = size;
    }

    fn report_if_due(&mut self, label: &str, capture_ms: Option<f64>) {
        let elapsed = self.since.elapsed();
        if elapsed < Self::INTERVAL || self.frames == 0 {
            return;
        }
        let seconds = elapsed.as_secs_f64();
        let captura = match capture_ms {
            Some(ms) => format!("{ms:.1} ms"),
            None => "?".to_string(),
        };
        println!(
            "{label} {}x{}: {:.1} fps · captura {captura}/quadro · codificação \
             {:.1} ms/quadro · {:.1} KB/quadro · {:.2} Mbps · {} tique(s) sem \
             quadro novo",
            self.size.0,
            self.size.1,
            self.frames as f64 / seconds,
            self.encode_total.as_secs_f64() * 1000.0 / self.frames as f64,
            self.bytes as f64 / self.frames as f64 / 1024.0,
            self.bytes as f64 * 8.0 / seconds / 1_000_000.0,
            self.starved,
        );
        *self = Self::default();
    }
}

/// Fim de transferência com falha, na forma que o backend espera.
fn file_failed(transfer_id: String, detail: String) -> ClientMessage {
    ClientMessage::FileDone {
        transfer_id,
        ok: false,
        detail: Some(detail),
        size: None,
    }
}

/// Decodifica um pedaço vindo em base64.
fn decode_chunk(data: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| format!("pedaço ilegível: {e}"))
}

/// Lê um arquivo e o publica em pedaços, até acabar ou alguém cancelar.
///
/// Roda numa thread de bloqueio e usa `blocking_send`: quando o canal enche —
/// porque a rede não vaza tão rápido quanto o disco lê — esta função **para**
/// aqui. É essa espera que impede um arquivo de 100 MB de virar 100 MB de fila
/// na memória.
fn send_file(
    transfer_id: &str,
    path: &str,
    outbox: &tokio::sync::mpsc::Sender<ClientMessage>,
    stop: &Arc<std::sync::atomic::AtomicBool>,
) {
    use base64::Engine;
    use std::io::Read;
    use std::sync::atomic::Ordering::Relaxed;

    let (mut file, size) = match crate::files::open_read(path) {
        Ok(aberto) => aberto,
        Err(e) => {
            let _ = outbox.blocking_send(file_failed(transfer_id.to_string(), e));
            return;
        }
    };
    if size > crate::files::MAX_TRANSFER_BYTES {
        let _ = outbox.blocking_send(file_failed(
            transfer_id.to_string(),
            format!(
                "arquivo maior que o limite de {} MB",
                crate::files::MAX_TRANSFER_BYTES / 1024 / 1024
            ),
        ));
        return;
    }

    let mut buffer = vec![0u8; crate::files::CHUNK_BYTES];
    let mut seq = 0u64;
    loop {
        if stop.load(Relaxed) {
            return; // cancelado: nem o fim precisa ser anunciado
        }
        let lidos = match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                let _ = outbox.blocking_send(file_failed(
                    transfer_id.to_string(),
                    format!("falha ao ler: {e}"),
                ));
                return;
            }
        };
        let chunk = ClientMessage::FileChunk {
            transfer_id: transfer_id.to_string(),
            seq,
            data: base64::engine::general_purpose::STANDARD.encode(&buffer[..lidos]),
        };
        // Canal fechado = o laço morreu (conexão caiu). Sem motivo para seguir.
        if outbox.blocking_send(chunk).is_err() {
            return;
        }
        seq += 1;
    }
    let _ = outbox.blocking_send(ClientMessage::FileDone {
        transfer_id: transfer_id.to_string(),
        ok: true,
        detail: None,
        size: Some(size),
    });
}

/// Contagem do som que sai, para o console dizer se ele está saindo.
///
/// Serve a uma pergunta específica e recorrente: "liguei e não ouvi nada" -
/// aqui se vê se o computador chegou a capturar e a mandar, o que separa um
/// problema de captura de um problema do telefone.
#[derive(Debug)]
struct AudioStats {
    packets: u64,
    bytes: u64,
    since: std::time::Instant,
}

impl Default for AudioStats {
    fn default() -> Self {
        Self {
            packets: 0,
            bytes: 0,
            since: std::time::Instant::now(),
        }
    }
}

impl AudioStats {
    const INTERVAL: Duration = Duration::from_secs(10);

    fn count(&mut self, bytes: usize) {
        self.packets += 1;
        self.bytes += bytes as u64;
    }

    /// Devolve a linha de log quando passaram 10 s, e zera a contagem.
    fn report_if_due(&mut self, ouvindo: bool) -> Option<String> {
        let elapsed = self.since.elapsed();
        if elapsed < Self::INTERVAL {
            return None;
        }
        let segundos = elapsed.as_secs_f64().max(0.001);
        let kbps = (self.bytes as f64 * 8.0 / 1000.0) / segundos;
        // Descartados: quadros que a placa produziu e o laço não recolheu a
        // tempo. Qualquer número diferente de zero aqui é picote garantido, e
        // a causa é deste lado - não da rede.
        let perdidos = crate::audio::take_dropped();
        let aviso = if perdidos > 0 {
            format!(", {perdidos} DESCARTADOS")
        } else {
            String::new()
        };
        let linha = format!(
            "Áudio: {} quadros em {segundos:.0}s ({kbps:.0} kbps{aviso}), faixa {}",
            self.packets,
            if ouvindo { "conectada" } else { "SEM ninguém ouvindo" }
        );
        self.packets = 0;
        self.bytes = 0;
        self.since = std::time::Instant::now();
        Some(linha)
    }
}

/// Ritmo com que a agenda é consultada.
///
/// Dez segundos para uma decisão com precisão de minuto: folga de sobra, e a
/// mesma folga que `ATRASO_MAXIMO_MINUTOS` cobre quando o relógio não observa o
/// instante exato das 18:00.
const RITMO_DA_AGENDA: Duration = Duration::from_secs(10);

/// Vigia o relógio e dispara as automações agendadas. Nunca retorna.
///
/// **Fora do laço da conexão, de propósito.** Dentro dele, um Wi-Fi que troca de
/// rede às 17:59 levaria as dezoito horas junto: o laço morre, reconecta e a
/// agenda voltaria zerada. Aqui a única coisa que a conexão faz é entregar a
/// lista; o disparo é do computador, e continua acontecendo com o servidor fora
/// do ar e com o celular na gaveta.
pub async fn vigiar_agenda(agenda: crate::agenda::Compartilhada, estado: crate::gui::Compartilhado) {
    let mut relogio = interval(RITMO_DA_AGENDA);
    loop {
        relogio.tick().await;
        // Fora do Windows não há relógio local nem automação para rodar: o
        // agente de desenvolvimento roda no terminal.
        let Some((dia, semana, minuto)) = crate::agenda::agora_local() else {
            continue;
        };

        // O cancelamento é lido **antes** de avaliar: cancelar às 17:59 e ver a
        // automação rodar mesmo assim seria o pior desfecho possível daqui.
        let pedido = estado.lock().ok().and_then(|mut e| e.cancelar.take());
        if let Some(id) = pedido {
            println!("Agenda: cancelada por hoje ({id})");
            if let Ok(mut a) = agenda.lock() {
                a.cancelar(&id, dia);
            }
            esquecer_aviso(&estado, &id);
        }

        let eventos = match agenda.lock() {
            Ok(mut a) => a.avaliar(dia, semana, minuto),
            Err(_) => continue,
        };
        for evento in eventos {
            match evento {
                crate::agenda::Evento::Avisar { id, nome, faltam } => {
                    println!("Agenda: \"{nome}\" roda em {faltam} min");
                    if let Ok(mut e) = estado.lock() {
                        e.aviso = Some(crate::gui::AvisoDeAgenda {
                            id,
                            nome,
                            minuto_do_dia: minuto.saturating_add(faltam.max(0) as u16),
                        });
                    }
                }
                crate::agenda::Evento::Disparar { id, nome, passos } => {
                    println!("Agenda: rodando \"{nome}\"");
                    esquecer_aviso(&estado, &id);
                    // Sem `await`: uma automação com esperas leva meio minuto, e
                    // segurar esta tarefa por esse tempo atrasaria a automação
                    // seguinte - duas marcadas para o mesmo horário são o caso
                    // normal, não a exceção.
                    tokio::task::spawn_blocking(move || {
                        crate::automacao::executar(&passos, std::thread::sleep, executar_passo)
                    });
                }
            }
        }
    }
}

/// Tira o aviso da bandeja, se ele for **desta** automação.
///
/// A conferência do identificador importa: com duas automações próximas, apagar
/// cegamente ao disparar a primeira levaria junto o aviso da segunda, e a pessoa
/// perderia a chance de cancelar aquela que ainda não rodou.
fn esquecer_aviso(estado: &crate::gui::Compartilhado, id: &str) {
    if let Ok(mut e) = estado.lock() {
        if e.aviso.as_ref().is_some_and(|a| a.id == id) {
            e.aviso = None;
        }
    }
}

/// Executa um passo de automação.
///
/// Cada braço chama exatamente o que o resto do agente já fazia por outro
/// caminho - é isso que garante que a automação não tenha nenhum poder novo.
///
/// Roda numa thread de bloqueio, então pode dormir e pode chamar PowerShell à
/// vontade: quem a chama já saiu do laço da conexão.
fn executar_passo(acao: &crate::automacao::Acao) -> crate::automacao::Desfecho {
    use crate::automacao::{Acao, Desfecho};
    match acao {
        Acao::Launch { id, zone } => {
            let item = crate::lote::Item {
                id: id.clone(),
                zone: *zone,
            };
            match abrir_e_posicionar(&item) {
                crate::lote::Passo::Ok => Desfecho::Ok,
                crate::lote::Passo::ComAviso(a) => Desfecho::ComAviso(a),
                crate::lote::Passo::Falhou(m) => Desfecho::Falhou(m),
            }
        }
        Acao::Close { name } => match crate::apps::close_by_name(name) {
            Ok(()) => Desfecho::Ok,
            Err(motivo) => Desfecho::Falhou(motivo),
        },
        Acao::CloseAll => match crate::apps::close_all() {
            // `ComAviso` mesmo quando dá certo: a quantidade é informação útil
            // no relatório da automação. Fechar zero programa não é erro - é o
            // computador já estando limpo -, mas ver "0 programa(s)" evita a
            // dúvida de ter ou não funcionado.
            Ok(quantos) => Desfecho::ComAviso(format!("{quantos} programa(s) fechado(s)")),
            Err(motivo) => Desfecho::Falhou(motivo),
        },
        Acao::Input { action } => {
            match crate::injector::controller().apply(action) {
                Ok(()) => Desfecho::Ok,
                Err(motivo) => Desfecho::Falhou(motivo),
            }
        }
        Acao::Media { action } => {
            match crate::injector::controller().media(*action) {
                Ok(()) => Desfecho::Ok,
                Err(motivo) => Desfecho::Falhou(motivo),
            }
        }
        Acao::Brightness { level, delta } => {
            match crate::brightness::ajustar(*level, *delta) {
                Ok(_) => Desfecho::Ok,
                Err(motivo) => Desfecho::Falhou(motivo),
            }
        }
        Acao::Power { action } => match crate::power::apply(*action) {
            Ok(()) => Desfecho::Ok,
            Err(motivo) => Desfecho::Falhou(motivo),
        },
    }
}

/// Abre um programa e, se houver zona, põe a janela dele no lugar.
///
/// **A fotografia das janelas é tirada antes de abrir.** É o que dispensa
/// descobrir de qual processo a janela é - e é por isso que funciona com
/// navegador, Office e Electron, em que quem abre a janela não é o processo que
/// foi lançado. A pergunta deixa de ser "de quem é esta janela" e passa a ser
/// "qual janela não existia agora há pouco".
///
/// Falhar em posicionar **não** é falhar em abrir: o programa está lá. Vira
/// aviso, e o app diz que a janela não foi para o lugar sem afirmar que o
/// programa não abriu.
fn abrir_e_posicionar(item: &crate::lote::Item) -> crate::lote::Passo {
    let antes = item
        .zone
        .as_ref()
        .map(|_| crate::janelas::janelas_visiveis());

    if let Err(motivo) = crate::apps::launch(&item.id) {
        return crate::lote::Passo::Falhou(motivo);
    }

    match (item.zone.as_ref(), antes) {
        (Some(zona), Some(antes)) => {
            match crate::janelas::posicionar_nova_janela(&antes, zona) {
                Ok(()) => crate::lote::Passo::Ok,
                Err(motivo) => crate::lote::Passo::ComAviso(motivo),
            }
        }
        _ => crate::lote::Passo::Ok,
    }
}

/// Algo que o laço principal precisa fazer depois de tratar uma mensagem —
/// tarefas que exigem `await` (recriar o ticker, responder ao servidor).
enum Action {
    /// A agenda mudou: trocar a lista do que dispara sozinho.
    ///
    /// Volta como ação em vez de ser aplicada onde chega porque quem guarda a
    /// agenda é o laço principal — é ele que tem o relógio.
    SetSchedule { items: Vec<crate::protocol::AgendaItem> },
    /// A transmissão ou o fps mudaram: reavaliar o ritmo do `frame_ticker`.
    RestartFrameTicker,
    /// Medir CPU/memória/disco e responder ao backend.
    SystemInfo { request_id: String },
    /// Listar os monitores e responder ao backend.
    ListMonitors { request_id: String },
    /// Trocar o monitor capturado. `None` volta ao principal.
    SetMonitor { monitor: Option<u32> },
    /// Descobrir o programa em primeiro plano e responder ao backend.
    ForegroundInfo { request_id: String },
    /// Ligar ou desligar a captura do som do computador, com o ganho.
    SetAudio { enabled: bool, gain: f32 },
    /// Ler a área de transferência e responder ao backend.
    ClipboardGet { request_id: String },
    /// Escrever na área de transferência do computador.
    ClipboardSet { text: String },
    /// Ligar/desligar o aviso automático de cópia nova.
    ClipboardSync { enabled: bool },
    /// Ligar/desligar o "manter o computador pronto", gravando a escolha.
    KeepAwake { enabled: bool },
    /// Responder ao backend se o computador está sendo mantido pronto.
    KeepAwakeInfo { request_id: String },
    /// Abrir vários programas e responder com o resultado de cada um.
    LaunchMany {
        request_id: String,
        itens: Vec<crate::lote::Item>,
    },
    /// Rodar uma automação e responder com o resultado de cada passo.
    RunAutomation {
        request_id: String,
        steps: Vec<crate::automacao::Passo>,
    },
    /// Ajustar o brilho e responder com o resultado.
    Brightness {
        request_id: String,
        level: Option<u8>,
        delta: Option<i16>,
    },
    /// Usar os servidores ICE que o backend mandou (STUN e TURN).
    SetIceServers {
        servers: Vec<crate::protocol::IceServer>,
    },
    /// Listar uma pasta e responder ao backend.
    ListFiles { request_id: String, path: String },
    /// Ler um arquivo e mandá-lo em pedaços.
    ReadFile { transfer_id: String, path: String },
    /// Começar a receber um arquivo vindo do celular.
    WriteBegin {
        transfer_id: String,
        name: String,
        size: u64,
    },
    /// Um pedaço do arquivo que está chegando.
    WriteChunk {
        transfer_id: String,
        seq: u64,
        data: String,
    },
    /// Fim do envio: publicar o arquivo.
    WriteEnd { transfer_id: String },
    /// Desistir de uma transferência nos dois sentidos.
    CancelTransfer { transfer_id: String },
    /// Listar aplicativos e responder ao backend.
    ListApps {
        request_id: String,
        kind: crate::apps::AppKind,
    },
    /// Negociar uma sessão de vídeo por WebRTC (criar a conexão e responder).
    WebrtcOffer { session_id: String, sdp: String },
    /// Adicionar um candidato ICE do app a uma sessão.
    WebrtcIce {
        session_id: String,
        candidate: String,
        sdp_mid: Option<String>,
        sdp_mline_index: Option<u32>,
    },
    /// Encerrar a sessão de vídeo de um app que saiu.
    WebrtcClose { session_id: String },
}

/// Trata uma mensagem de texto do servidor. O que exige `await` volta como
/// [`Action`] para o laço principal executar.
fn handle_server_text(
    text: &str,
    injector: &mut dyn crate::injector::InputInjector,
    streaming: &mut bool,
    active: &mut StreamConfig,
    last_frame: &mut u64,
) -> Option<Action> {
    match serde_json::from_str::<ServerMessage>(text) {
        Ok(ServerMessage::Welcome {
            server_version,
            ice_servers,
        }) => {
            println!("Registrado no backend (servidor v{server_version})");
            if !ice_servers.is_empty() {
                return Some(Action::SetIceServers { servers: ice_servers });
            }
        }
        Ok(ServerMessage::Ack) => { /* heartbeat confirmado */ }
        Ok(ServerMessage::Error { message }) => {
            eprintln!("Erro do backend: {message}");
        }
        Ok(ServerMessage::PairCode {
            code,
            expires_in_seconds,
        }) => {
            let minutes = expires_in_seconds / 60;
            println!();
            println!("┌───────────────────────────────────────────┐");
            println!("│  Código de pareamento: {code:<19}│");
            println!("└───────────────────────────────────────────┘");
            println!("Informe esse código no aplicativo (expira em {minutes} min).");
            // Também mostra o código sem depender do terminal (arquivo + janela),
            // para quando o agente roda em segundo plano.
            crate::notify::announce_pairing_code(&code, expires_in_seconds);
        }
        Ok(ServerMessage::Paired { user_email }) => {
            println!("✓ Dispositivo já pareado com a conta {user_email}");
            println!(
                "  (para gerar um novo código, remova este computador no app — \
                 o código aparece aqui automaticamente)"
            );
            // Já pareado: remove o arquivo de código antigo, se houver.
            crate::notify::clear_pairing_code();
        }
        Ok(ServerMessage::Input { action }) => {
            if let Err(e) = injector.apply(&action) {
                eprintln!("Falha ao aplicar entrada: {e}");
            }
        }
        Ok(ServerMessage::StartStream {
            max_fps,
            quality,
            max_width,
        }) => {
            *streaming = true;
            // Sessão nova (ou qualidade nova): o app ainda não tem frame algum,
            // então o próximo precisa ir mesmo que a tela esteja parada.
            *last_frame = crate::capture::NO_FRAME;
            active.fps = max_fps;
            if let Some(q) = quality {
                active.quality = q;
            }
            if let Some(w) = max_width {
                active.max_width = w;
            }
            println!(
                "Transmissão de tela iniciada (~{} fps, largura máx. {}px, qualidade {})",
                active.fps, active.max_width, active.quality
            );
            // O ritmo (e a captura) saem da config, então basta pedir a
            // reavaliação — não é preciso comparar com o fps anterior.
            return Some(Action::RestartFrameTicker);
        }
        Ok(ServerMessage::StopStream) => {
            *streaming = false;
            // O backend descarta o frame guardado ao parar: zera o hash para o
            // próximo start não concluir que "a tela não mudou".
            *last_frame = crate::capture::NO_FRAME;
            println!("Transmissão de tela encerrada");
            // Se ninguém mais quer a tela, a captura precisa ser encerrada e o
            // ticker cair para o ritmo ocioso — quem decide isso é o laço.
            return Some(Action::RestartFrameTicker);
        }
        Ok(ServerMessage::Power { action }) => {
            println!("Comando de energia recebido: {action:?}");
            if let Err(e) = crate::power::apply(action) {
                eprintln!("Falha ao executar comando de energia: {e}");
            }
        }
        Ok(ServerMessage::Wake { mac }) => {
            println!("Acordando vizinho na LAN (Wake-on-LAN) → {mac}");
            if let Err(e) = crate::wol::send_magic_packet(&mac) {
                eprintln!("Falha ao enviar pacote mágico: {e}");
            }
        }
        Ok(ServerMessage::ListApps { request_id, kind }) => {
            return Some(Action::ListApps { request_id, kind });
        }
        // Medir exige `&mut` no monitor, que vive no laço: volta como ação.
        Ok(ServerMessage::ListMonitors { request_id }) => {
            return Some(Action::ListMonitors { request_id });
        }
        Ok(ServerMessage::SetMonitor { monitor }) => {
            return Some(Action::SetMonitor { monitor });
        }
        Ok(ServerMessage::SystemInfo { request_id }) => {
            return Some(Action::SystemInfo { request_id });
        }
        // Idem: o acompanhante do primeiro plano guarda memória entre uma
        // pergunta e outra, e essa memória vive no laço.
        Ok(ServerMessage::ForegroundInfo { request_id }) => {
            return Some(Action::ForegroundInfo { request_id });
        }
        // Ligar a placa de som é `await` e estado: volta como ação.
        Ok(ServerMessage::ClipboardGet { request_id }) => {
            return Some(Action::ClipboardGet { request_id });
        }
        Ok(ServerMessage::ClipboardSet { text }) => {
            return Some(Action::ClipboardSet { text });
        }
        Ok(ServerMessage::ClipboardSync { enabled }) => {
            return Some(Action::ClipboardSync { enabled });
        }
        // Gravar em disco e responder pelo socket: os dois vivem no laço.
        Ok(ServerMessage::KeepAwake { enabled }) => {
            return Some(Action::KeepAwake { enabled });
        }
        Ok(ServerMessage::KeepAwakeInfo { request_id }) => {
            return Some(Action::KeepAwakeInfo { request_id });
        }
        Ok(ServerMessage::Brightness {
            request_id,
            level,
            delta,
        }) => {
            return Some(Action::Brightness {
                request_id,
                level,
                delta,
            });
        }
        Ok(ServerMessage::Audio { enabled, gain }) => {
            return Some(Action::SetAudio { enabled, gain });
        }
        // Arquivos: tudo precisa do socket ou do estado das transferências, que
        // vivem no laço. Aqui só viram ação.
        Ok(ServerMessage::ListFiles { request_id, path }) => {
            return Some(Action::ListFiles { request_id, path });
        }
        Ok(ServerMessage::ReadFile { transfer_id, path }) => {
            return Some(Action::ReadFile { transfer_id, path });
        }
        Ok(ServerMessage::WriteFileBegin {
            transfer_id,
            name,
            size,
        }) => {
            return Some(Action::WriteBegin {
                transfer_id,
                name,
                size,
            });
        }
        Ok(ServerMessage::WriteFileChunk {
            transfer_id,
            seq,
            data,
        }) => {
            return Some(Action::WriteChunk {
                transfer_id,
                seq,
                data,
            });
        }
        Ok(ServerMessage::WriteFileEnd { transfer_id }) => {
            return Some(Action::WriteEnd { transfer_id });
        }
        Ok(ServerMessage::CancelTransfer { transfer_id }) => {
            return Some(Action::CancelTransfer { transfer_id });
        }
        Ok(ServerMessage::Media { action }) => {
            if let Err(e) = injector.media(action) {
                eprintln!("Falha ao aplicar comando de mídia: {e}");
            }
        }
        Ok(ServerMessage::LaunchApp { id }) => {
            println!("Abrindo aplicativo: {id}");
            if let Err(e) = crate::apps::launch(&id) {
                eprintln!("Falha ao abrir aplicativo: {e}");
            }
        }
        Ok(ServerMessage::LaunchMany {
            request_id,
            apps,
            zones,
        }) => {
            // Junta os dois vetores paralelos num item por programa. `zip` com
            // o vetor de zonas preenchido de `None` quando ele não veio: assim
            // o resto do caminho não precisa saber que houve compatibilidade
            // com agente antigo no meio.
            let zonas = zones.unwrap_or_default();
            let itens = apps
                .into_iter()
                .enumerate()
                .map(|(i, id)| crate::lote::Item {
                    id,
                    zone: zonas.get(i).copied().flatten(),
                })
                .collect();
            return Some(Action::LaunchMany { request_id, itens });
        }
        Ok(ServerMessage::RunAutomation { request_id, steps }) => {
            return Some(Action::RunAutomation { request_id, steps });
        }
        Ok(ServerMessage::SetSchedule { items }) => {
            return Some(Action::SetSchedule { items });
        }
        Ok(ServerMessage::FocusApp { id }) => {
            println!("Trazendo para frente (PID {id})");
            match id.parse::<u32>() {
                Ok(pid) => {
                    if let Err(e) = crate::janelas::focar(pid) {
                        eprintln!("Falha ao trazer para frente: {e}");
                    }
                }
                Err(_) => eprintln!("PID inválido: {id}"),
            }
        }
        Ok(ServerMessage::CloseApp { id }) => {
            println!("Encerrando aplicativo (PID {id})");
            if let Err(e) = crate::apps::close(&id) {
                eprintln!("Falha ao encerrar aplicativo: {e}");
            }
        }
        // Sinalização de WebRTC: tudo aqui precisa de `await` (criar conexão,
        // aplicar SDP, fechar), então volta como ação para o laço principal.
        Ok(ServerMessage::WebrtcOffer { session_id, sdp }) => {
            return Some(Action::WebrtcOffer { session_id, sdp });
        }
        Ok(ServerMessage::WebrtcIce {
            session_id,
            candidate,
            sdp_mid,
            sdp_mline_index,
        }) => {
            return Some(Action::WebrtcIce {
                session_id,
                candidate,
                sdp_mid,
                sdp_mline_index,
            });
        }
        Ok(ServerMessage::WebrtcClose { session_id }) => {
            return Some(Action::WebrtcClose { session_id });
        }
        Err(e) => eprintln!("Mensagem desconhecida do servidor: {text} ({e})"),
    }
    None
}

#[cfg(test)]
mod tests {
    #[test]
    fn contagem_de_audio_so_reporta_no_intervalo() {
        use super::AudioStats;
        let mut stats = AudioStats::default();
        stats.count(240);
        // Recém-criada: ainda não deu o intervalo, então não há o que dizer.
        assert!(stats.report_if_due(true).is_none());
        // Forçando o relógio para trás, a linha sai e a contagem zera.
        stats.since = std::time::Instant::now() - AudioStats::INTERVAL;
        let linha = stats.report_if_due(true).expect("devia reportar");
        assert!(linha.contains("1 quadros"), "{linha}");
        assert!(linha.contains("conectada"), "{linha}");
        assert_eq!(stats.packets, 0);
    }

    #[test]
    fn contagem_de_audio_avisa_quando_ninguem_ouve() {
        use super::AudioStats;
        let mut stats = AudioStats::default();
        stats.count(240);
        stats.since = std::time::Instant::now() - AudioStats::INTERVAL;
        let linha = stats.report_if_due(false).expect("devia reportar");
        assert!(linha.contains("SEM ninguém ouvindo"), "{linha}");
    }

    #[test]
    fn o_aviso_so_some_se_for_o_da_automacao_que_rodou() {
        // Com duas automações próximas, apagar o aviso cegamente levaria junto
        // o da segunda - e a pessoa perderia a chance de cancelar aquela que
        // ainda não rodou, sem nenhum sinal de que isso aconteceu.
        let estado = crate::gui::compartilhar(crate::gui::Estado {
            aviso: Some(crate::gui::AvisoDeAgenda {
                id: "b".into(),
                nome: "backup".into(),
                minuto_do_dia: 18 * 60,
            }),
            ..Default::default()
        });

        super::esquecer_aviso(&estado, "a");
        assert!(estado.lock().unwrap().aviso.is_some());

        super::esquecer_aviso(&estado, "b");
        assert!(estado.lock().unwrap().aviso.is_none());
    }

    use super::*;

    #[test]
    fn hello_is_built_from_identity() {
        let identity = AgentIdentity {
            device_id: "dev-1".into(),
            hostname: "dell-g5".into(),
            os: "linux".into(),
            agent_version: "0.1.0".into(),
            mac: Some("01:23:45:AB:CD:EF".into()),
        };
        assert_eq!(
            identity.hello(),
            ClientMessage::Hello {
                device_id: "dev-1".into(),
                hostname: "dell-g5".into(),
                os: "linux".into(),
                agent_version: "0.1.0".into(),
                mac: Some("01:23:45:AB:CD:EF".into()),
            }
        );
    }

    /// O degrau de topo: é onde toda sessão começa, e é o estado em que estes
    /// testes checam os tetos configurados.
    /// Uma captura pedida, para as comparações ficarem legíveis.
    fn quer(width: u32, fps: u32) -> Option<CaptureWanted> {
        Some(CaptureWanted { monitor: None, width, fps })
    }

    fn topo() -> crate::adaptive::Level {
        crate::adaptive::LADDER[0]
    }

    fn config() -> StreamConfig {
        StreamConfig {
            fps: 10,
            max_width: 1600,
            video_max_width: 1280,
            video_fps: 30,
            ..StreamConfig::default()
        }
    }

    #[test]
    fn ninguem_pedindo_a_tela_nao_pede_captura() {
        assert_eq!(desired_capture(false, false, &config(), topo(), None), None);
        assert_eq!(rhythm(None), IDLE_INTERVAL);
    }

    #[test]
    fn jpeg_usa_a_largura_e_o_fps_do_preset() {
        assert_eq!(desired_capture(true, false, &config(), topo(), None), quer(1600, 10));
        assert_eq!(
            rhythm(desired_capture(true, false, &config(), topo(), None)),
            Duration::from_millis(100)
        );
    }

    #[test]
    fn video_tem_teto_proprio_e_manda_no_ritmo() {
        // 1280 e não 1600: codificar custa por pixel (ver `video_max_width`).
        assert_eq!(desired_capture(true, true, &config(), topo(), None), quer(1280, 30));
        assert_eq!(
            rhythm(desired_capture(true, true, &config(), topo(), None)),
            Duration::from_millis(33)
        );
    }

    #[test]
    fn video_dispensa_a_transmissao_jpeg() {
        // O app pode ter vídeo sem nunca pedir `start_stream`.
        assert_eq!(desired_capture(false, true, &config(), topo(), None), quer(1280, 30));
    }

    #[test]
    fn o_degrau_de_topo_devolve_o_que_esta_configurado() {
        // O topo é ausência de limite, não um limite: quem configurou 60 fps
        // continua com 60. Se a escada virasse teto, ela passaria a *impor*
        // qualidade em vez de só reduzi-la quando a rede pede.
        let cfg = StreamConfig {
            video_max_width: 1600,
            max_width: 1600,
            video_fps: 60,
            video_bitrate: 4_000_000,
            ..config()
        };
        let p = cfg.video_params(topo());
        assert_eq!((p.width, p.fps, p.bitrate), (1600, 60, 4_000_000));
    }

    #[test]
    fn descer_um_degrau_respeita_os_tetos_configurados() {
        // Máquina fraca com teto de 800px: o degrau pede 1280 e não ganha -
        // o ajuste automático só abaixa.
        let cfg = StreamConfig {
            video_max_width: 800,
            video_fps: 24,
            ..config()
        };
        let p = cfg.video_params(crate::adaptive::LADDER[1]);
        assert_eq!(p.width, 800, "a rede não manda no teto do dono da máquina");
        assert_eq!(p.fps, 20, "aqui o degrau é mais restritivo, e vale");
    }

    #[test]
    fn trocar_de_monitor_muda_a_captura_pedida() {
        // A thread de captura é recriada quando esta função muda de resposta.
        // Se o monitor não entrasse na comparação, escolher outra tela no app
        // não teria efeito nenhum - e nada quebraria para avisar.
        let a = desired_capture(true, true, &config(), topo(), None);
        let b = desired_capture(true, true, &config(), topo(), Some(7));
        assert_ne!(a, b, "o monitor precisa fazer parte da captura pedida");
        assert_eq!(b.unwrap().monitor, Some(7));
        // O ritmo, esse, não muda: trocar de tela não é trocar de fps.
        assert_eq!(rhythm(a), rhythm(b));
    }

    #[test]
    fn fps_absurdo_nao_vira_intervalo_zero() {
        let cfg = StreamConfig {
            fps: 0,
            video_fps: 9999,
            ..config()
        };
        assert_eq!(desired_capture(true, false, &cfg, topo(), None), quer(1600, 1));
        assert_eq!(desired_capture(true, true, &cfg, topo(), None), quer(1280, 60));
        assert!(rhythm(desired_capture(true, true, &cfg, topo(), None)) > Duration::ZERO);
    }
}
