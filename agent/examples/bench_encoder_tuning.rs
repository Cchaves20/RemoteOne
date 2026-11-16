//! Mede o **custo de tempo** de cada ajuste do codificador.
//!
//! Existe porque o S2 mediu banda e qualidade, mas não tempo por configuração —
//! e no primeiro teste em máquina real a codificação apareceu em 60–105 ms por
//! quadro, contra 23 ms medidos aqui. A diferença tinha que ser explicada com
//! número, não com palpite.
//!
//! ```bash
//! cargo run --release --example bench_encoder_tuning
//! ```

use openh264::encoder::{
    BitRate, Complexity, Encoder, EncoderConfig, FrameRate, QpRange, UsageType,
};
use openh264::formats::{RgbSliceU8, YUVBuffer};
use openh264::{OpenH264API, Timestamp};
use std::time::Instant;

const FPS: u32 = 30;
const FRAMES: u32 = 40;
const TARGET_BPS: u32 = 1_500_000;

/// Uma tela de trabalho com texto e um retângulo em movimento.
fn frame(w: usize, h: usize, step: u32) -> Vec<u8> {
    let mut rgb = vec![235u8; w * h * 3];
    // Linhas de "texto".
    let mut s = 12345u32;
    for row in 0..(h / 22) {
        let y = 20 + row * 22;
        if y + 9 >= h {
            break;
        }
        let mut x = 60;
        while x < w - 80 {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            let word = 14 + (s >> 27) as usize * 4;
            if x + word >= w - 80 {
                break;
            }
            for yy in y..(y + 9) {
                for xx in x..(x + word) {
                    let i = (yy * w + xx) * 3;
                    rgb[i..i + 3].copy_from_slice(&[45, 45, 50]);
                }
            }
            x += word + 6;
        }
    }
    // Algo que se move, para haver diferença entre quadros.
    let x0 = (step as usize * 11) % (w - 60);
    for y in (h / 3)..(h / 3 + 80).min(h) {
        for x in x0..(x0 + 60) {
            let i = (y * w + x) * 3;
            rgb[i..i + 3].copy_from_slice(&[30, 90, 170]);
        }
    }
    rgb
}

struct Config {
    label: &'static str,
    complexity: Complexity,
    qp: Option<QpRange>,
    threads: Option<u16>,
}

fn measure(cfg: &Config, w: usize, h: usize, frames: &[Vec<u8>]) -> (f64, f64) {
    let mut config = EncoderConfig::new()
        .usage_type(UsageType::ScreenContentRealTime)
        .skip_frames(false)
        .max_frame_rate(FrameRate::from_hz(FPS as f32))
        .bitrate(BitRate::from_bps(TARGET_BPS))
        .complexity(cfg.complexity);
    if let Some(qp) = cfg.qp {
        config = config.qp(qp);
    }
    if let Some(threads) = cfg.threads {
        config = config.num_threads(threads);
    }
    let mut encoder = Encoder::with_api_config(OpenH264API::from_source(), config).unwrap();
    let mut yuv = YUVBuffer::new(w, h);

    let mut bytes = 0usize;
    let start = Instant::now();
    for (i, rgb) in frames.iter().enumerate() {
        yuv.read_rgb8(RgbSliceU8::new(rgb, (w, h)));
        let ts = Timestamp::from_millis(i as u64 * 1000 / FPS as u64);
        bytes += encoder.encode_at(&yuv, ts).unwrap().to_vec().len();
    }
    let ms = start.elapsed().as_secs_f64() * 1000.0 / frames.len() as f64;
    (ms, bytes as f64 / frames.len() as f64 / 1024.0)
}

fn main() {
    let cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    println!("Ajustes do codificador — {cores} núcleo(s) disponível(is)\n");

    let configs = [
        Config {
            label: "atual (Medium, QP 20-42)",
            complexity: Complexity::Medium,
            qp: Some(QpRange::new(20, 42)),
            threads: None,
        },
        Config {
            label: "sem piso de QP (Medium)",
            complexity: Complexity::Medium,
            qp: None,
            threads: None,
        },
        Config {
            label: "Low + QP 20-42",
            complexity: Complexity::Low,
            qp: Some(QpRange::new(20, 42)),
            threads: None,
        },
        Config {
            label: "Low, sem piso de QP",
            complexity: Complexity::Low,
            qp: None,
            threads: None,
        },
        Config {
            label: "Low + threads = núcleos",
            complexity: Complexity::Low,
            qp: None,
            threads: Some(cores as u16),
        },
        Config {
            label: "Medium + threads = núcleos",
            complexity: Complexity::Medium,
            qp: None,
            threads: Some(cores as u16),
        },
    ];

    // Duas resoluções: a do preset "Equilibrado" e a do "Nítido" em 3:2, que é a
    // proporção da Surface — bem mais pixels do que 720p.
    for (w, h, nome) in [(1280, 720, "1280x720"), (1600, 1066, "1600x1066 (3:2)")] {
        let frames: Vec<Vec<u8>> = (0..FRAMES).map(|i| frame(w, h, i)).collect();
        println!("--- {nome} ({:.1} Mpx) ---", (w * h) as f64 / 1e6);
        println!("{:<30} {:>10} {:>11}", "config", "ms/quadro", "KB/quadro");
        for cfg in &configs {
            let (ms, kb) = measure(cfg, w, h, &frames);
            println!("{:<30} {ms:>10.1} {kb:>11.1}", cfg.label);
        }
        println!();
    }
}
