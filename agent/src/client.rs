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
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            fps: 60,
            max_width: 1280,
            quality: 50,
            video_bitrate: 1_500_000,
            ice_servers: vec!["stun:stun.l.google.com:19302".to_string()],
        }
    }
}

impl StreamConfig {
    /// Intervalo entre frames, com um teto de segurança de ~60 fps.
    fn frame_interval(&self) -> Duration {
        let fps = self.fps.clamp(1, 60);
        Duration::from_millis(1000 / fps as u64)
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
    let mut video = crate::webrtc::Video::new(signal_tx, stream.ice_servers.clone())
        .map_err(|e| format!("não consegui iniciar o vídeo por WebRTC: {e}"))?;

    // Codificador H.264, compartilhado com a thread de codificação. Precisa
    // viver entre quadros: é guardar o anterior que permite mandar só a
    // diferença. `None` até o primeiro quadro definir a resolução.
    let encoder: Arc<Mutex<Option<crate::h264::Encoder>>> = Arc::new(Mutex::new(None));

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
            // Um tique de quadro serve os dois caminhos. Quando há sessão de
            // WebRTC conectada, o vídeo vai por lá (banda ~100x menor, medida
            // no S2); senão, segue o JPEG, que continua sendo o fallback.
            _ = frame_ticker.tick(), if streaming || video.wants_video() => {
                if video.wants_video() {
                    let (max_width, fps) = (active.max_width, active.fps.clamp(1, 60));
                    let shared = Arc::clone(&encoder);
                    // Captura e codificação na mesma tarefa bloqueante: separá-las
                    // custaria uma cópia do quadro e outra ida ao pool de threads.
                    let encoded = tokio::task::spawn_blocking(move || {
                        let (rgb, w, h) = crate::capture::capture_rgb(max_width)?;
                        let mut slot = shared.lock().unwrap_or_else(|e| e.into_inner());
                        // Resolução nova (trocou de monitor, mudou a tela):
                        // recria o codificador em vez de remendar o atual.
                        if !slot.as_ref().is_some_and(|enc| enc.fits(w, h)) {
                            *slot = Some(crate::h264::Encoder::new(w, h, fps, video_bitrate)?);
                        }
                        slot.as_mut().expect("acabou de ser criado").encode(&rgb, w, h)
                    })
                    .await;
                    match encoded {
                        Ok(Ok(frame)) => {
                            video.write(&frame, Duration::from_micros(
                                1_000_000 / active.fps.clamp(1, 60) as u64,
                            )).await;
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
                                frame_ticker = interval(active.frame_interval());
                                frame_ticker
                                    .set_missed_tick_behavior(MissedTickBehavior::Delay);
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
                                    println!(
                                        "Vídeo por WebRTC negociado (sessão {session_id})"
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
