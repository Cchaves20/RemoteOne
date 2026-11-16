//! Teste de fumaça do webrtc-rs: duas conexões negociam e uma faixa H.264
//! atravessa de uma para a outra.
//!
//! Existe para responder cedo, antes de construir a Fase 2 em cima: a
//! biblioteca sobe neste ambiente, a negociação fecha, e o DTLS funciona sem
//! precisar instalar um crypto provider à mão (que foi o que nos morreu com o
//! rustls no WebSocket).
//!
//! ```bash
//! cargo run --release --example smoke_webrtc
//! ```

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264};
use webrtc::api::APIBuilder;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::rtp_transceiver::rtp_codec::{RTCRtpCodecCapability, RTPCodecType};
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut media = MediaEngine::default();
    media.register_default_codecs()?;
    let registry = register_default_interceptors(Registry::new(), &mut media)?;
    let api = Arc::new(
        APIBuilder::new()
            .with_media_engine(media)
            .with_interceptor_registry(registry)
            .build(),
    );

    // Sem STUN: as duas pontas estão na mesma máquina, candidatos locais bastam.
    let config = RTCConfiguration {
        ice_servers: vec![RTCIceServer::default()],
        ..Default::default()
    };

    let sender = Arc::new(api.new_peer_connection(config.clone()).await?);
    let receiver = Arc::new(api.new_peer_connection(config).await?);

    // Faixa de vídeo H.264 do lado que transmite (o papel do agente).
    let track = Arc::new(TrackLocalStaticSample::new(
        RTCRtpCodecCapability {
            mime_type: MIME_TYPE_H264.to_owned(),
            ..Default::default()
        },
        "video".to_owned(),
        "deskside".to_owned(),
    ));
    sender
        .add_track(Arc::clone(&track) as Arc<dyn TrackLocal + Send + Sync>)
        .await?;

    // O lado que recebe só quer receber (é o papel do app).
    receiver
        .add_transceiver_from_kind(RTPCodecType::Video, None)
        .await?;

    // Avisa quando o primeiro pacote RTP chegar do outro lado.
    let (got_tx, mut got_rx) = mpsc::channel::<usize>(1);
    receiver.on_track(Box::new(move |track, _, _| {
        let got_tx = got_tx.clone();
        Box::pin(async move {
            tokio::spawn(async move {
                if let Ok((packet, _)) = track.read_rtp().await {
                    let _ = got_tx.send(packet.payload.len()).await;
                }
            });
        })
    }));

    // Troca de candidatos ICE nas duas direções.
    let peer = Arc::clone(&receiver);
    sender.on_ice_candidate(Box::new(move |candidate| {
        let peer = Arc::clone(&peer);
        Box::pin(async move {
            if let Some(candidate) = candidate {
                if let Ok(init) = candidate.to_json() {
                    let _ = peer.add_ice_candidate(init).await;
                }
            }
        })
    }));
    let peer = Arc::clone(&sender);
    receiver.on_ice_candidate(Box::new(move |candidate| {
        let peer = Arc::clone(&peer);
        Box::pin(async move {
            if let Some(candidate) = candidate {
                if let Ok(init) = candidate.to_json() {
                    let _ = peer.add_ice_candidate(init).await;
                }
            }
        })
    }));

    // Oferta e resposta.
    let offer = sender.create_offer(None).await?;
    sender.set_local_description(offer.clone()).await?;
    receiver.set_remote_description(offer).await?;
    let answer = receiver.create_answer(None).await?;
    receiver.set_local_description(answer.clone()).await?;
    sender.set_remote_description(answer).await?;
    println!("✓ negociação concluída (oferta/resposta trocadas)");

    // Manda alguns "quadros". O conteúdo não importa aqui: o que se testa é o
    // caminho RTP/DTLS, não o codec.
    let writer = tokio::spawn(async move {
        for i in 0..120u32 {
            let payload = vec![i as u8; 1200];
            let _ = track
                .write_sample(&webrtc::media::Sample {
                    data: payload.into(),
                    duration: Duration::from_millis(33),
                    ..Default::default()
                })
                .await;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    });

    match tokio::time::timeout(Duration::from_secs(20), got_rx.recv()).await {
        Ok(Some(bytes)) => println!("✓ pacote RTP recebido do outro lado ({bytes} bytes)"),
        Ok(None) => {
            println!("✗ canal fechado sem receber pacote");
            std::process::exit(1);
        }
        Err(_) => {
            println!("✗ nenhum pacote em 20s — a mídia não atravessou");
            std::process::exit(1);
        }
    }

    writer.abort();
    sender.close().await?;
    receiver.close().await?;
    println!("✓ tudo certo: webrtc-rs funciona neste ambiente");
    Ok(())
}
