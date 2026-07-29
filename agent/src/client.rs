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

    fn interval_for(fps: u32) -> Duration {
        Duration::from_millis(1000 / fps.clamp(1, 60) as u64)
    }
}

/// Ritmo do ticker quando ninguém está olhando a tela.
///
/// Lento de propósito: só serve para perceber que alguém voltou a pedir. Sem
/// isto o laço acordaria 60 vezes por segundo com o computador ocioso.
const IDLE_INTERVAL: Duration = Duration::from_millis(500);

/// O que a captura precisa entregar agora — `(largura, fps)` — ou `None` se
/// ninguém está pedindo a tela.
///
/// Existe para que a thread de captura seja função do estado, e não de eventos:
/// ela nasce, troca de tamanho e morre porque esta função mudou de resposta. Era
/// por depender de eventos que a captura vazava quando o vídeo e o JPEG paravam
/// juntos — não havia transição para observar.
fn desired_capture(streaming: bool, video: bool, cfg: &StreamConfig) -> Option<(u32, u32)> {
    if video {
        Some((cfg.video_width(), cfg.video_fps.clamp(1, 60)))
    } else if streaming {
        Some((cfg.max_width, cfg.fps.clamp(1, 60)))
    } else {
        None
    }
}

/// Intervalo do ticker de quadros para uma captura desejada.
fn rhythm(capture: Option<(u32, u32)>) -> Duration {
    match capture {
        Some((_, fps)) => StreamConfig::interval_for(fps),
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
) -> Result<(), Box<dyn std::error::Error>> {
    let video_bitrate = stream.video_bitrate;
    let (mut ws, _response) = connect_async(url).await?;
    println!("Conectado ao backend em {url}");

    // Envia o hello e aguarda o welcome.
    let hello = serde_json::to_string(&identity.hello())?;
    ws.send(Message::Text(hello)).await?;

    let mut ticker = interval(heartbeat);
    ticker.tick().await; // consome o primeiro tick imediato

    // Injetor de entrada da plataforma (real no Windows, stub no restante).
    let mut injector = crate::injector::controller();

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
    let mut video = crate::webrtc::Video::new(signal_tx, input_tx, stream.ice_servers.clone())
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
    let mut pump_config: Option<(u32, u32)> = None;
    // Contadores do resumo periódico: sem número, "está travado" não tem
    // como virar diagnóstico.
    let mut stats = VideoStats::default();

    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let hb = serde_json::to_string(&ClientMessage::Heartbeat)?;
                ws.send(Message::Text(hb)).await?;
            }
            // Quadros de som prontos, vindos da thread da placa. Escrever na
            // faixa é rápido (empacota e enfileira no transporte), então não
            // atrapalha o resto do laço.
            Some(pacote) = audio_rx.recv() => {
                audio_stats.count(pacote.data.len());
                video.write_audio(&pacote.data, pacote.duration).await;
                // Um número no console é a diferença entre "não ouvi nada" e
                // saber de qual lado o som parou.
                if let Some(linha) = audio_stats.report_if_due(video.wants_audio()) {
                    println!("{linha}");
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
            _ = frame_ticker.tick() => {
                let quer_video = video.wants_video();
                let desejada = desired_capture(streaming, quer_video, &active);

                // O vídeo roda mais rápido que o JPEG e a ociosidade mais lenta
                // que os dois. Sem acertar o ritmo, o vídeo herdaria os 10 fps
                // do preset e pareceria travado por falta de quadros.
                let ritmo = rhythm(desejada);
                if ritmo != ticker_interval {
                    ticker_interval = ritmo;
                    frame_ticker = interval(ritmo);
                    frame_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
                    match desejada {
                        Some((_, fps)) => println!(
                            "Ritmo da tela: {fps} fps ({})",
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
                        let largura = active.video_width();
                        if largura < active.max_width {
                            println!(
                                "Vídeo limitado a {largura}px de largura (o preset pede \
                                 {}px). Codificar custa por pixel; ajuste com \
                                 REMOTEONE_VIDEO_MAX_WIDTH.",
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
                    if let Some((largura, fps)) = desejada {
                        match crate::capture::FramePump::start(largura, fps) {
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
                    let fps = active.video_fps.clamp(1, 60);
                    let shared = Arc::clone(&encoder);
                    let encode_started = std::time::Instant::now();
                    let encoded = tokio::task::spawn_blocking(move || {
                        let (w, h) = (captured.width, captured.height);
                        let mut slot = shared.lock().unwrap_or_else(|e| e.into_inner());
                        // Resolução nova (trocou de monitor, mudou a tela):
                        // recria o codificador em vez de remendar o atual.
                        if !slot.as_ref().is_some_and(|enc| enc.fits(w, h)) {
                            *slot = Some(crate::h264::Encoder::new(w, h, fps, video_bitrate)?);
                        }
                        slot.as_mut()
                            .expect("acabou de ser criado")
                            .encode(&captured.rgb, w, h, elapsed)
                    })
                    .await;
                    match encoded {
                        Ok(Ok(frame)) => {
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
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        match handle_server_text(
                            &text, injector.as_mut(), &mut streaming, &mut active,
                            &mut last_frame,
                        ) {
                            // A transmissão começou, parou ou trocou de fps. O
                            // próximo tique já reavaliaria tudo, mas do ritmo
                            // ocioso isso levaria meio segundo: acerta agora.
                            Some(Action::RestartFrameTicker) => {
                                let ritmo = rhythm(desired_capture(
                                    streaming, video.wants_video(), &active,
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
                            Some(Action::SystemInfo { request_id }) => {
                                let stats = monitor.snapshot();
                                let reply = serde_json::to_string(
                                    &ClientMessage::SystemStats { request_id, stats },
                                )?;
                                ws.send(Message::Text(reply)).await?;
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
        let linha = format!(
            "Áudio: {} quadros em {segundos:.0}s ({kbps:.0} kbps), faixa {}",
            self.packets,
            if ouvindo { "conectada" } else { "SEM ninguém ouvindo" }
        );
        self.packets = 0;
        self.bytes = 0;
        self.since = std::time::Instant::now();
        Some(linha)
    }
}

/// Algo que o laço principal precisa fazer depois de tratar uma mensagem —
/// tarefas que exigem `await` (recriar o ticker, responder ao servidor).
enum Action {
    /// A transmissão ou o fps mudaram: reavaliar o ritmo do `frame_ticker`.
    RestartFrameTicker,
    /// Medir CPU/memória/disco e responder ao backend.
    SystemInfo { request_id: String },
    /// Descobrir o programa em primeiro plano e responder ao backend.
    ForegroundInfo { request_id: String },
    /// Ligar ou desligar a captura do som do computador, com o ganho.
    SetAudio { enabled: bool, gain: f32 },
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
        Ok(ServerMessage::SystemInfo { request_id }) => {
            return Some(Action::SystemInfo { request_id });
        }
        // Idem: o acompanhante do primeiro plano guarda memória entre uma
        // pergunta e outra, e essa memória vive no laço.
        Ok(ServerMessage::ForegroundInfo { request_id }) => {
            return Some(Action::ForegroundInfo { request_id });
        }
        // Ligar a placa de som é `await` e estado: volta como ação.
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
        assert_eq!(desired_capture(false, false, &config()), None);
        assert_eq!(rhythm(None), IDLE_INTERVAL);
    }

    #[test]
    fn jpeg_usa_a_largura_e_o_fps_do_preset() {
        assert_eq!(desired_capture(true, false, &config()), Some((1600, 10)));
        assert_eq!(
            rhythm(desired_capture(true, false, &config())),
            Duration::from_millis(100)
        );
    }

    #[test]
    fn video_tem_teto_proprio_e_manda_no_ritmo() {
        // 1280 e não 1600: codificar custa por pixel (ver `video_max_width`).
        assert_eq!(desired_capture(true, true, &config()), Some((1280, 30)));
        assert_eq!(
            rhythm(desired_capture(true, true, &config())),
            Duration::from_millis(33)
        );
    }

    #[test]
    fn video_dispensa_a_transmissao_jpeg() {
        // O app pode ter vídeo sem nunca pedir `start_stream`.
        assert_eq!(desired_capture(false, true, &config()), Some((1280, 30)));
    }

    #[test]
    fn fps_absurdo_nao_vira_intervalo_zero() {
        let cfg = StreamConfig {
            fps: 0,
            video_fps: 9999,
            ..config()
        };
        assert_eq!(desired_capture(true, false, &cfg), Some((1600, 1)));
        assert_eq!(desired_capture(true, true, &cfg), Some((1280, 60)));
        assert!(rhythm(desired_capture(true, true, &cfg)) > Duration::ZERO);
    }
}
