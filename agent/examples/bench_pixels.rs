//! Custo de preparar um quadro: da captura crua ao buffer que o codificador lê.
//!
//! Compara o caminho antigo (converter e depois reduzir com o filtro do
//! `image`) com o atual (reduzir com SIMD e depois converter).
use std::time::Instant;
use image::{imageops, RgbImage};
use remoteone_agent::capture::{target_size, Scaler};

/// Uma "tela": fundo claro, barra de janela e traços finos do tamanho de texto.
fn tela(w: u32, h: u32) -> Vec<u8> {
    let mut px = vec![245u8; (w * h * 4) as usize];
    let put = |px: &mut Vec<u8>, x: u32, y: u32, c: [u8; 3]| {
        let i = ((y * w + x) * 4) as usize;
        px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
    };
    for y in 0..h.min(32) { for x in 0..w { put(&mut px, x, y, [40, 44, 60]); } }
    for linha in 0..((h - 60) / 22) {
        let y0 = 50 + linha * 22;
        for coluna in 0..(w / 9) {
            let x0 = 20 + coluna * 9;
            if (coluna * 7 + linha * 3) % 11 == 0 || x0 + 5 >= w { continue; }
            for dy in 0..11u32 {
                if y0 + dy >= h { break; }
                for dx in 0..5u32 {
                    if (dx == 0 || dx == 4 || dy == 5) && x0 + dx < w {
                        put(&mut px, x0 + dx, y0 + dy, [25, 25, 30]);
                    }
                }
            }
        }
    }
    px
}

/// Como era antes: converter o quadro inteiro e reduzir com o filtro do `image`.
fn antigo(rgba: &[u8], w: u32, h: u32, max_w: u32) -> RgbImage {
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for px in rgba.chunks_exact(4) { rgb.extend_from_slice(&px[0..3]); }
    let image = RgbImage::from_raw(w, h, rgb).unwrap();
    if w > max_w {
        let nh = (h * max_w / w).max(1);
        imageops::thumbnail(&image, max_w, nh)
    } else { image }
}

fn melhor<F: FnMut()>(mut f: F, n: u32, lotes: u32) -> f64 {
    let mut best = f64::MAX;
    for _ in 0..lotes {
        let t = Instant::now();
        for _ in 0..n { f(); }
        let ms = t.elapsed().as_secs_f64() * 1000.0 / n as f64;
        if ms < best { best = ms; }
    }
    best
}

fn main() {
    let mut scaler = Scaler::new();
    // O `clone` está dentro do laço medido (o `scale` consome o buffer); o
    // agente não o paga, porque já é dono do quadro que veio da captura.
    let max_w = 1280u32;
    for (w, h, quem) in [
        (1920u32, 1080u32, "Dell G5 / 1080p"),
        (3000, 2000, "Surface Book 3"),
        (2560, 1600, "notebook 16:10"),
    ] {
        let buf = tela(w, h);
        let (dw, dh) = target_size(w, h, max_w);
        let a = melhor(|| { std::hint::black_box(antigo(&buf, w, h, max_w)); }, 10, 5);
        let n = melhor(|| { std::hint::black_box(scaler.scale(buf.clone(), w, h, max_w).unwrap()); }, 10, 5);
        let c = melhor(|| { std::hint::black_box(buf.clone()); }, 10, 5);
        println!("{quem} ({w}x{h} -> {dw}x{dh}): antes {a:.1} ms · agora {n:.1} ms, dos quais {c:.1} ms são a cópia do medidor → {:.1} ms reais ({:.1}x)", n - c, a / (n - c));

        // Qualidade: só compara quando o arredondamento par não muda a altura.
        let ref_img = antigo(&buf, w, h, max_w);
        let novo = scaler.scale(buf.clone(), w, h, max_w).unwrap();
        if ref_img.width() == dw && ref_img.height() == dh {
            let max = ref_img.as_raw().iter().zip(&novo.rgb)
                .map(|(a, b)| (*a as i32 - *b as i32).abs()).max().unwrap_or(0);
            let media: f64 = ref_img.as_raw().iter().zip(&novo.rgb)
                .map(|(a, b)| (*a as i32 - *b as i32).abs() as f64).sum::<f64>() / novo.rgb.len() as f64;
            println!("  diferença de imagem: máx {max} de 255 · média {media:.2}");
        } else {
            println!("  (o filtro antigo daria {}x{}, ímpar - o H.264 recusaria)", ref_img.width(), ref_img.height());
        }
    }
}
