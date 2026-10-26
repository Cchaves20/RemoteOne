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
//!
//! ## Na placa de vídeo, quando dá (Windows)
//!
//! O openh264 codifica no processador, e o custo cresce com os pixels: ~40 ms
//! por quadro em 1280 px no Dell de testes, o que prende a imagem em ~20 fps e
//! atrasa cada quadro. No Windows, o `Encoder` tenta antes o codificador da
//! placa de vídeo (ver `h264_placa.rs`) e só cai no openh264 se ela não tiver
//! um, se ele recusar a configuração ou se falhar no meio — aí o openh264
//! assume sem a sessão cair. `DESKSIDE_VIDEO_ENCODER=cpu` força o openh264.

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
    motor: Motor,
    width: u32,
    height: u32,
    /// Para o openh264 assumir com os mesmos números se a placa falhar.
    #[cfg_attr(not(windows), allow(dead_code))]
    fps: u32,
    #[cfg_attr(not(windows), allow(dead_code))]
    bitrate_bps: u32,
    /// Quantos quadros já passaram — só para diagnóstico.
    frames: u64,
}

/// Quem codifica de fato.
enum Motor {
    // Em caixa: o openh264 ocupa uns 7 KB, a placa quase nada.
    Processador(Box<Openh264>),
    #[cfg(windows)]
    Placa(crate::h264_placa::Placa),
}

/// O openh264, no processador. Funciona em qualquer máquina.
struct Openh264 {
    inner: Openh264Encoder,
    yuv: YUVBuffer,
}

impl Openh264 {
    fn new(width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<Self, String> {
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
        })
    }

    fn encode(
        &mut self,
        rgb: &[u8],
        width: u32,
        height: u32,
        elapsed: std::time::Duration,
    ) -> Result<EncodedFrame, String> {
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
        Ok(EncodedFrame {
            data: bitstream.to_vec(),
            keyframe,
        })
    }
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
        #[cfg(windows)]
        if let Some(placa) = crate::h264_placa::abrir(width, height, fps, bitrate_bps) {
            return Ok(Self {
                motor: Motor::Placa(placa),
                width,
                height,
                fps,
                bitrate_bps,
                frames: 0,
            });
        }
        Ok(Self {
            motor: Motor::Processador(Box::new(Openh264::new(width, height, fps, bitrate_bps)?)),
            width,
            height,
            fps,
            bitrate_bps,
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
    /// RGB e não RGBA: só `RgbSliceU8` implementa `RGB8Source`, o caminho rápido
    /// do `openh264`. O wrapper de RGBA existe, mas cai no caminho por pixel em
    /// `f32` — trocar uma passagem de conversão por isso seria pior.
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

        let quadro = match &mut self.motor {
            Motor::Processador(p) => p.encode(rgb, width, height, elapsed)?,
            #[cfg(windows)]
            Motor::Placa(p) => match p.encode(rgb, width, height, elapsed) {
                Ok(quadro) => quadro,
                // A placa falhou no meio: o openh264 assume aqui mesmo, e a
                // sessão segue sem perceber. O primeiro quadro dele é chave,
                // então o celular retoma sem pedir nada.
                Err(e) => {
                    crate::h264_placa::desistir(&e);
                    let mut cpu = Openh264::new(width, height, self.fps, self.bitrate_bps)?;
                    let quadro = cpu.encode(rgb, width, height, elapsed)?;
                    self.motor = Motor::Processador(Box::new(cpu));
                    quadro
                }
            },
        };
        self.frames += 1;
        Ok(quadro)
    }

    /// Força o próximo quadro a ser quadro-chave.
    ///
    /// É o que resolve um app que entra no meio da transmissão: sem um IDR ele
    /// não tem como começar a decodificar e fica na tela preta.
    pub fn request_keyframe(&mut self) {
        match &mut self.motor {
            Motor::Processador(p) => p.inner.force_intra_frame(),
            #[cfg(windows)]
            Motor::Placa(p) => p.request_keyframe(),
        }
    }
}

/// RGB (3 bytes por pixel) para NV12, o formato que os codificadores das
/// placas de vídeo recebem: o brilho (Y) de cada pixel, e depois a cor (U e V
/// intercalados) de cada bloco de 2x2.
///
/// BT.601 em faixa limitada (16–235), o padrão do H.264 sem informação de cor
/// — o mesmo que o openh264 usa, para a imagem não mudar de tom ao trocar de
/// codificador. Inteiro e sem desvio: ~1 milhão de pixels em poucos
/// milissegundos.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn rgb_para_nv12(rgb: &[u8], largura: usize, altura: usize, saida: &mut Vec<u8>) {
    saida.clear();
    saida.resize(largura * altura * 3 / 2, 0);
    let (brilho, cor) = saida.split_at_mut(largura * altura);
    for (linha_y, linha_rgb) in brilho.chunks_exact_mut(largura).zip(rgb.chunks_exact(largura * 3)) {
        for (y, px) in linha_y.iter_mut().zip(linha_rgb.chunks_exact(3)) {
            let (r, g, b) = (px[0] as i32, px[1] as i32, px[2] as i32);
            *y = (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8;
        }
    }
    for (bloco, linha_uv) in cor.chunks_exact_mut(largura).enumerate() {
        let (cima, baixo) = (bloco * 2, bloco * 2 + 1);
        for (coluna, uv) in linha_uv.chunks_exact_mut(2).enumerate() {
            let (mut r, mut g, mut b) = (0i32, 0i32, 0i32);
            for linha in [cima, baixo] {
                for x in [coluna * 2, coluna * 2 + 1] {
                    let i = (linha * largura + x) * 3;
                    r += rgb[i] as i32;
                    g += rgb[i + 1] as i32;
                    b += rgb[i + 2] as i32;
                }
            }
            let (r, g, b) = (r / 4, g / 4, b / 4);
            uv[0] = (((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128) as u8;
            uv[1] = (((112 * r - 94 * g - 18 * b + 128) >> 8) + 128) as u8;
        }
    }
}

/// As unidades (NAL) de um trecho H.264 em Annex-B: `(tipo, bytes com o
/// prefixo de início)`.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn unidades(dados: &[u8]) -> Vec<(u8, &[u8])> {
    // Onde cada prefixo começa e onde o conteúdo depois dele começa.
    let mut inicios = Vec::new();
    let mut i = 0;
    while i + 3 <= dados.len() {
        if dados[i] == 0 && dados[i + 1] == 0 && dados[i + 2] == 1 {
            let prefixo = if i > 0 && dados[i - 1] == 0 { i - 1 } else { i };
            inicios.push((prefixo, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    inicios
        .iter()
        .enumerate()
        .filter_map(|(n, &(prefixo, conteudo))| {
            let fim = inicios.get(n + 1).map_or(dados.len(), |&(p, _)| p);
            let tipo = dados.get(conteudo)? & 0x1F;
            Some((tipo, &dados[prefixo..fim]))
        })
        .collect()
}

/// Garante que todo quadro-chave leve os parâmetros da sequência (SPS e PPS).
///
/// Sem eles, um celular que entra no meio — ou que pediu um quadro-chave
/// depois de se perder — não tem como começar a decodificar, e a tela fica
/// preta. O openh264 sempre os manda; codificadores de placa de vídeo, nem
/// sempre (alguns só no primeiro). Os vistos ficam em `guardados` e entram na
/// frente de um quadro-chave que vier sem eles.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn com_parametros(dados: Vec<u8>, guardados: &mut Vec<u8>) -> Vec<u8> {
    let nal = unidades(&dados);
    let parametros: Vec<u8> = nal
        .iter()
        .filter(|(tipo, _)| *tipo == 7 || *tipo == 8)
        .flat_map(|(_, bytes)| bytes.iter().copied())
        .collect();
    if !parametros.is_empty() {
        *guardados = parametros;
        return dados;
    }
    let chave = nal.iter().any(|(tipo, _)| *tipo == 5);
    if chave && !guardados.is_empty() {
        let mut junto = guardados.clone();
        junto.extend_from_slice(&dados);
        return junto;
    }
    dados
}

#[cfg(test)]
mod tests {
    #[test]
    fn nv12_tem_as_cores_de_referencia_do_bt601() {
        // Branco, preto e vermelho puros, em 2x2 (um bloco de cor).
        let mut saida = Vec::new();
        for (rgb, y, u, v) in [
            ([255u8, 255, 255], 235u8, 128u8, 128u8),
            ([0, 0, 0], 16, 128, 128),
            ([255, 0, 0], 82, 90, 240),
        ] {
            let quadro: Vec<u8> = rgb.iter().copied().cycle().take(2 * 2 * 3).collect();
            rgb_para_nv12(&quadro, 2, 2, &mut saida);
            assert_eq!(saida.len(), 6, "4 de brilho + 1 par de cor");
            assert!(saida[..4].iter().all(|b| (*b as i32 - y as i32).abs() <= 1), "{rgb:?}: {saida:?}");
            assert!((saida[4] as i32 - u as i32).abs() <= 1, "{rgb:?}: U {}", saida[4]);
            assert!((saida[5] as i32 - v as i32).abs() <= 1, "{rgb:?}: V {}", saida[5]);
        }
    }

    #[test]
    fn nv12_poe_a_cor_de_cada_bloco_no_lugar_certo() {
        // 4x2: metade esquerda preta, direita branca. Dois blocos de cor,
        // ambos cinza-neutros, e o brilho seguindo cada pixel.
        let mut quadro = Vec::new();
        for _ in 0..2 {
            for x in 0..4 {
                let c = if x < 2 { 0 } else { 255 };
                quadro.extend_from_slice(&[c, c, c]);
            }
        }
        let mut saida = Vec::new();
        rgb_para_nv12(&quadro, 4, 2, &mut saida);
        assert_eq!(&saida[..4], &[16, 16, 235, 235]);
        assert_eq!(&saida[4..8], &[16, 16, 235, 235]);
        assert_eq!(&saida[8..], &[128, 128, 128, 128]);
    }

    #[test]
    fn separa_as_unidades_com_os_dois_prefixos() {
        let dados = [
            0, 0, 0, 1, 0x67, 1, 2, // SPS, prefixo de 4 bytes
            0, 0, 1, 0x68, 3, // PPS, prefixo de 3 bytes
            0, 0, 0, 1, 0x65, 4, 5, 6, // IDR
        ];
        let nal = unidades(&dados);
        let tipos: Vec<u8> = nal.iter().map(|(t, _)| *t).collect();
        assert_eq!(tipos, vec![7, 8, 5]);
        assert_eq!(nal[0].1, &[0, 0, 0, 1, 0x67, 1, 2]);
        assert_eq!(nal[1].1, &[0, 0, 1, 0x68, 3]);
    }

    #[test]
    fn quadro_chave_sem_parametros_ganha_os_guardados() {
        let mut guardados = Vec::new();
        let primeiro = vec![0, 0, 0, 1, 0x67, 9, 0, 0, 0, 1, 0x68, 8, 0, 0, 0, 1, 0x65, 1];
        assert_eq!(com_parametros(primeiro.clone(), &mut guardados), primeiro);
        assert_eq!(guardados, vec![0, 0, 0, 1, 0x67, 9, 0, 0, 0, 1, 0x68, 8]);

        // Quadro comum: passa como veio.
        let comum = vec![0, 0, 0, 1, 0x41, 7];
        assert_eq!(com_parametros(comum.clone(), &mut guardados), comum);

        // Quadro-chave sem SPS/PPS (o que algumas placas fazem): ganha os dois.
        let chave = vec![0, 0, 0, 1, 0x65, 2];
        let consertado = com_parametros(chave, &mut guardados);
        let tipos: Vec<u8> = unidades(&consertado).iter().map(|(t, _)| *t).collect();
        assert_eq!(tipos, vec![7, 8, 5]);
    }

    #[test]
    fn nv12_alimenta_um_codificador_h264_de_verdade() {
        // O NV12 daqui, convertido de volta para planos separados, codifica no
        // openh264 e sai como quadro-chave: o formato está certo de ponta a
        // ponta, e não só nos números.
        use openh264::formats::YUVSlices;
        let (w, h) = (64usize, 48usize);
        let rgb = frame(w as u32, h as u32, 3);
        let mut nv12 = Vec::new();
        rgb_para_nv12(&rgb, w, h, &mut nv12);
        let (y, uv) = nv12.split_at(w * h);
        let u: Vec<u8> = uv.iter().step_by(2).copied().collect();
        let v: Vec<u8> = uv.iter().skip(1).step_by(2).copied().collect();
        let fatias = YUVSlices::new((y, &u, &v), (w, h), (w, w / 2, w / 2));
        let mut enc = Openh264Encoder::new().unwrap();
        let saida = enc.encode(&fatias).unwrap();
        assert_eq!(saida.frame_type(), FrameType::IDR);
        assert!(!saida.to_vec().is_empty());
    }

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
