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

    /// Intervalo entre frames, com um teto de segurança de ~60 fps.
    fn frame_interval(&self) -> Duration {
        Self::interval_for(self.fps)
    }

    /// Intervalo do caminho de vídeo, que roda mais rápido que o do JPEG.
    fn video_interval(&self) -> Duration {
        Self::interval_for(self.video_fps)
    }

    fn interval_for(fps: u32) -> Duration {
        Duration::from_millis(1000 / fps.clamp(1, 60) as u64)
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

    // Transmissão de tela: enquanto ativa, captura e envia frames JPEG. A
    // config é mutável porque o app pode ajustar fps/qualidade por sessão.
    let mut streaming = false;
    let mut active = stream.clone();
    let mut frame_ticker = interval(active.frame_interval());
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
    // Se o ticker está no ritmo do vídeo ou no do JPEG, para saber quando trocar.
    let mut ticker_is_video = false;
    // Captura correndo à parte, para o laço só pagar a codificação.
    let mut pump: Option<crate::capture::FramePump> = None;
    // Contadores do resumo periódico: sem número, "está travado" não tem
    // como virar diagnóstico.
    let mut stats = VideoStats::default();

    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let hb = serde_json::to_string(&ClientMessage::Heartbeat)?;
                ws.send(Message::Text(hb)).await?;
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
            // no S2); senão, segue o JPEG, que continua sendo o fallback.
            _ = frame_ticker.tick(), if streaming || video.wants_video() => {
                // O vídeo roda mais rápido que o JPEG, então o ritmo do ticker
                // muda quando a sessão entra ou sai. Sem isto, o vídeo herdaria
                // os 10 fps do preset e pareceria travado por falta de quadros.
                let quer_video = video.wants_video();
                if quer_video != ticker_is_video {
                    ticker_is_video = quer_video;
                    let intervalo = if quer_video {
                        active.video_interval()
                    } else {
                        active.frame_interval()
                    };
                    frame_ticker = interval(intervalo);
                    frame_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
                    println!(
                        "Ritmo da tela: {} fps ({})",
                        1000 / intervalo.as_millis().max(1),
                        if quer_video { "vídeo" } else { "JPEG" },
                    );
                    // Sessão nova de vídeo: relógio, contagem e captura
                    // começam agora; ao sair, a thread de captura para.
                    if quer_video {
                        video_clock = None;
                        last_video_frame = None;
                        stats = VideoStats::default();
                        let largura = active.video_width();
                        if largura < active.max_width {
                            println!(
                                "Vídeo limitado a {largura}px de largura (o preset pede \
                                 {}px). Codificar custa por pixel; ajuste com \
                                 REMOTEONE_VIDEO_MAX_WIDTH.",
                                active.max_width,
                            );
                        }
                        match crate::capture::FramePump::start(largura, active.video_fps) {
                            Ok(started) => pump = Some(started),
                            Err(e) => {
                                eprintln!("Não consegui iniciar a captura: {e}");
                                pump = None;
                            }
                        }
                    } else {
                        pump = None; // Drop encerra a thread
                    }
                }
                if quer_video {
                    // Pega o quadro mais recente já capturado. Se ainda não há
                    // nenhum novo, não vale recodificar o mesmo: espera o
                    // próximo tique.
                    let Some(captured) = pump.as_ref().and_then(|p| p.take()) else {
                        stats.starved += 1;
                        continue;
                    };
                    let size = (captured.width, captured.height);
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
                            stats.report_if_due(capture_ms);
                        }
                        Ok(Err(e)) => eprintln!("Falha ao codificar a tela: {e}"),
                        Err(e) => eprintln!("Falha na tarefa de vídeo: {e}"),
                    }
                } else {
                    // Captura fora do event loop (spawn_blocking) para não travar
                    // o tratamento de comandos durante a codificação do frame.
                    let (max_width, quality) = (active.max_width, active.quality);
                    let previous = last_frame;
                    let captured = tokio::task::spawn_blocking(move || {
                        crate::capture::capture_frame_dedup(max_width, quality, previous)
                    })
                    .await;
                    match captured {
                        Ok(Ok(frame)) => {
                            last_frame = frame.hash;
                            // `jpeg` vazio = tela idêntica à anterior: nada a enviar.
                            if let Some(jpeg) = frame.jpeg {
                                ws.send(Message::Binary(jpeg)).await?;
                            }
                        }
                        Ok(Err(e)) => eprintln!("Falha ao capturar a tela: {e}"),
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
                            // A config de fps mudou: recria o ticker no ritmo novo.
                            Some(Action::RestartFrameTicker) => {
                                // Só reposiciona o ritmo se o JPEG é quem manda;
                                // com vídeo ativo, o ritmo é o do vídeo.
                                if !ticker_is_video {
                                    frame_ticker = interval(active.frame_interval());
                                    frame_ticker
                                        .set_missed_tick_behavior(MissedTickBehavior::Delay);
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
                            }
                            None => {}
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        println!("Conexão encerrada pelo servidor");
                        // Sem o backend não há como sinalizar: solta as sessões
                        // de vídeo em vez de deixá-las penduradas.
                        video.close_all().await;
                        return Ok(());
                    }
                    Some(Ok(_)) => {} // ping/pong/binário: ignorados por ora
                    Some(Err(e)) => {
                        video.close_all().await;
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

    fn report_if_due(&mut self, capture_ms: Option<f64>) {
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
            "Vídeo {}x{}: {:.1} fps · captura {captura}/quadro · codificação \
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

/// Algo que o laço principal precisa fazer depois de tratar uma mensagem —
/// tarefas que exigem `await` (recriar o ticker, responder ao servidor).
enum Action {
    /// O fps mudou: recriar o `frame_ticker`.
    RestartFrameTicker,
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
        Ok(ServerMessage::Welcome { server_version }) => {
            println!("Registrado no backend (servidor v{server_version})");
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
            let old_fps = active.fps;
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
            if active.fps != old_fps {
                return Some(Action::RestartFrameTicker);
            }
        }
        Ok(ServerMessage::StopStream) => {
            *streaming = false;
            // O backend descarta o frame guardado ao parar: zera o hash para o
            // próximo start não concluir que "a tela não mudou".
            *last_frame = crate::capture::NO_FRAME;
            println!("Transmissão de tela encerrada");
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
}
