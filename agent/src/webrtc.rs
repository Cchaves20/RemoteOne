//! Transmissão de vídeo por WebRTC (Fase 2 do `docs/webrtc-plano.md`).
//!
//! Na Fase 1 este módulo só acompanhava as sessões pelos logs. Agora ele mantém
//! as conexões de verdade: recebe a oferta de um app, responde, troca candidatos
//! ICE e escreve os quadros H.264 na faixa de vídeo.
//!
//! Duas coisas moldam o desenho:
//!
//! - **Um agente atende vários apps.** O `session_id` vem do backend justamente
//!   para isso, então tudo aqui é indexado por sessão. O quadro é codificado
//!   **uma vez** e a mesma amostra vai para todas as faixas: o custo de CPU não
//!   cresce com o número de espectadores, só o de rede.
//! - **As respostas não podem ser enviadas daqui.** Quem tem o WebSocket é o
//!   laço principal do cliente. Então o que precisa voltar ao backend sai por um
//!   canal (`Signal`), e o laço encaminha. É isso que permite ao `webrtc-rs`
//!   chamar de volta de dentro das tarefas dele sem precisar do WebSocket.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc::UnboundedSender;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264, MIME_TYPE_OPUS};
use webrtc::api::{APIBuilder, API};
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;

use crate::datachannel::InputEnvelope;
use crate::h264::EncodedFrame;

/// O que precisa voltar ao backend. O laço do cliente converte em
/// [`crate::protocol::ClientMessage`] e envia pelo WebSocket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Signal {
    Answer {
        session_id: String,
        sdp: String,
    },
    Ice {
        session_id: String,
        candidate: String,
        sdp_mid: Option<String>,
        sdp_mline_index: Option<u32>,
    },
}

/// Nome do canal de dados de entrada. Tem que casar com o que o app cria.
pub const INPUT_CHANNEL: &str = "input";

/// Uma sessão: a conexão com um app e as faixas por onde a tela e o som saem.
struct Peer {
    connection: Arc<RTCPeerConnection>,
    track: Arc<TrackLocalStaticSample>,
    /// Faixa de som. Só existe quando o app pediu áudio na oferta - um app de
    /// versão antiga não tem linha `m=audio` no SDP, e uma faixa sem lugar na
    /// oferta não teria como entrar na resposta.
    audio: Option<Arc<TrackLocalStaticSample>>,
}

/// As sessões de WebRTC deste agente.
pub struct Video {
    api: API,
    ice_servers: Vec<String>,
    peers: HashMap<String, Peer>,
    outbox: UnboundedSender<Signal>,
    /// Entrada recebida pelo canal de dados. Sai por aqui porque o injetor de
    /// teclado/mouse vive no laço principal, e o webrtc-rs chama de volta de
    /// dentro das tarefas dele — mesmo desenho da sinalização.
    input: UnboundedSender<InputEnvelope>,
}

impl Video {
    /// Monta o motor de mídia. `ice_servers` são URLs de STUN (ex.:
    /// `stun:stun.l.google.com:19302`); vazio significa só rede local.
    pub fn new(
        outbox: UnboundedSender<Signal>,
        input: UnboundedSender<InputEnvelope>,
        ice_servers: Vec<String>,
    ) -> Result<Self, String> {
        let mut media = MediaEngine::default();
        media
            .register_default_codecs()
            .map_err(|e| format!("codecs: {e}"))?;
        let registry = register_default_interceptors(Default::default(), &mut media)
            .map_err(|e| format!("interceptors: {e}"))?;
        let api = APIBuilder::new()
            .with_media_engine(media)
            .with_interceptor_registry(registry)
            .build();
        Ok(Self {
            api,
            ice_servers,
            peers: HashMap::new(),
            outbox,
            input,
        })
    }

    fn configuration(&self) -> RTCConfiguration {
        RTCConfiguration {
            ice_servers: vec![RTCIceServer {
                urls: self.ice_servers.clone(),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    /// Atende a oferta de um app: cria a conexão, adiciona a faixa de vídeo e
    /// devolve a resposta pelo canal de sinalização.
    ///
    /// Uma oferta na mesma sessão é renegociação: a conexão antiga é descartada
    /// e uma nova entra no lugar, o que é mais simples e mais previsível do que
    /// tentar reaproveitar uma conexão em estado desconhecido.
    pub async fn offer(&mut self, session_id: &str, sdp: &str) -> Result<(), String> {
        self.close(session_id).await;

        let connection = Arc::new(
            self.api
                .new_peer_connection(self.configuration())
                .await
                .map_err(|e| format!("não consegui criar a conexão: {e}"))?,
        );

        let track = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: MIME_TYPE_H264.to_owned(),
                ..Default::default()
            },
            "tela".to_owned(),
            "remoteone".to_owned(),
        ));
        connection
            .add_track(Arc::clone(&track) as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .map_err(|e| format!("não consegui adicionar a faixa de vídeo: {e}"))?;

        // Faixa de som, quando o app a pediu. O Opus é obrigatório em WebRTC,
        // então o celular toca isto sem precisar de nada a mais; `stereo=1` é
        // o que faz música chegar em dois canais em vez de virar voz mono.
        let audio = if sdp.contains("m=audio") {
            let faixa = Arc::new(TrackLocalStaticSample::new(
                RTCRtpCodecCapability {
                    mime_type: MIME_TYPE_OPUS.to_owned(),
                    clock_rate: 48_000,
                    channels: 2,
                    sdp_fmtp_line: "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1"
                        .to_owned(),
                    ..Default::default()
                },
                "som".to_owned(),
                "remoteone".to_owned(),
            ));
            // Sem `?`: **o som não pode derrubar a tela**. Ver o computador é
            // a função do app; ouvi-lo é um extra. Um erro aqui abortava a
            // negociação inteira, e o resultado no aparelho era o vídeo
            // sumindo e a tela voltando para o JPEG - um problema muito maior
            // do que ficar sem som.
            match connection
                .add_track(Arc::clone(&faixa) as Arc<dyn TrackLocal + Send + Sync>)
                .await
            {
                Ok(_) => {
                    println!("WebRTC ({session_id}): sessão com faixa de som");
                    Some(faixa)
                }
                Err(e) => {
                    eprintln!("WebRTC ({session_id}): sessão sem som ({e})");
                    None
                }
            }
        } else {
            // App antigo (sem transceptor de áudio na oferta). Vale dizer: é a
            // explicação de "liguei o som e não ouvi nada".
            println!(
                "WebRTC ({session_id}): oferta sem faixa de som - o app pode \
                 estar desatualizado"
            );
            None
        };

        // Os candidatos locais aparecem aos poucos, de dentro do webrtc-rs:
        // saem pelo canal para o laço principal despachar.
        let outbox = self.outbox.clone();
        let session = session_id.to_string();
        connection.on_ice_candidate(Box::new(move |candidate| {
            let outbox = outbox.clone();
            let session = session.clone();
            Box::pin(async move {
                // `None` é o fim dos candidatos; vira candidato vazio no fio,
                // que é o que a outra ponta espera para parar de aguardar.
                let signal = match candidate.and_then(|c| c.to_json().ok()) {
                    Some(init) => Signal::Ice {
                        session_id: session,
                        candidate: init.candidate,
                        sdp_mid: init.sdp_mid,
                        sdp_mline_index: init.sdp_mline_index.map(u32::from),
                    },
                    None => Signal::Ice {
                        session_id: session,
                        candidate: String::new(),
                        sdp_mid: None,
                        sdp_mline_index: None,
                    },
                };
                let _ = outbox.send(signal);
            })
        }));

        // O canal de dados é criado pelo **app** (que faz a oferta), então aqui
        // só se recebe. Fosse o contrário, precisaria renegociar a sessão.
        let input = self.input.clone();
        let session = session_id.to_string();
        connection.on_data_channel(Box::new(move |channel| {
            let input = input.clone();
            let session = session.clone();
            let label = channel.label().to_string();
            Box::pin(async move {
                if label != INPUT_CHANNEL {
                    println!("Canal de dados desconhecido ignorado: {label}");
                    return;
                }
                println!("Canal de entrada aberto (sessão {session})");
                channel.on_message(Box::new(move |message| {
                    let input = input.clone();
                    Box::pin(async move {
                        match serde_json::from_slice::<InputEnvelope>(&message.data) {
                            Ok(envelope) => {
                                let _ = input.send(envelope);
                            }
                            Err(e) => eprintln!("Entrada inválida no canal: {e}"),
                        }
                    })
                }));
            })
        }));

        let session = session_id.to_string();
        connection.on_peer_connection_state_change(Box::new(move |state| {
            println!("WebRTC ({session}): {state}");
            Box::pin(async {})
        }));

        let remote = RTCSessionDescription::offer(sdp.to_string())
            .map_err(|e| format!("oferta inválida: {e}"))?;
        connection
            .set_remote_description(remote)
            .await
            .map_err(|e| format!("não consegui aplicar a oferta: {e}"))?;
        let answer = connection
            .create_answer(None)
            .await
            .map_err(|e| format!("não consegui criar a resposta: {e}"))?;

        // A resposta vai para a fila **antes** de aplicar a descrição local, e a
        // ordem importa: aplicar a descrição é o que dispara os candidatos ICE.
        // Se a resposta saísse depois, candidatos poderiam chegar ao app antes
        // dela — e `addCandidate` sem descrição remota falha. O app também
        // enfileira por conta própria, mas não custa nada garantir dos dois
        // lados, e aqui a garantia é absoluta.
        self.outbox
            .send(Signal::Answer {
                session_id: session_id.to_string(),
                sdp: answer.sdp.clone(),
            })
            .map_err(|_| "canal de sinalização fechado".to_string())?;

        connection
            .set_local_description(answer)
            .await
            .map_err(|e| format!("não consegui aplicar a resposta: {e}"))?;

        self.peers.insert(
            session_id.to_string(),
            Peer {
                connection,
                track,
                audio,
            },
        );
        Ok(())
    }

    /// Adiciona um candidato ICE do app.
    ///
    /// Devolve `false` se a sessão é desconhecida — candidato atrasado de sessão
    /// já encerrada, que é para ser ignorado e não tratado como falha.
    pub async fn candidate(
        &mut self,
        session_id: &str,
        candidate: &str,
        sdp_mid: Option<String>,
        sdp_mline_index: Option<u32>,
    ) -> bool {
        let Some(peer) = self.peers.get(session_id) else {
            return false;
        };
        // Candidato vazio é o "acabaram os meus": nada a adicionar.
        if candidate.is_empty() {
            return true;
        }
        let init = RTCIceCandidateInit {
            candidate: candidate.to_string(),
            sdp_mid,
            sdp_mline_index: sdp_mline_index.map(|i| i as u16),
            ..Default::default()
        };
        if let Err(e) = peer.connection.add_ice_candidate(init).await {
            eprintln!("candidato ICE recusado ({session_id}): {e}");
        }
        true
    }

    /// Encerra uma sessão. Devolve `true` se havia o que encerrar.
    pub async fn close(&mut self, session_id: &str) -> bool {
        match self.peers.remove(session_id) {
            None => false,
            Some(peer) => {
                if let Err(e) = peer.connection.close().await {
                    eprintln!("falha ao fechar a conexão ({session_id}): {e}");
                }
                true
            }
        }
    }

    /// Se há alguma sessão **conectada** — isto é, se vale capturar e codificar.
    ///
    /// Sessão em negociação não conta: gastar CPU codificando para uma conexão
    /// que ainda não fechou (ou que falhou) seria desperdício.
    pub fn wants_video(&self) -> bool {
        self.peers
            .values()
            .any(|p| p.connection.connection_state() == RTCPeerConnectionState::Connected)
    }

    /// Quantas sessões existem, conectadas ou não.
    pub fn len(&self) -> usize {
        self.peers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.peers.is_empty()
    }

    /// Escreve o quadro codificado em todas as faixas conectadas.
    ///
    /// Uma faixa que falhe não interrompe as outras: um app com problema não
    /// pode derrubar a transmissão dos demais.
    pub async fn write(&self, frame: &EncodedFrame, duration: Duration) {
        let sample = webrtc::media::Sample {
            data: frame.data.clone().into(),
            duration,
            ..Default::default()
        };
        for (session_id, peer) in &self.peers {
            if peer.connection.connection_state() != RTCPeerConnectionState::Connected {
                continue;
            }
            if let Err(e) = peer.track.write_sample(&sample).await {
                eprintln!("falha ao enviar quadro ({session_id}): {e}");
            }
        }
    }

    /// Se alguma sessão conectada tem faixa de som - isto é, se vale capturar.
    pub fn wants_audio(&self) -> bool {
        self.peers.values().any(|p| {
            p.audio.is_some()
                && p.connection.connection_state() == RTCPeerConnectionState::Connected
        })
    }

    /// Escreve um quadro de som em todas as faixas conectadas que o aceitem.
    pub async fn write_audio(&self, data: &[u8], duration: Duration) {
        let sample = webrtc::media::Sample {
            data: data.to_vec().into(),
            duration,
            ..Default::default()
        };
        for (session_id, peer) in &self.peers {
            if peer.connection.connection_state() != RTCPeerConnectionState::Connected {
                continue;
            }
            let Some(faixa) = &peer.audio else { continue };
            if let Err(e) = faixa.write_sample(&sample).await {
                eprintln!("falha ao enviar som ({session_id}): {e}");
            }
        }
    }

    /// Fecha todas as sessões (usado quando a conexão com o backend cai).
    pub async fn close_all(&mut self) {
        let sessions: Vec<String> = self.peers.keys().cloned().collect();
        for session_id in sessions {
            self.close(&session_id).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;
    use webrtc::rtp_transceiver::rtp_codec::RTPCodecType;

    /// Monta o "app": uma conexão que só quer receber vídeo, como o Flutter faz.
    async fn app_peer() -> Arc<RTCPeerConnection> {
        let mut media = MediaEngine::default();
        media.register_default_codecs().unwrap();
        let registry = register_default_interceptors(Default::default(), &mut media).unwrap();
        let api = APIBuilder::new()
            .with_media_engine(media)
            .with_interceptor_registry(registry)
            .build();
        let peer = Arc::new(
            api.new_peer_connection(RTCConfiguration::default())
                .await
                .unwrap(),
        );
        peer.add_transceiver_from_kind(RTPCodecType::Video, None)
            .await
            .unwrap();
        peer
    }

    /// O mesmo "app", agora pedindo **som** além da tela - que é o que o
    /// Flutter passou a oferecer. Existe separado porque foi exatamente esta
    /// diferença que quebrou o vídeo uma vez: a faixa de som entrou na oferta,
    /// algo falhou do lado do agente e a negociação inteira morreu junto.
    async fn app_peer_com_som() -> Arc<RTCPeerConnection> {
        let peer = app_peer().await;
        peer.add_transceiver_from_kind(RTPCodecType::Audio, None)
            .await
            .unwrap();
        peer
    }

    fn video() -> (Video, mpsc::UnboundedReceiver<Signal>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let (input_tx, _input_rx) = mpsc::unbounded_channel();
        // O receptor de entrada é descartado de propósito: estes testes cuidam
        // da negociação e do vídeo. O envio pelo canal é coberto no `datachannel`.
        std::mem::forget(_input_rx);
        (Video::new(tx, input_tx, vec![]).unwrap(), rx)
    }

    #[tokio::test]
    async fn responde_a_oferta_com_uma_resposta_sdp() {
        let (mut agent, mut signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        app.set_local_description(offer.clone()).await.unwrap();

        agent.offer("s1", &offer.sdp).await.unwrap();

        // A primeira coisa no canal tem que ser a resposta, com a sessão certa.
        let signal = signals.recv().await.unwrap();
        match signal {
            Signal::Answer { session_id, sdp } => {
                assert_eq!(session_id, "s1");
                assert!(sdp.starts_with("v=0"), "SDP inesperado: {sdp}");
                // A resposta precisa oferecer H.264, senão o iPhone não
                // decodifica por hardware (é o motivo da escolha do codec).
                assert!(
                    sdp.to_lowercase().contains("h264"),
                    "a resposta não anuncia H.264"
                );
            }
            outro => panic!("esperava a resposta primeiro, veio {outro:?}"),
        }
        assert_eq!(agent.len(), 1);
        agent.close_all().await;
    }

    /// Oferta com som: a resposta precisa trazer as duas faixas **e** ser
    /// aceita pelo app. Aplicar a resposta do outro lado é a prova real - uma
    /// resposta malformada passa por `starts_with("v=0")` e falha aqui.
    #[tokio::test]
    async fn oferta_com_som_responde_com_tela_e_som() {
        let (mut agent, mut signals) = video();
        let app = app_peer_com_som().await;
        let offer = app.create_offer(None).await.unwrap();
        app.set_local_description(offer.clone()).await.unwrap();
        assert!(offer.sdp.contains("m=audio"), "a oferta devia pedir som");

        agent.offer("s1", &offer.sdp).await.unwrap();

        let Some(Signal::Answer { sdp, .. }) = signals.recv().await else {
            panic!("esperava a resposta");
        };
        let minusculo = sdp.to_lowercase();
        assert!(minusculo.contains("m=video"), "a resposta perdeu a tela");
        assert!(minusculo.contains("h264"), "a resposta perdeu o H.264");
        assert!(minusculo.contains("m=audio"), "a resposta perdeu o som");
        assert!(minusculo.contains("opus"), "a resposta não anuncia Opus");

        // O app aplica a resposta. É aqui que uma resposta inconsistente
        // (faixa a mais, faixa fora de ordem, codec que não casa) aparece.
        let resposta = RTCSessionDescription::answer(sdp).unwrap();
        app.set_remote_description(resposta)
            .await
            .expect("o app precisa aceitar a resposta");

        agent.close_all().await;
        app.close().await.unwrap();
    }

    /// App sem som (versão antiga): a sessão continua valendo, só que sem
    /// faixa de áudio. Ninguém pode ficar sem tela por não ter pedido som.
    #[tokio::test]
    async fn oferta_sem_som_continua_valendo() {
        let (mut agent, mut signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        app.set_local_description(offer.clone()).await.unwrap();
        assert!(!offer.sdp.contains("m=audio"));

        agent.offer("s1", &offer.sdp).await.unwrap();

        let Some(Signal::Answer { sdp, .. }) = signals.recv().await else {
            panic!("esperava a resposta");
        };
        assert!(sdp.to_lowercase().contains("m=video"));
        let resposta = RTCSessionDescription::answer(sdp).unwrap();
        app.set_remote_description(resposta).await.unwrap();
        assert!(!agent.wants_audio(), "não há faixa de som para escrever");

        agent.close_all().await;
        app.close().await.unwrap();
    }

    #[tokio::test]
    async fn oferta_invalida_nao_deixa_sessao_pendurada() {
        let (mut agent, _signals) = video();
        assert!(agent.offer("s1", "isto não é um SDP").await.is_err());
        assert!(
            agent.is_empty(),
            "sessão inválida não deve ficar registrada"
        );
    }

    /// A resposta tem que sair **antes** de qualquer candidato.
    ///
    /// Não é preciosismo: no app, `addCandidate` antes de `setRemoteDescription`
    /// falha, e um candidato perdido é exatamente o tipo de coisa que faz a
    /// conexão nunca fechar sem dar erro em lugar nenhum.
    #[tokio::test]
    async fn a_resposta_sai_antes_dos_candidatos() {
        let (mut agent, mut signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();

        // Deixa os candidatos serem gerados antes de olhar a fila, para o teste
        // não passar só por chegar primeiro na corrida.
        tokio::time::sleep(Duration::from_millis(500)).await;

        let mut recebidos = Vec::new();
        while let Ok(signal) = signals.try_recv() {
            recebidos.push(signal);
        }
        assert!(!recebidos.is_empty(), "nada foi emitido");
        assert!(
            matches!(recebidos[0], Signal::Answer { .. }),
            "o primeiro sinal precisa ser a resposta, veio {:?}",
            recebidos[0]
        );
        agent.close_all().await;
    }

    #[tokio::test]
    async fn emite_candidatos_ice_pelo_canal() {
        let (mut agent, mut signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();

        // Depois da resposta vêm os candidatos, e o último é o vazio (fim).
        let mut vistos = 0;
        let mut fim = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while tokio::time::Instant::now() < deadline && !fim {
            match tokio::time::timeout_at(deadline, signals.recv()).await {
                Ok(Some(Signal::Ice { candidate, .. })) => {
                    if candidate.is_empty() {
                        fim = true;
                    } else {
                        vistos += 1;
                    }
                }
                Ok(Some(Signal::Answer { .. })) => {}
                Ok(None) | Err(_) => break,
            }
        }
        assert!(vistos > 0, "nenhum candidato ICE local foi emitido");
        agent.close_all().await;
    }

    #[tokio::test]
    async fn candidato_de_sessao_desconhecida_e_recusado() {
        let (mut agent, _signals) = video();
        assert!(
            !agent
                .candidate("fantasma", "candidate:1 ...", None, None)
                .await
        );
    }

    #[tokio::test]
    async fn candidato_vazio_e_aceito_sem_erro() {
        let (mut agent, _signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();
        assert!(agent.candidate("s1", "", None, None).await);
        agent.close_all().await;
    }

    #[tokio::test]
    async fn close_remove_e_e_idempotente() {
        let (mut agent, _signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();
        assert!(agent.close("s1").await);
        assert!(!agent.close("s1").await, "fechar de novo não é erro");
        assert!(agent.is_empty());
    }

    #[tokio::test]
    async fn renegociar_substitui_a_conexao_sem_duplicar_sessao() {
        let (mut agent, _signals) = video();
        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();
        assert_eq!(agent.len(), 1);
        agent.close_all().await;
    }

    #[tokio::test]
    async fn sem_sessao_conectada_nao_vale_codificar() {
        let (mut agent, _signals) = video();
        assert!(!agent.wants_video(), "sem sessão nenhuma");

        let app = app_peer().await;
        let offer = app.create_offer(None).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();
        // Sessão só negociada, sem ICE trocado: não conectou, então não vale
        // gastar CPU codificando.
        assert!(!agent.wants_video(), "sessão em negociação não conta");
        agent.close_all().await;
    }

    /// O teste que fecha a Fase 2: quadros H.264 de verdade, saídos do
    /// codificador, atravessando uma conexão WebRTC de verdade até o outro lado.
    ///
    /// Cobre o caminho inteiro — codificador → faixa → RTP/DTLS → receptor —
    /// que é justamente o que não dá para verificar por partes. Roda no Linux,
    /// sem tela e sem Windows, porque o quadro é sintético.
    #[tokio::test]
    async fn video_h264_atravessa_a_conexao() {
        let (mut agent, mut signals) = video();
        let app = app_peer().await;

        // Conta os bytes de RTP que chegarem do outro lado.
        let (rtp_tx, mut rtp_rx) = mpsc::unbounded_channel::<usize>();
        app.on_track(Box::new(move |track, _, _| {
            let rtp_tx = rtp_tx.clone();
            Box::pin(async move {
                tokio::spawn(async move {
                    while let Ok((packet, _)) = track.read_rtp().await {
                        if rtp_tx.send(packet.payload.len()).is_err() {
                            break;
                        }
                    }
                });
            })
        }));

        // Os candidatos do app vão para uma fila que o laço abaixo consome.
        let (app_ice_tx, mut app_ice_rx) = mpsc::unbounded_channel();
        app.on_ice_candidate(Box::new(move |candidate| {
            let app_ice_tx = app_ice_tx.clone();
            Box::pin(async move {
                let init = candidate.and_then(|c| c.to_json().ok());
                let _ = app_ice_tx.send(init);
            })
        }));

        // Oferta do app → resposta do agente.
        let offer = app.create_offer(None).await.unwrap();
        app.set_local_description(offer.clone()).await.unwrap();
        agent.offer("s1", &offer.sdp).await.unwrap();

        let Some(Signal::Answer { sdp, .. }) = signals.recv().await else {
            panic!("a resposta SDP não veio");
        };
        app.set_remote_description(RTCSessionDescription::answer(sdp).unwrap())
            .await
            .unwrap();

        // Troca de candidatos nas duas direções até a conexão fechar. Tudo numa
        // tarefa só, então o `&mut agent` não conflita com nada.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
        while !agent.wants_video() && tokio::time::Instant::now() < deadline {
            tokio::select! {
                Some(signal) = signals.recv() => {
                    if let Signal::Ice { candidate, sdp_mid, sdp_mline_index, .. } = signal {
                        if !candidate.is_empty() {
                            let init = RTCIceCandidateInit {
                                candidate, sdp_mid,
                                sdp_mline_index: sdp_mline_index.map(|i| i as u16),
                                ..Default::default()
                            };
                            let _ = app.add_ice_candidate(init).await;
                        }
                    }
                }
                Some(init) = app_ice_rx.recv() => {
                    match init {
                        Some(init) => {
                            agent.candidate(
                                "s1", &init.candidate, init.sdp_mid,
                                init.sdp_mline_index.map(u32::from),
                            ).await;
                        }
                        None => { agent.candidate("s1", "", None, None).await; }
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        }
        assert!(
            agent.wants_video(),
            "a conexão não fechou em 25s — sem isso não há o que medir"
        );

        // Agora o que importa: codificar quadros de verdade e mandá-los.
        let (w, h) = (320u32, 240u32);
        let mut encoder = crate::h264::Encoder::new(w, h, 30, 800_000).unwrap();
        let mut enviados = 0usize;
        for step in 0..30u32 {
            let mut rgb = vec![210u8; (w * h * 3) as usize];
            let x0 = (step * 9) % (w - 30);
            for y in 20..(h - 20) {
                for x in x0..(x0 + 30) {
                    let i = ((y * w + x) * 3) as usize;
                    rgb[i..i + 3].copy_from_slice(&[10, 60, 120]);
                }
            }
            let frame = encoder
                .encode(&rgb, w, h, Duration::from_millis(step as u64 * 33))
                .unwrap();
            enviados += frame.data.len();
            agent.write(&frame, Duration::from_millis(33)).await;
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(enviados > 0, "o codificador não produziu nada");

        // Espera os pacotes chegarem e soma o que atravessou.
        let mut recebidos = 0usize;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while recebidos * 2 < enviados && tokio::time::Instant::now() < deadline {
            match tokio::time::timeout_at(deadline, rtp_rx.recv()).await {
                Ok(Some(bytes)) => recebidos += bytes,
                Ok(None) | Err(_) => break,
            }
        }
        // Metade é folga suficiente: alguns pacotes podem estar em trânsito e o
        // RTP tem cabeçalho próprio. O ponto é que o vídeo atravessou de fato,
        // não um pacote solto.
        assert!(
            recebidos * 2 >= enviados,
            "atravessaram {recebidos} B de {enviados} B codificados"
        );

        agent.close_all().await;
    }

    #[tokio::test]
    async fn escrever_sem_sessao_nao_quebra() {
        let (agent, _signals) = video();
        let frame = EncodedFrame {
            data: vec![0, 0, 0, 1, 0x65],
            keyframe: true,
        };
        agent.write(&frame, Duration::from_millis(33)).await;
    }
}
