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
use webrtc::rtcp::payload_feedbacks::full_intra_request::FullIntraRequest;
use webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use webrtc::rtcp::receiver_report::ReceiverReport;
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
}

/// As faixas de som das sessões abertas, para quem manda o som.
///
/// O som sai por uma tarefa própria, e não pelo laço principal: lá ele
/// esperava cada quadro de imagem ser codificado (dezenas de milissegundos no
/// processador), a fila enchia e quadros de som eram jogados fora — o som
/// picotado. Esta lista é o que a tarefa precisa saber das sessões, sem tocar
/// no resto delas.
#[derive(Clone, Default)]
pub struct SaidaDeSom(Arc<std::sync::Mutex<Vec<FaixaDeSom>>>);

struct FaixaDeSom {
    sessao: String,
    conexao: Arc<RTCPeerConnection>,
    faixa: Arc<TrackLocalStaticSample>,
}

impl SaidaDeSom {
    fn por(&self, sessao: &str, conexao: Arc<RTCPeerConnection>, faixa: Arc<TrackLocalStaticSample>) {
        if let Ok(mut l) = self.0.lock() {
            l.retain(|f| f.sessao != sessao);
            l.push(FaixaDeSom {
                sessao: sessao.to_string(),
                conexao,
                faixa,
            });
        }
    }

    fn tirar(&self, sessao: &str) {
        if let Ok(mut l) = self.0.lock() {
            l.retain(|f| f.sessao != sessao);
        }
    }

    /// As faixas de sessões conectadas agora.
    fn conectadas(&self) -> Vec<(String, Arc<TrackLocalStaticSample>)> {
        self.0
            .lock()
            .map(|l| {
                l.iter()
                    .filter(|f| f.conexao.connection_state() == RTCPeerConnectionState::Connected)
                    .map(|f| (f.sessao.clone(), Arc::clone(&f.faixa)))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Se alguma sessão conectada tem faixa de som - isto é, se vale capturar.
    pub fn alguem_ouvindo(&self) -> bool {
        !self.conectadas().is_empty()
    }

    /// Escreve um quadro de som em todas as faixas conectadas.
    pub async fn escrever(&self, data: &[u8], duration: Duration) {
        let sample = webrtc::media::Sample {
            data: data.to_vec().into(),
            duration,
            ..Default::default()
        };
        // A lista é copiada antes: o cadeado não atravessa o `await`.
        for (sessao, faixa) in self.conectadas() {
            if let Err(e) = faixa.write_sample(&sample).await {
                eprintln!("falha ao enviar som ({sessao}): {e}");
            }
        }
    }
}

/// As sessões de WebRTC deste agente.
pub struct Video {
    api: API,
    ice_servers: Vec<crate::protocol::IceServer>,
    peers: HashMap<String, Peer>,
    outbox: UnboundedSender<Signal>,
    /// Entrada recebida pelo canal de dados. Sai por aqui porque o injetor de
    /// teclado/mouse vive no laço principal, e o webrtc-rs chama de volta de
    /// dentro das tarefas dele — mesmo desenho da sinalização.
    input: UnboundedSender<InputEnvelope>,
    /// Pedidos de quadro-chave vindos do telefone (RTCP PLI/FIR). Mesmo
    /// desenho: quem tem o codificador é o laço principal.
    keyframe: UnboundedSender<()>,
    /// Fração de pacotes perdida, como o telefone a relata (RTCP RR). Alimenta
    /// a qualidade adaptativa; sai pelo mesmo caminho porque quem decide a
    /// resolução também é o laço principal.
    loss: UnboundedSender<f32>,
    som: SaidaDeSom,
}

impl Video {
    /// Monta o motor de mídia. `ice_servers` são URLs de STUN (ex.:
    /// `stun:stun.l.google.com:19302`); vazio significa só rede local.
    pub fn new(
        outbox: UnboundedSender<Signal>,
        input: UnboundedSender<InputEnvelope>,
        keyframe: UnboundedSender<()>,
        loss: UnboundedSender<f32>,
        stun_urls: Vec<String>,
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
            ice_servers: vec![crate::protocol::IceServer {
                urls: stun_urls,
                ..Default::default()
            }],
            peers: HashMap::new(),
            outbox,
            input,
            keyframe,
            loss,
            som: SaidaDeSom::default(),
        })
    }

    /// Troca os servidores ICE (o backend os manda no `welcome`).
    ///
    /// Só vale para sessões novas, e é o suficiente: uma sessão em curso já
    /// achou (ou não) o caminho dela.
    pub fn set_ice_servers(&mut self, servers: Vec<crate::protocol::IceServer>) {
        if servers.is_empty() {
            return;
        }
        let agora = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let validade = servers
            .iter()
            .filter_map(|s| s.username.as_deref())
            .find_map(|u| segundos_ate_vencer(u, agora));
        // No diário, e não só no console: com o agente oculto, é esta linha
        // que diz se o computador tinha TURN — e se a credencial ainda valia —
        // quando o vídeo direto não fechou.
        crate::diario(&format!(
            "ICE: {} servidor(es) do backend{}",
            servers.len(),
            match validade {
                Some(s) => format!(" (com TURN, credencial vale por mais {}h)", s / 3600),
                None => " (só STUN)".to_string(),
            }
        ));
        self.ice_servers = servers;
    }

    fn configuration(&self) -> RTCConfiguration {
        RTCConfiguration {
            ice_servers: self
                .ice_servers
                .iter()
                .map(|s| RTCIceServer {
                    urls: s.urls.clone(),
                    username: s.username.clone().unwrap_or_default(),
                    credential: s.credential.clone().unwrap_or_default(),
                })
                .collect(),
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
            "deskside".to_owned(),
        ));
        let sender = connection
            .add_track(Arc::clone(&track) as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .map_err(|e| format!("não consegui adicionar a faixa de vídeo: {e}"))?;

        // Ouvir o que o telefone responde sobre o vídeo.
        //
        // Quando o decodificador dele se perde - o primeiro quadro-chave se
        // perdeu no caminho, um pacote sumiu, a rede engasgou -, ele pede um
        // quadro novo por RTCP (PLI/FIR). Sem alguém lendo isso, o pedido
        // morre aqui e a tela fica **preta para sempre**, mesmo com a conexão
        // perfeita: o computador segue mandando quadros que se referem a uma
        // imagem que o telefone nunca teve. Numa rede móvel, perder o
        // quadro-chave é questão de tempo.
        // O mesmo fluxo traz os **relatórios de recepção**, que dizem quanto do
        // que saiu daqui chegou lá. É o sinal da qualidade adaptativa: não
        // porque seja o melhor medidor de banda que existe, mas porque é o
        // único que as duas pontas já trocam sem nada novo no protocolo.
        let keyframe = self.keyframe.clone();
        let loss = self.loss.clone();
        let sessao = session_id.to_string();
        tokio::spawn(async move {
            // De quem é cada relatório: o celular manda um bloco por faixa, e
            // só o da imagem conta (ver `perda_da_imagem`).
            let da_imagem: Vec<u32> = sender
                .get_parameters()
                .await
                .encodings
                .iter()
                .map(|e| e.ssrc)
                .collect();
            let mut buf = vec![0u8; 1500];
            while let Ok((pacotes, _)) = sender.read(&mut buf).await {
                let mut pediu = false;
                let mut pior: Option<f32> = None;
                for pacote in &pacotes {
                    let algum = pacote.as_any();
                    if algum.downcast_ref::<PictureLossIndication>().is_some()
                        || algum.downcast_ref::<FullIntraRequest>().is_some()
                    {
                        pediu = true;
                    }
                    if let Some(rr) = algum.downcast_ref::<ReceiverReport>() {
                        if let Some(f) = perda_da_imagem(&rr.reports, &da_imagem) {
                            pior = Some(pior.map_or(f, |atual: f32| atual.max(f)));
                        }
                    }
                }
                if pediu {
                    println!("WebRTC ({sessao}): o app pediu um quadro-chave");
                    if keyframe.send(()).is_err() {
                        break; // laço principal encerrou
                    }
                }
                if let Some(f) = pior {
                    if loss.send(f).is_err() {
                        break;
                    }
                }
            }
        });

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
                // **Fluxo próprio, e não o `deskside` da tela.** Faixas no
                // mesmo fluxo o celular sincroniza: segura cada quadro até o
                // som daquele instante tocar, e o som toca com uma folga para
                // não picotar. Com som ligado, a imagem e o controle passavam
                // a chegar com essa folga de atraso, e engasgavam a cada
                // variação dela. Num controle remoto a imagem vale mais que
                // lábio sincronizado: separados, cada um chega no seu tempo.
                "deskside-som".to_owned(),
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
        // Quantos de cada tipo, para o diário: é o lado do computador do
        // "celular: 20 host + 1 srflx + 2 relay; computador: 1 host" que o app
        // mostra, e sem ele não dá para saber se o STUN e o TURN responderam.
        let contagem: Arc<std::sync::Mutex<std::collections::BTreeMap<String, u32>>> =
            Arc::default();
        connection.on_ice_candidate(Box::new(move |candidate| {
            let outbox = outbox.clone();
            let session = session.clone();
            let contagem = contagem.clone();
            Box::pin(async move {
                let init = candidate.and_then(|c| c.to_json().ok());
                if let Ok(mut c) = contagem.lock() {
                    match &init {
                        Some(i) => {
                            *c.entry(tipo_do_candidato(&i.candidate).to_string())
                                .or_default() += 1
                        }
                        None => crate::diario(&format!(
                            "WebRTC ({session}): caminhos do computador: {}",
                            resumo_de_candidatos(&c)
                        )),
                    }
                }
                // `None` é o fim dos candidatos; vira candidato vazio no fio,
                // que é o que a outra ponta espera para parar de aguardar.
                let signal = match init {
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
            crate::diario(&format!("WebRTC ({session}): {state}"));
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

        if let Some(faixa) = &audio {
            self.som
                .por(session_id, Arc::clone(&connection), Arc::clone(faixa));
        }
        self.peers.insert(
            session_id.to_string(),
            Peer { connection, track },
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
        self.som.tirar(session_id);
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
        self.som.alguem_ouvindo()
    }

    /// Por onde o som sai, para a tarefa dele (ver [`SaidaDeSom`]).
    pub fn saida_de_som(&self) -> SaidaDeSom {
        self.som.clone()
    }

    /// Fecha todas as sessões (usado quando a conexão com o backend cai).
    pub async fn close_all(&mut self) {
        let sessions: Vec<String> = self.peers.keys().cloned().collect();
        for session_id in sessions {
            self.close(&session_id).await;
        }
    }
}

/// A perda da imagem num relatório de recepção do celular.
///
/// `fraction_lost` é a perda desde o relatório anterior, em 1/256 avos. O
/// relatório traz um bloco por faixa — a da imagem e, com o som ligado, a do
/// som —, e o pior **da imagem** manda. Contar o do som era o defeito: o som
/// perde pacotes que o Opus disfarça sem ninguém notar, e cada perda dele
/// fazia a qualidade da imagem cair à toa — só com o som ligado.
///
/// Sem saber qual é a faixa da imagem (lista vazia), conta todos, como antes.
fn perda_da_imagem(
    blocos: &[webrtc::rtcp::reception_report::ReceptionReport],
    da_imagem: &[u32],
) -> Option<f32> {
    blocos
        .iter()
        .filter(|b| da_imagem.is_empty() || da_imagem.contains(&b.ssrc))
        .map(|b| b.fraction_lost as f32 / 256.0)
        .reduce(f32::max)
}

/// O tipo de um candidato ICE (`host`, `srflx`, `relay`), lido do texto dele.
pub(crate) fn tipo_do_candidato(candidato: &str) -> &str {
    let mut partes = candidato.split_whitespace();
    while let Some(p) = partes.next() {
        if p == "typ" {
            return partes.next().unwrap_or("?");
        }
    }
    "?"
}

/// `1 host + 1 srflx`, ou `nenhum`. O mesmo formato do app.
pub(crate) fn resumo_de_candidatos(contagem: &std::collections::BTreeMap<String, u32>) -> String {
    if contagem.is_empty() {
        return "nenhum".into();
    }
    contagem
        .iter()
        .map(|(tipo, n)| format!("{n} {tipo}"))
        .collect::<Vec<_>>()
        .join(" + ")
}

/// Quantos segundos faltam para a credencial de TURN vencer.
///
/// O usuário é `<vence em unix>:<quem>` (ver `backend/app/ice.py`). `None`
/// se não estiver nesse formato.
pub(crate) fn segundos_ate_vencer(usuario: &str, agora_unix: i64) -> Option<i64> {
    let vence: i64 = usuario.split_once(':')?.0.parse().ok()?;
    Some(vence - agora_unix)
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
        // O canal de quadro-chave é descartado: estes testes cuidam da
        // negociação. O pedido em si é do laço principal.
        let (keyframe_tx, _keyframe_rx) = mpsc::unbounded_channel();
        std::mem::forget(_keyframe_rx);
        // Idem para a perda: a política que a consome é testada, pura, no
        // `adaptive`.
        let (loss_tx, _loss_rx) = mpsc::unbounded_channel();
        std::mem::forget(_loss_rx);
        (
            Video::new(tx, input_tx, keyframe_tx, loss_tx, vec![]).unwrap(),
            rx,
        )
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
        // Som e tela em fluxos diferentes: no mesmo, o celular atrasaria a
        // imagem para esperar o som.
        assert!(sdp.contains("a=msid:deskside tela"), "a tela saiu do fluxo dela");
        assert!(sdp.contains("a=msid:deskside-som som"), "o som ficou no fluxo da tela");

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

    #[test]
    fn le_o_tipo_do_candidato() {
        assert_eq!(
            tipo_do_candidato("candidate:1 1 udp 2130706431 192.168.0.10 50000 typ host"),
            "host"
        );
        assert_eq!(
            tipo_do_candidato(
                "candidate:2 1 udp 1694498815 200.1.2.3 50000 typ srflx raddr 0.0.0.0 rport 0"
            ),
            "srflx"
        );
        assert_eq!(tipo_do_candidato("lixo"), "?");
    }

    #[test]
    fn resume_os_candidatos_como_o_app() {
        let mut c = std::collections::BTreeMap::new();
        assert_eq!(resumo_de_candidatos(&c), "nenhum");
        c.insert("host".to_string(), 1);
        c.insert("relay".to_string(), 2);
        assert_eq!(resumo_de_candidatos(&c), "1 host + 2 relay");
    }

    #[test]
    fn sabe_quanto_falta_para_a_credencial_vencer() {
        assert_eq!(segundos_ate_vencer("1000:agent-x", 400), Some(600));
        // Vencida: negativo, e o diário mostra isso.
        assert_eq!(segundos_ate_vencer("1000:agent-x", 1600), Some(-600));
        assert_eq!(segundos_ate_vencer("sem-prazo", 0), None);
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

    /// Negocia uma sessão entre o "app" e o agente e troca candidatos até a
    /// conexão fechar. Tudo numa tarefa só, então o `&mut agent` não conflita
    /// com nada.
    async fn conectar(
        agent: &mut Video,
        signals: &mut mpsc::UnboundedReceiver<Signal>,
        app: &Arc<RTCPeerConnection>,
    ) {
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

        // Troca de candidatos nas duas direções até a conexão fechar.
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

        conectar(&mut agent, &mut signals, &app).await;

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

    /// O som sai por uma tarefa separada do agente (ver `SaidaDeSom`) e chega
    /// do outro lado de uma conexão de verdade. É a garantia de que a tarefa
    /// do som não precisa do laço principal para nada.
    #[tokio::test]
    async fn som_sai_por_tarefa_propria_e_atravessa_a_conexao() {
        let (mut agent, mut signals) = video();
        let app = app_peer_com_som().await;

        let (rtp_tx, mut rtp_rx) = mpsc::unbounded_channel::<usize>();
        app.on_track(Box::new(move |track, _, _| {
            let rtp_tx = rtp_tx.clone();
            Box::pin(async move {
                if track.kind() != RTPCodecType::Audio {
                    return;
                }
                tokio::spawn(async move {
                    while let Ok((packet, _)) = track.read_rtp().await {
                        if rtp_tx.send(packet.payload.len()).is_err() {
                            break;
                        }
                    }
                });
            })
        }));
        conectar(&mut agent, &mut signals, &app).await;
        assert!(agent.wants_audio(), "a sessão conectada tem faixa de som");

        // Outra tarefa, só com a saída de som: o agente fica parado aqui.
        let saida = agent.saida_de_som();
        let tarefa = tokio::spawn(async move {
            for _ in 0..50 {
                saida.escrever(&[0xF8, 0xFF, 0xFE], Duration::from_millis(20)).await;
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        });
        let mut pacotes = 0;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while pacotes < 25 {
            match tokio::time::timeout_at(deadline, rtp_rx.recv()).await {
                Ok(Some(_)) => pacotes += 1,
                Ok(None) | Err(_) => break,
            }
        }
        tarefa.await.unwrap();
        assert!(pacotes >= 25, "só {pacotes} pacotes de som atravessaram");

        // Fechada a sessão, a faixa sai da lista do som.
        agent.close_all().await;
        assert!(!agent.saida_de_som().alguem_ouvindo());
    }

    #[test]
    fn a_perda_do_som_nao_derruba_a_imagem() {
        use webrtc::rtcp::reception_report::ReceptionReport;
        let bloco = |ssrc, fraction_lost| ReceptionReport {
            ssrc,
            fraction_lost,
            ..Default::default()
        };
        // Imagem (111) sem perda; som (222) perdendo um terço.
        let blocos = [bloco(111, 0), bloco(222, 85)];
        assert_eq!(perda_da_imagem(&blocos, &[111]), Some(0.0));
        // A da imagem conta.
        let blocos = [bloco(111, 64), bloco(222, 0)];
        assert_eq!(perda_da_imagem(&blocos, &[111]), Some(0.25));
        // Relatório só do som: nada a dizer sobre a imagem.
        assert_eq!(perda_da_imagem(&[bloco(222, 200)], &[111]), None);
        // Sem saber qual é a da imagem, o pior de todos, como antes.
        assert_eq!(perda_da_imagem(&[bloco(222, 128)], &[]), Some(0.5));
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
