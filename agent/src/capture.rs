//! Captura da tela e codificação em JPEG (Etapa 7).
//!
//! A captura real usa o `xcap` e existe apenas no Windows — a única plataforma
//! com tela para testar aqui. No Linux/macOS um stub gera um frame sintético,
//! o que permite validar todo o pipeline (agente → backend → app) sem uma
//! sessão gráfica. A codificação JPEG é compartilhada e testável em qualquer
//! plataforma.

use image::codecs::jpeg::JpegEncoder;
use image::{imageops, ExtendedColorType, RgbImage};

/// Codifica pixels RGB (8 bits/canal) em JPEG.
pub fn encode_jpeg(rgb: &[u8], width: u32, height: u32, quality: u8) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut out, quality);
    encoder
        .encode(rgb, width, height, ExtendedColorType::Rgb8)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

/// Converte um buffer RGBA para RGB, reduz para `max_width` (mantendo a
/// proporção) e codifica em JPEG.
fn rgba_to_jpeg(
    rgba: Vec<u8>,
    width: u32,
    height: u32,
    max_width: u32,
    quality: u8,
) -> Result<Vec<u8>, String> {
    let mut rgb = Vec::with_capacity((width * height * 3) as usize);
    for px in rgba.chunks_exact(4) {
        rgb.extend_from_slice(&px[0..3]);
    }
    let image = RgbImage::from_raw(width, height, rgb).ok_or("buffer de imagem inválido")?;

    let image = if width > max_width {
        let new_height = height * max_width / width;
        imageops::resize(
            &image,
            max_width,
            new_height,
            imageops::FilterType::Triangle,
        )
    } else {
        image
    };

    encode_jpeg(image.as_raw(), image.width(), image.height(), quality)
}

#[cfg(windows)]
pub fn capture_frame(max_width: u32, quality: u8) -> Result<Vec<u8>, String> {
    use xcap::Monitor;

    let monitors = Monitor::all().map_err(|e| e.to_string())?;
    let monitor = monitors
        .into_iter()
        .next()
        .ok_or("nenhum monitor encontrado")?;
    let image = monitor.capture_image().map_err(|e| e.to_string())?;
    let (width, height) = (image.width(), image.height());
    rgba_to_jpeg(image.into_raw(), width, height, max_width, quality)
}

/// Stub (não-Windows): gera um frame sintético — um gradiente com uma faixa
/// vertical que se move com o tempo, para dar movimento visível ao testar.
#[cfg(not(windows))]
pub fn capture_frame(max_width: u32, quality: u8) -> Result<Vec<u8>, String> {
    let (width, height) = (640u32, 360u32);
    let ticks = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let bar = (ticks / 16 % width as u128) as i64;

    let mut rgba = Vec::with_capacity((width * height * 4) as usize);
    for y in 0..height {
        for x in 0..width {
            let r = (x * 255 / width) as u8;
            let g = (y * 255 / height) as u8;
            let b = if (x as i64 - bar).abs() < 8 { 255 } else { 64 };
            rgba.extend_from_slice(&[r, g, b, 255]);
        }
    }
    rgba_to_jpeg(rgba, width, height, max_width, quality)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn is_jpeg(bytes: &[u8]) -> bool {
        bytes.len() > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    }

    #[test]
    fn encode_jpeg_produces_jpeg_magic() {
        let rgb = vec![128u8; 8 * 8 * 3];
        let jpeg = encode_jpeg(&rgb, 8, 8, 70).unwrap();
        assert!(is_jpeg(&jpeg));
    }

    #[test]
    fn capture_frame_returns_jpeg() {
        // No stub (Linux) captura o frame sintético; garante o pipeline.
        let jpeg = capture_frame(1280, 60).unwrap();
        assert!(is_jpeg(&jpeg));
    }

    #[test]
    fn downscale_reduces_dimensions() {
        // Uma imagem 100x50 reduzida para max_width 40 vira 40x20.
        let rgba = vec![10u8; (100 * 50 * 4) as usize];
        let jpeg = rgba_to_jpeg(rgba, 100, 50, 40, 60).unwrap();
        let decoded = image::load_from_memory(&jpeg).unwrap();
        assert_eq!(decoded.width(), 40);
        assert_eq!(decoded.height(), 20);
    }
}
