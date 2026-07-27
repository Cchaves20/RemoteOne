//! Cliente WebSocket que conecta o agente ao backend.
//!
//! Fluxo: conecta, envia `hello`, aguarda `welcome` e então entra em um laço
//! que envia `heartbeat` periodicamente enquanto trata as respostas do
//! servidor. A construção das mensagens (parte pura) é testável; o laço de
//! conexão em si é exercitado manualmente e pela validação ponta a ponta.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::time::{interval, MissedTickBehavior};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::protocol::{ClientMessage, ServerMessage};

/// Parâmetros da transmissão de tela (ajustáveis por variável de ambiente).
#[derive(Debug, Clone, Copy)]
pub struct StreamConfig {
    pub fps: u32,
    pub max_width: u32,
    pub quality: u8,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            fps: 60,
            max_width: 1280,
            quality: 50,
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
    let mut active = stream;
    let mut frame_ticker = interval(active.frame_interval());
    frame_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    // Hash do último frame enviado: se a tela não mudou, não vale codificar
    // nem transmitir de novo (o app já mostra a mesma imagem).
    let mut last_frame = crate::capture::NO_FRAME;

    // Sessões de WebRTC em negociação. Na Fase 1 só acompanham o estado; a
    // negociação de verdade entra na Fase 2 (docs/webrtc-plano.md).
    let mut sessions = crate::webrtc::Sessions::new();

    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let hb = serde_json::to_string(&ClientMessage::Heartbeat)?;
                ws.send(Message::Text(hb)).await?;
            }
            _ = frame_ticker.tick(), if streaming => {
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
            incoming = ws.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        match handle_server_text(
                            &text, injector.as_mut(), &mut streaming, &mut active,
                            &mut last_frame, &mut sessions,
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
                            None => {}
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        println!("Conexão encerrada pelo servidor");
                        return Ok(());
                    }
                    Some(Ok(_)) => {} // ping/pong/binário: ignorados por ora
                    Some(Err(e)) => return Err(Box::new(e)),
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
}

/// Trata uma mensagem de texto do servidor. O que exige `await` volta como
/// [`Action`] para o laço principal executar.
fn handle_server_text(
    text: &str,
    injector: &mut dyn crate::injector::InputInjector,
    streaming: &mut bool,
    active: &mut StreamConfig,
    last_frame: &mut u64,
    sessions: &mut crate::webrtc::Sessions,
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
        // Sinalização de WebRTC. A Fase 1 do plano só encaminha e acompanha; a
        // negociação (responder com SDP e transmitir vídeo) é a Fase 2, então
        // aqui não se inventa resposta nenhuma — o app cai no caminho JPEG.
        Ok(ServerMessage::WebrtcOffer { session_id, sdp }) => {
            let nova = sessions.offer(&session_id);
            println!(
                "Oferta de WebRTC recebida (sessão {session_id}, {} bytes de SDP, {}). \
                 A negociação entra na Fase 2 — seguindo com a tela por JPEG.",
                sdp.len(),
                if nova {
                    "sessão nova"
                } else {
                    "renegociação"
                },
            );
        }
        Ok(ServerMessage::WebrtcIce {
            session_id,
            candidate,
            ..
        }) => {
            if !sessions.candidate(&session_id, &candidate) {
                // Candidato atrasado de uma sessão já encerrada: ignorar é o
                // comportamento certo, não é falha.
                println!("Candidato ICE de sessão desconhecida ({session_id}): ignorado");
            }
        }
        Ok(ServerMessage::WebrtcClose { session_id }) => {
            if sessions.close(&session_id) {
                println!("Sessão de WebRTC encerrada ({session_id})");
            }
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
