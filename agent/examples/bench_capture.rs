//! Medição temporária do pipeline de captura (não faz parte do agente).
use image::codecs::jpeg::JpegEncoder;
use image::{imageops, ExtendedColorType, RgbImage};
use std::time::Instant;

fn synthetic_rgba(w: u32, h: u32) -> Vec<u8> {
    // Conteúdo com textura (mais parecido com uma tela real do que um plano).
    let mut v = Vec::with_capacity((w * h * 4) as usize);
    let mut s: u32 = 12345;
    for y in 0..h {
        for x in 0..w {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            let n = (s >> 24) as u8 / 8;
            v.extend_from_slice(&[
                (x * 255 / w) as u8 ^ n,
                (y * 255 / h) as u8,
                ((x + y) % 255) as u8 ^ n,
                255,
            ]);
        }
    }
    v
}

fn to_rgb(rgba: &[u8], w: u32, h: u32) -> RgbImage {
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for px in rgba.chunks_exact(4) {
        rgb.extend_from_slice(&px[0..3]);
    }
    RgbImage::from_raw(w, h, rgb).unwrap()
}

fn encode(img: &RgbImage, q: u8) -> Vec<u8> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, q)
        .encode(
            img.as_raw(),
            img.width(),
            img.height(),
            ExtendedColorType::Rgb8,
        )
        .unwrap();
    out
}

fn hash(bytes: &[u8]) -> u64 {
    let mut acc: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        acc ^= *b as u64;
        acc = acc.wrapping_mul(0x100_0000_01b3);
    }
    acc
}

fn timed<T>(label: &str, n: u32, mut f: impl FnMut() -> T) -> T {
    let start = Instant::now();
    let mut last = f();
    for _ in 1..n {
        last = f();
    }
    println!(
        "{label:<34} {:>7.1} ms",
        start.elapsed().as_secs_f64() * 1000.0 / n as f64
    );
    last
}

fn main() {
    let (w, h) = (1920u32, 1080u32);
    let rgba = synthetic_rgba(w, h);
    let n = 10;
    println!("Frame {w}x{h} → 1280px, qualidade 50\n");

    let antigo = timed("ANTES  total (Triangle+encode)", n, || {
        let img = to_rgb(&rgba, w, h);
        let small = imageops::resize(&img, 1280, 720, imageops::FilterType::Triangle);
        encode(&small, 50)
    });

    let novo = timed("DEPOIS total (thumbnail+encode)", n, || {
        let img = to_rgb(&rgba, w, h);
        let small = imageops::thumbnail(&img, 1280, 720);
        let _ = hash(small.as_raw());
        encode(&small, 50)
    });

    timed("DEPOIS tela parada (sem encode)", n, || {
        let img = to_rgb(&rgba, w, h);
        let small = imageops::thumbnail(&img, 1280, 720);
        hash(small.as_raw())
    });

    println!(
        "\nJPEG antes: {} KB | depois: {} KB",
        antigo.len() / 1024,
        novo.len() / 1024
    );
}
