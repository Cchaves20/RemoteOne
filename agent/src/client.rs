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

/// Parâmetros da transmissão de tela.
const FRAME_INTERVAL_MS: u64 = 100; // ~10 fps
const STREAM_MAX_WIDTH: u32 = 1280;
const STREAM_QUALITY: u8 = 55;

/// Dados de identificação do agente, resolvidos uma vez na inicialização.
#[derive(Debug, Clone)]
pub struct AgentIdentity {
    pub device_id: String,
    pub hostname: String,
    pub os: String,
    pub agent_version: String,
}

impl AgentIdentity {
    /// Constrói a mensagem `hello` a partir da identidade.
    pub fn hello(&self) -> ClientMessage {
        ClientMessage::Hello {
            device_id: self.device_id.clone(),
            hostname: self.hostname.clone(),
            os: self.os.clone(),
            agent_version: self.agent_version.clone(),
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

    // Transmissão de tela: enquanto ativa, captura e envia frames JPEG.
    let mut streaming = false;
    let mut frame_ticker = interval(Duration::from_millis(FRAME_INTERVAL_MS));
    frame_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let hb = serde_json::to_string(&ClientMessage::Heartbeat)?;
                ws.send(Message::Text(hb)).await?;
            }
            _ = frame_ticker.tick(), if streaming => {
                // Captura fora do event loop (spawn_blocking) para não travar
                // o tratamento de comandos durante a codificação do frame.
                let captured = tokio::task::spawn_blocking(|| {
                    crate::capture::capture_frame(STREAM_MAX_WIDTH, STREAM_QUALITY)
                })
                .await;
                match captured {
                    Ok(Ok(jpeg)) => ws.send(Message::Binary(jpeg)).await?,
                    Ok(Err(e)) => eprintln!("Falha ao capturar a tela: {e}"),
                    Err(e) => eprintln!("Falha na tarefa de captura: {e}"),
                }
            }
            incoming = ws.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        handle_server_text(&text, injector.as_mut(), &mut streaming);
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

fn handle_server_text(
    text: &str,
    injector: &mut dyn crate::injector::InputInjector,
    streaming: &mut bool,
) {
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
        }
        Ok(ServerMessage::Paired { user_email }) => {
            println!("✓ Dispositivo pareado com a conta {user_email}");
        }
        Ok(ServerMessage::Input { action }) => {
            if let Err(e) = injector.apply(&action) {
                eprintln!("Falha ao aplicar entrada: {e}");
            }
        }
        Ok(ServerMessage::StartStream { max_fps }) => {
            *streaming = true;
            println!("Transmissão de tela iniciada (~{max_fps} fps)");
        }
        Ok(ServerMessage::StopStream) => {
            *streaming = false;
            println!("Transmissão de tela encerrada");
        }
        Err(e) => eprintln!("Mensagem desconhecida do servidor: {text} ({e})"),
    }
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
        };
        assert_eq!(
            identity.hello(),
            ClientMessage::Hello {
                device_id: "dev-1".into(),
                hostname: "dell-g5".into(),
                os: "linux".into(),
                agent_version: "0.1.0".into(),
            }
        );
    }
}
