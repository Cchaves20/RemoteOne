use image::{imageops, RgbImage};
use std::time::Instant;

fn main() {
    let (w, h) = (1920u32, 1080u32);
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            rgb.extend_from_slice(&[(x % 251) as u8, (y % 253) as u8, ((x ^ y) % 247) as u8]);
        }
    }
    let img = RgbImage::from_raw(w, h, rgb).unwrap();

    for (nome, f) in [
        ("Triangle (atual)", imageops::FilterType::Triangle),
        ("Nearest", imageops::FilterType::Nearest),
    ] {
        let t = Instant::now();
        let out = imageops::resize(&img, 1280, 720, f);
        println!(
            "{:<18} {:>7.1} ms  ({}x{})",
            nome,
            t.elapsed().as_secs_f64() * 1000.0,
            out.width(),
            out.height()
        );
    }
    let t = Instant::now();
    let out = imageops::thumbnail(&img, 1280, 720);
    println!(
        "{:<18} {:>7.1} ms  ({}x{})",
        "thumbnail (box)",
        t.elapsed().as_secs_f64() * 1000.0,
        out.width(),
        out.height()
    );

    // Hash do buffer, para detectar tela parada.
    let t = Instant::now();
    let mut acc: u64 = 1469598103934665603;
    for b in out.as_raw().iter() {
        acc ^= *b as u64;
        acc = acc.wrapping_mul(1099511628211);
    }
    println!(
        "{:<18} {:>7.1} ms",
        "hash do frame",
        t.elapsed().as_secs_f64() * 1000.0
    );
}
