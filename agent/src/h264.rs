//! Codificação H.264 dos quadros de tela (Fase 2 do `docs/webrtc-plano.md`).
//!
//! Envolve o `openh264` numa interface que recebe RGB e devolve H.264 em Annex-B
//! — o formato que o `webrtc-rs` espera numa amostra de vídeo.
//!
//! As escolhas de configuração vêm do spike S2, que mediu o codec contra o JPEG
//! que estava no ar. Duas merecem explicação:
//!
//! - **Perfil de conteúdo de tela** (`ScreenContentRealTime`) em vez do de
//!   câmera: a tela de um computador é quase toda superfície plana com texto
//!   nítido, o oposto de vídeo natural.
//! - **Sem descarte de quadros.** O padrão do openh264 é jogar quadros fora
//!   para caber no teto de banda; no S2 isso entregou 7 de 90 quadros (~2 fps).
//!   Para controle remoto, imagem borrada é ruim mas usável — imagem travada
//!   não é.
//!
//! Essa segunda escolha tem uma consequência que vale dizer em voz alta: com o
//! descarte desligado, **o openh264 não respeita o teto de banda**. Ele avisa
//! isso na saída, e a medição confirmou — no cenário extremo (ruído em tela
//! cheia) a taxa foi a 26 Mbps com alvo de 1,5. As alternativas foram medidas e
//! nenhuma resolve: o teto de quantização corta só ~16%, e o modo por buffer
//! chegou a 68 Mbps, porque ele *sobe* a qualidade em vez de segurar a banda.
//!
//! Isso é aceitável porque o cenário extremo não é o nosso: em conteúdo de
//! desktop o S2 mediu 0,08–0,22 Mbps, uma ordem de grandeza abaixo do alvo, e o
//! teto simplesmente nunca entra em jogo. O caminho certo para limitar de
//! verdade é reduzir resolução e fps quando a rede aperta — degrada suave, sem
//! travar — e isso é assunto de uma etapa de refino, não deste módulo.

use openh264::encoder::{
    BitRate, Encoder as Openh264Encoder, EncoderConfig, FrameRate, FrameType, QpRange, UsageType,
};
use openh264::formats::{RgbSliceU8, YUVBuffer};
use openh264::{OpenH264API, Timestamp};

/// Um quadro codificado, pronto para virar amostra de vídeo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedFrame {
    /// Fluxo H.264 em Annex-B (com os prefixos de início de NAL).
    pub data: Vec<u8>,
    /// Se é quadro-chave (IDR), decodificável por si só.
    pub keyframe: bool,
}

/// Codificador H.264 persistente.
///
/// Precisa viver entre quadros: é justamente guardar o quadro anterior que
/// permite mandar só a diferença — a economia toda do codec vem daí. Criar um
/// codificador por quadro produziria um quadro-chave a cada vez e jogaria fora
/// o ganho.
pub struct Encoder {
    inner: Openh264Encoder,
    yuv: YUVBuffer,
    width: u32,
    height: u32,
    /// Quantos quadros já passaram — só para diagnóstico.
    frames: u64,
}

impl Encoder {
    /// Cria o codificador para uma resolução e taxa de bits alvo.
    ///
    /// A largura e a altura precisam ser pares (exigência do H.264, que
    /// trabalha em blocos e subamostra a cor pela metade).
    pub fn new(width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<Self, String> {
        if !width.is_multiple_of(2) || !height.is_multiple_of(2) {
            return Err(format!(
                "dimensões ímpares não servem para H.264: {width}x{height}"
            ));
        }
        let config = EncoderConfig::new()
            .usage_type(UsageType::ScreenContentRealTime)
            .skip_frames(false)
            .max_frame_rate(FrameRate::from_hz(fps as f32))
            .bitrate(BitRate::from_bps(bitrate_bps))
            // Só teto, sem piso. O piso que havia aqui (20) foi medido e fazia
            // o oposto do pretendido: forçava qualidade alta em conteúdo fácil,
            // gastando 1,6 KB por quadro onde o controle de taxa gastava 1,3 —
            // e sem economizar tempo algum. O teto continua, porque limita o
            // pior caso e custa zero.
            .qp(QpRange::new(0, 46));
        let inner = Openh264Encoder::with_api_config(OpenH264API::from_source(), config)
            .map_err(|e| format!("não consegui criar o codificador H.264: {e}"))?;
        Ok(Self {
            inner,
            yuv: YUVBuffer::new(width as usize, height as usize),
            width,
            height,
            frames: 0,
        })
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    /// Quadros codificados desde a criação.
    pub fn frames(&self) -> u64 {
        self.frames
    }

    /// Se o codificador serve para um quadro deste tamanho.
    ///
    /// Trocar de monitor ou mudar a resolução no meio da sessão muda o tamanho
    /// do quadro; nesse caso o chamador recria o codificador em vez de tentar
    /// remendar o que já está em andamento.
    pub fn fits(&self, width: u32, height: u32) -> bool {
        self.width == width && self.height == height
    }

    /// Codifica um quadro RGB (3 bytes por pixel, sem alfa).
    ///
    /// `elapsed` é o tempo **real** desde o início da transmissão. Precisa ser
    /// medido, não calculado a partir do fps pretendido: capturar e codificar
    /// leva dezenas de milissegundos, então o ritmo efetivo é sempre menor que o
    /// alvo. Alimentar o codificador com um relógio que não corresponde à
    /// realidade faz o controle de taxa trabalhar sobre uma premissa falsa.
    pub fn encode(
        &mut self,
        rgb: &[u8],
        width: u32,
        height: u32,
        elapsed: std::time::Duration,
    ) -> Result<EncodedFrame, String> {
        if !self.fits(width, height) {
            return Err(format!(
                "quadro {width}x{height} não casa com o codificador {}x{}",
                self.width, self.height
            ));
        }
        let expected = (width as usize) * (height as usize) * 3;
        if rgb.len() != expected {
            return Err(format!(
                "quadro com {} bytes, esperado {expected}",
                rgb.len()
            ));
        }

        self.yuv
            .read_rgb8(RgbSliceU8::new(rgb, (width as usize, height as usize)));
        let bitstream = self
            .inner
            .encode_at(
                &self.yuv,
                Timestamp::from_millis(elapsed.as_millis() as u64),
            )
            .map_err(|e| format!("falha ao codificar: {e}"))?;
        let keyframe = bitstream.frame_type() == FrameType::IDR;
        let data = bitstream.to_vec();
        self.frames += 1;
        Ok(EncodedFrame { data, keyframe })
    }

    /// Força o próximo quadro a ser quadro-chave.
    ///
    /// É o que resolve um app que entra no meio da transmissão: sem um IDR ele
    /// não tem como começar a decodificar e fica na tela preta.
    pub fn request_keyframe(&mut self) {
        self.inner.force_intra_frame();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(v: u64) -> std::time::Duration {
        std::time::Duration::from_millis(v)
    }

    /// Uma "tela" simples com um retângulo que se move — dá conteúdo para o
    /// codificador ter o que fazer entre quadros.
    fn frame(width: u32, height: u32, step: u32) -> Vec<u8> {
        let mut rgb = vec![220u8; (width * height * 3) as usize];
        let x0 = (step * 7) % (width - 40);
        for y in 10..(height / 2) {
            for x in x0..(x0 + 40) {
                let i = ((y * width + x) * 3) as usize;
                rgb[i..i + 3].copy_from_slice(&[20, 40, 90]);
            }
        }
        rgb
    }

    #[test]
    fn primeiro_quadro_e_chave_e_tem_conteudo() {
        let mut encoder = Encoder::new(320, 240, 30, 800_000).unwrap();
        let encoded = encoder
            .encode(&frame(320, 240, 0), 320, 240, ms(0))
            .unwrap();
        assert!(encoded.keyframe, "o primeiro quadro tem que ser IDR");
        // Annex-B começa com o prefixo de início 00 00 00 01.
        assert_eq!(&encoded.data[0..4], &[0, 0, 0, 1]);
    }

    #[test]
    fn quadros_seguintes_sao_muito_menores_que_o_primeiro() {
        // É a razão de existir do codec: mandar só o que mudou. Se esta
        // proporção se perder, o codificador está sendo recriado ou
        // reinicializado sem querer.
        let mut encoder = Encoder::new(640, 480, 30, 1_000_000).unwrap();
        let chave = encoder
            .encode(&frame(640, 480, 0), 640, 480, ms(0))
            .unwrap();
        let mut soma_depois = 0usize;
        for step in 1..10 {
            soma_depois += encoder
                .encode(&frame(640, 480, step), 640, 480, ms(step as u64 * 33))
                .unwrap()
                .data
                .len();
        }
        let media_depois = soma_depois / 9;
        assert!(
            media_depois * 4 < chave.data.len(),
            "quadro de diferença ({media_depois} B) deveria ser bem menor que o IDR ({} B)",
            chave.data.len()
        );
    }

    #[test]
    fn tela_parada_gasta_quase_nada() {
        let mut encoder = Encoder::new(320, 240, 30, 800_000).unwrap();
        let parada = frame(320, 240, 0);
        let chave = encoder.encode(&parada, 320, 240, ms(0)).unwrap();
        let repetido = encoder.encode(&parada, 320, 240, ms(33)).unwrap();
        assert!(!repetido.keyframe);
        assert!(
            repetido.data.len() * 10 < chave.data.len(),
            "quadro idêntico gerou {} B contra {} B do IDR",
            repetido.data.len(),
            chave.data.len()
        );
    }

    #[test]
    fn dimensoes_impares_sao_recusadas_na_criacao() {
        assert!(Encoder::new(321, 240, 30, 500_000).is_err());
        assert!(Encoder::new(320, 241, 30, 500_000).is_err());
    }

    #[test]
    fn quadro_de_tamanho_errado_e_recusado() {
        let mut encoder = Encoder::new(320, 240, 30, 500_000).unwrap();
        // Dimensão diferente da configurada.
        assert!(encoder
            .encode(&frame(640, 480, 0), 640, 480, ms(0))
            .is_err());
        // Dimensão certa, buffer curto.
        assert!(encoder.encode(&[0u8; 10], 320, 240, ms(0)).is_err());
    }

    #[test]
    fn fits_reconhece_a_resolucao() {
        let encoder = Encoder::new(320, 240, 30, 500_000).unwrap();
        assert!(encoder.fits(320, 240));
        assert!(!encoder.fits(320, 480));
    }
}
