//! Spike S2 do plano de WebRTC: quanto custa codificar em H.264 no agente, e
//! quanto se ganha de banda contra o JPEG que está no ar hoje.
//!
//! Não faz parte do agente. Com um desktop sintético:
//!
//! ```bash
//! cargo run --release --example bench_h264
//! ```
//!
//! Ou com quadros reais gravados pelo `capture_frames` (bem mais fiel):
//!
//! ```bash
//! cargo run --release --example bench_h264 -- quadros/
//! ```
//!
//! O que importa aqui não é um quadro isolado, e sim a **sequência**: o H.264
//! ganha justamente por só mandar o que mudou de um quadro para o outro. Por
//! isso os cenários sintéticos imitam usos reais de uma tela de computador.

use image::codecs::jpeg::JpegEncoder;
use image::ExtendedColorType;
use openh264::encoder::{BitRate, Encoder, EncoderConfig, FrameRate, FrameType, UsageType};
use openh264::formats::{RgbSliceU8, YUVBuffer};
use openh264::{OpenH264API, Timestamp};
use std::time::Instant;

const FPS: u32 = 30;
const FRAMES: u32 = 90; // 3 segundos
const JPEG_QUALITY: u8 = 50; // o mesmo que o agente usa hoje
const TARGET_BPS: u32 = 1_500_000;

/// Uma sequência de quadros RGB, todos do mesmo tamanho.
struct Clip {
    frames: Vec<Vec<u8>>,
    w: usize,
    h: usize,
    label: String,
}

// --- uma "tela de computador" sintética ---------------------------------------
//
// Fundo claro, uma janela com barra de título e linhas de texto (retângulos
// escuros pequenos). Texto é conteúdo de alta frequência e alto contraste — o
// caso difícil para os dois codecs, então é uma comparação honesta.
//
// Ainda assim é mais simples que uma tela real (sem suavização de fontes, sem
// ícones, sem fotos): os números do H.264 aqui são otimistas. Para fechar essa
// lacuna, use o `capture_frames` e passe a pasta ao benchmark.

struct Desktop {
    pixels: Vec<u8>,
    w: usize,
    h: usize,
}

impl Desktop {
    fn new(w: usize, h: usize) -> Self {
        Self {
            pixels: vec![0u8; w * h * 3],
            w,
            h,
        }
    }

    fn put(&mut self, x: usize, y: usize, c: [u8; 3]) {
        if x >= self.w || y >= self.h {
            return;
        }
        let i = (y * self.w + x) * 3;
        self.pixels[i..i + 3].copy_from_slice(&c);
    }

    fn rect(&mut self, x0: usize, y0: usize, w: usize, h: usize, c: [u8; 3]) {
        for y in y0..(y0 + h).min(self.h) {
            for x in x0..(x0 + w).min(self.w) {
                self.put(x, y, c);
            }
        }
    }

    /// Uma linha de "texto": blocos escuros de larguras variadas, como palavras.
    fn text_line(&mut self, x0: usize, y: usize, width: usize, seed: u32) {
        let mut s = seed.wrapping_mul(2654435761).wrapping_add(1);
        let mut x = x0;
        while x < x0 + width {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            let word = 12 + (s >> 27) as usize * 4;
            let gap = 5 + ((s >> 20) & 3) as usize;
            if x + word > x0 + width {
                break;
            }
            self.rect(x, y, word, 9, [40, 40, 45]);
            x += word + gap;
        }
    }

    fn render(&mut self, scenario: Scenario, frame: u32) {
        let (w, h) = (self.w, self.h);

        if scenario == Scenario::Video {
            // Ruído colorido que muda por completo a cada quadro. É mais duro
            // que vídeo de verdade (que tem correlação entre quadros), então
            // serve de teto, não de estimativa.
            let mut s = frame.wrapping_mul(2654435761).wrapping_add(7);
            for y in 0..h {
                for x in 0..w {
                    s = s.wrapping_mul(1664525).wrapping_add(1013904223);
                    let n = (s >> 26) as u8;
                    self.put(
                        x,
                        y,
                        [
                            ((x * 200 / w) as u8).saturating_add(n),
                            ((y * 200 / h) as u8).saturating_add(n),
                            140u8.saturating_add(n),
                        ],
                    );
                }
            }
            return;
        }

        // Papel de parede e barra de tarefas.
        for y in 0..h {
            for x in 0..w {
                let c = [
                    (30 + x * 40 / w) as u8,
                    (35 + y * 30 / h) as u8,
                    (70 + x * 50 / w) as u8,
                ];
                self.put(x, y, c);
            }
        }
        self.rect(0, h - 44, w, 44, [24, 24, 28]);
        for i in 0..8 {
            self.rect(16 + i * 52, h - 36, 30, 28, [70, 80, 110]);
        }

        // Janela: moldura, barra de título e área de conteúdo.
        let (wx, wy) = (90, 60);
        let (ww, wh) = (w - 230, h - 140);
        self.rect(wx, wy, ww, wh, [250, 250, 252]);
        self.rect(wx, wy, ww, 34, [225, 228, 235]);
        self.rect(wx + ww - 30, wy + 11, 12, 12, [220, 90, 90]);

        // Conteúdo de texto. O deslocamento vertical é o que cria a rolagem.
        let scroll = match scenario {
            Scenario::Scrolling => (frame as usize * 6) % 24,
            _ => 0,
        };
        let lines = (wh - 60) / 24;
        for l in 0..lines {
            let y = wy + 52 + l * 24 - scroll;
            if y < wy + 40 || y + 9 > wy + wh {
                continue;
            }
            let seed = match scenario {
                Scenario::Scrolling => (l + frame as usize / 4) as u32,
                _ => l as u32,
            };
            let width = if l % 7 == 6 { 420 } else { ww - 80 };
            self.text_line(wx + 40, y, width, seed + 1);
        }

        // Digitando: uma linha cresce caractere a caractere.
        if scenario == Scenario::Typing {
            let caret = (frame as usize * 7) % 600;
            self.rect(wx + 40, wy + 52 + 6 * 24, caret, 9, [40, 40, 45]);
            self.rect(wx + 42 + caret, wy + 50 + 6 * 24, 2, 13, [20, 90, 200]);
        }

        // Cursor do mouse: move-se sempre, em todos os cenários. É ele que
        // impede o JPEG de aproveitar a deduplicação.
        let cx = 200 + ((frame as usize * 11) % (w / 2));
        let cy = 150 + ((frame as usize * 7) % (h / 2));
        self.rect(cx, cy, 12, 18, [10, 10, 10]);
        self.rect(cx + 1, cy + 1, 9, 14, [255, 255, 255]);
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Scenario {
    /// Tela parada, só o cursor se mexe (ler um documento).
    IdleCursor,
    /// Digitando: uma região pequena muda.
    Typing,
    /// Rolando a página: quase tudo muda.
    Scrolling,
    /// Pior caso: ruído em tela cheia, tudo muda a cada quadro.
    Video,
}

impl Scenario {
    fn label(self) -> &'static str {
        match self {
            Scenario::IdleCursor => "Parada + cursor",
            Scenario::Typing => "Digitando",
            Scenario::Scrolling => "Rolando",
            Scenario::Video => "Ruído (teto)",
        }
    }
}

// --- hash usado hoje pela deduplicação ----------------------------------------

fn frame_hash(bytes: &[u8]) -> u64 {
    let mut acc: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        acc ^= *b as u64;
        acc = acc.wrapping_mul(0x100_0000_01b3);
    }
    acc
}

/// PSNR em dB entre a imagem original e a reconstruída (RGB, 8 bits).
///
/// Serve para provar que a economia de banda não veio às custas de virar
/// borrão. Como referência grosseira: acima de 40 dB é difícil de distinguir a
/// olho, 30–40 dB é bom, abaixo de 30 dB começa a incomodar.
fn psnr(original: &[u8], reconstructed: &[u8]) -> f64 {
    let n = original.len().min(reconstructed.len());
    let mut sum_sq = 0f64;
    for i in 0..n {
        let d = original[i] as f64 - reconstructed[i] as f64;
        sum_sq += d * d;
    }
    let mse = sum_sq / n as f64;
    if mse == 0.0 {
        return f64::INFINITY;
    }
    10.0 * (255.0f64 * 255.0 / mse).log10()
}

struct Measurement {
    ms_per_frame: f64,
    total_bytes: usize,
    sent_frames: u32,
    psnr_db: f64,
}

impl Measurement {
    fn mbps(&self, total_frames: usize) -> f64 {
        self.total_bytes as f64 * 8.0 * FPS as f64 / total_frames as f64 / 1_000_000.0
    }

    fn kb_per_sent_frame(&self) -> f64 {
        self.total_bytes as f64 / self.sent_frames.max(1) as f64 / 1024.0
    }
}

/// Caminho de hoje: JPEG por quadro, pulando quadros idênticos ao anterior.
fn run_jpeg(clip: &Clip) -> Measurement {
    let (w, h) = (clip.w as u32, clip.h as u32);
    let mut total = 0usize;
    let mut sent = 0u32;
    let mut last_hash = 0u64;
    let mut encoded: Vec<Option<Vec<u8>>> = Vec::new();

    let start = Instant::now();
    for rgb in &clip.frames {
        let hash = frame_hash(rgb);
        if hash == last_hash {
            encoded.push(None); // deduplicação: nada a codificar nem a enviar
            continue;
        }
        last_hash = hash;
        let mut out = Vec::new();
        JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY)
            .encode(rgb, w, h, ExtendedColorType::Rgb8)
            .unwrap();
        total += out.len();
        sent += 1;
        encoded.push(Some(out));
    }
    let elapsed = start.elapsed();

    // Qualidade: decodifica de volta e compara com o original (fora do relógio).
    let mut psnr_sum = 0f64;
    let mut psnr_n = 0u32;
    for (rgb, jpeg) in clip.frames.iter().zip(&encoded) {
        let Some(jpeg) = jpeg else { continue };
        let decoded = image::load_from_memory(jpeg).unwrap().to_rgb8();
        psnr_sum += psnr(rgb, decoded.as_raw());
        psnr_n += 1;
    }

    Measurement {
        ms_per_frame: elapsed.as_secs_f64() * 1000.0 / clip.frames.len() as f64,
        total_bytes: total,
        sent_frames: sent,
        psnr_db: psnr_sum / psnr_n.max(1) as f64,
    }
}

/// Caminho proposto: H.264, perfil de conteúdo de tela, tempo real.
///
/// `skip_frames` é o padrão do openh264: sob pressão de banda ele **descarta
/// quadros inteiros** em vez de baixar a qualidade. Medimos os dois modos
/// porque a diferença decide o comportamento em rede ruim.
fn run_h264(clip: &Clip, skip_frames: bool, target_bps: u32) -> (Measurement, u32) {
    let config = EncoderConfig::new()
        .usage_type(UsageType::ScreenContentRealTime)
        .skip_frames(skip_frames)
        .max_frame_rate(FrameRate::from_hz(FPS as f32))
        .bitrate(BitRate::from_bps(target_bps));
    let mut encoder = Encoder::with_api_config(OpenH264API::from_source(), config).unwrap();
    let mut yuv = YUVBuffer::new(clip.w, clip.h);

    let mut total = 0usize;
    let mut sent = 0u32;
    let mut keyframes = 0u32;
    let mut packets: Vec<Vec<u8>> = Vec::new();

    let start = Instant::now();
    for (i, rgb) in clip.frames.iter().enumerate() {
        yuv.read_rgb8(RgbSliceU8::new(rgb, (clip.w, clip.h)));
        let ts = Timestamp::from_millis(i as u64 * 1000 / FPS as u64);
        let bitstream = encoder.encode_at(&yuv, ts).unwrap();
        if bitstream.frame_type() == FrameType::IDR {
            keyframes += 1;
        }
        let bytes = bitstream.to_vec();
        if !bytes.is_empty() {
            total += bytes.len();
            sent += 1;
        }
        packets.push(bytes);
    }
    let elapsed = start.elapsed();

    // Qualidade: decodifica o fluxo inteiro e compara quadro a quadro. Fora do
    // relógio — mede-se o custo de codificar, não o de decodificar (que
    // acontece no iPhone, por hardware).
    let mut decoder = openh264::decoder::Decoder::new().unwrap();
    let mut rgb_out = vec![0u8; clip.w * clip.h * 3];
    let mut psnr_sum = 0f64;
    let mut psnr_n = 0u32;
    for (original, packet) in clip.frames.iter().zip(&packets) {
        if packet.is_empty() {
            continue;
        }
        if let Ok(Some(decoded)) = decoder.decode(packet) {
            decoded.write_rgb8(&mut rgb_out);
            psnr_sum += psnr(original, &rgb_out);
            psnr_n += 1;
        }
    }

    (
        Measurement {
            ms_per_frame: elapsed.as_secs_f64() * 1000.0 / clip.frames.len() as f64,
            total_bytes: total,
            sent_frames: sent,
            psnr_db: psnr_sum / psnr_n.max(1) as f64,
        },
        keyframes,
    )
}

/// Carrega quadros PNG de uma pasta, em ordem de nome.
///
/// Todos precisam ter o mesmo tamanho; dimensões ímpares são cortadas em um
/// pixel porque o H.264 exige múltiplos de 2.
fn load_clip(dir: &str) -> Result<Clip, String> {
    let mut paths: Vec<_> = std::fs::read_dir(dir)
        .map_err(|e| format!("não consegui ler {dir}: {e}"))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("png")))
        .collect();
    paths.sort();
    if paths.is_empty() {
        return Err(format!("nenhum .png em {dir}"));
    }

    let mut frames = Vec::new();
    let (mut w, mut h) = (0usize, 0usize);
    for path in &paths {
        let img = image::open(path)
            .map_err(|e| format!("{}: {e}", path.display()))?
            .to_rgb8();
        let (iw, ih) = (img.width() as usize & !1, img.height() as usize & !1);
        if w == 0 {
            (w, h) = (iw, ih);
        } else if (iw, ih) != (w, h) {
            return Err(format!(
                "{} tem {iw}x{ih}, mas os anteriores são {w}x{h}",
                path.display()
            ));
        }
        // Corta para dimensões pares, copiando linha a linha.
        let src = img.as_raw();
        let mut rgb = Vec::with_capacity(w * h * 3);
        for y in 0..h {
            let row = y * img.width() as usize * 3;
            rgb.extend_from_slice(&src[row..row + w * 3]);
        }
        frames.push(rgb);
    }

    let name = std::path::Path::new(dir)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| dir.to_string());
    Ok(Clip {
        label: format!("{name}/ ({} reais)", frames.len()),
        frames,
        w,
        h,
    })
}

fn synthetic_clip(scenario: Scenario, w: usize, h: usize) -> Clip {
    // Gera a sequência inteira antes de medir: o custo de desenhar a tela
    // sintética não pode entrar na conta de nenhum dos dois codecs.
    let mut desktop = Desktop::new(w, h);
    let frames = (0..FRAMES)
        .map(|f| {
            desktop.render(scenario, f);
            desktop.pixels.clone()
        })
        .collect();
    Clip {
        frames,
        w,
        h,
        label: scenario.label().to_string(),
    }
}

fn report(clip: &Clip) {
    let n = clip.frames.len();
    let jpeg = run_jpeg(clip);
    let (h264, keyframes) = run_h264(clip, true, TARGET_BPS);

    for (name, m) in [("JPEG q50", &jpeg), ("H.264", &h264)] {
        println!(
            "{:<22} {:>12} {:>9.1} {:>8.2} {:>9.1} {:>9} {:>8.1}",
            if name == "JPEG q50" { &clip.label } else { "" },
            name,
            m.ms_per_frame,
            m.mbps(n),
            m.kb_per_sent_frame(),
            m.sent_frames,
            m.psnr_db,
        );
    }
    println!(
        "{:<22} {:>12} {:.0}x menos banda, {:.1}x o custo de CPU ({keyframes} keyframe(s))",
        "",
        "→",
        jpeg.mbps(n) / h264.mbps(n).max(0.0001),
        h264.ms_per_frame / jpeg.ms_per_frame.max(0.0001),
    );

    // Quando o encoder descartou quadros para caber no teto, mede-se de novo
    // sem descarte: é a diferença entre "trava" e "borra" em rede ruim.
    if (h264.sent_frames as usize) < n {
        let (full, _) = run_h264(clip, false, TARGET_BPS);
        println!(
            "{:<22} {:>12} {:>9.1} {:>8.2} {:>9.1} {:>9} {:>8.1}",
            "",
            "H.264 s/skip",
            full.ms_per_frame,
            full.mbps(n),
            full.kb_per_sent_frame(),
            full.sent_frames,
            full.psnr_db,
        );
    }
    println!();
}

fn main() {
    let arg = std::env::args().nth(1);

    println!(
        "Spike S2 — H.264 (openh264) contra o JPEG atual\n\
         {FPS} fps, alvo {} kbps, JPEG q{JPEG_QUALITY} com deduplicação\n",
        TARGET_BPS / 1000
    );
    println!(
        "{:<22} {:>12} {:>9} {:>8} {:>9} {:>9} {:>8}",
        "Cenário", "codec", "ms/frame", "Mbps", "KB/frame", "enviados", "PSNR dB"
    );
    println!("{}", "-".repeat(82));

    match arg {
        Some(dir) => match load_clip(&dir) {
            Ok(clip) => report(&clip),
            Err(e) => {
                eprintln!("Erro: {e}");
                std::process::exit(1);
            }
        },
        None => {
            for scenario in [
                Scenario::IdleCursor,
                Scenario::Typing,
                Scenario::Scrolling,
                Scenario::Video,
            ] {
                report(&synthetic_clip(scenario, 1280, 720));
            }
            println!(
                "Estes são quadros sintéticos, mais simples que uma tela real —\n\
                 os números do H.264 estão otimistas. Para medir de verdade:\n\
                 \n\
                 \x20 cargo run --release --example capture_frames -- 90 quadros/\n\
                 \x20 cargo run --release --example bench_h264 -- quadros/"
            );
        }
    }
}
