//! Grava uma sequência de quadros reais da tela, para alimentar o
//! `bench_h264` com conteúdo de verdade em vez do desktop sintético.
//!
//! Rode no Windows (onde a captura é real), mexendo na tela enquanto grava —
//! rolar uma página, digitar, mover o mouse:
//!
//! ```bash
//! cargo run --release --example capture_frames -- 90 quadros/
//! ```
//!
//! Depois passe a pasta ao benchmark:
//!
//! ```bash
//! cargo run --release --example bench_h264 -- quadros/
//! ```
//!
//! Os PNG são sem perdas de propósito: se fossem JPEG, a medição estaria
//! comparando codecs sobre uma imagem já degradada.

use std::path::PathBuf;
use std::time::{Duration, Instant};

const MAX_WIDTH: u32 = 1280;
const FPS: u64 = 30;

fn main() {
    let mut args = std::env::args().skip(1);
    let count: u32 = args
        .next()
        .and_then(|a| a.parse().ok())
        .unwrap_or(90);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| "quadros".into()));

    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("Não consegui criar {}: {e}", dir.display());
        std::process::exit(1);
    }

    println!(
        "Gravando {count} quadros a {FPS} fps ({:.1}s) em {} — mexa na tela.",
        count as f64 / FPS as f64,
        dir.display()
    );

    let interval = Duration::from_millis(1000 / FPS);
    let mut written = 0u32;
    for i in 0..count {
        let started = Instant::now();
        match remoteone_agent::capture::capture_rgb(MAX_WIDTH) {
            Ok((rgb, w, h)) => {
                let path = dir.join(format!("quadro_{i:04}.png"));
                match image::RgbImage::from_raw(w, h, rgb) {
                    Some(img) => match img.save(&path) {
                        Ok(()) => written += 1,
                        Err(e) => eprintln!("Falha ao gravar {}: {e}", path.display()),
                    },
                    None => eprintln!("Quadro {i} com tamanho inesperado"),
                }
            }
            Err(e) => eprintln!("Falha ao capturar o quadro {i}: {e}"),
        }
        if let Some(rest) = interval.checked_sub(started.elapsed()) {
            std::thread::sleep(rest);
        }
    }

    println!("Pronto: {written} quadros em {}", dir.display());
    println!("Agora rode: cargo run --release --example bench_h264 -- {}", dir.display());
}
