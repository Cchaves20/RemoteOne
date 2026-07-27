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

/// Resultado de uma captura com deduplicação.
///
/// `jpeg` é `None` quando a tela está idêntica ao frame anterior; `hash` deve
/// ser guardado pelo chamador e devolvido na chamada seguinte.
#[derive(Debug)]
pub struct Frame {
    pub jpeg: Option<Vec<u8>>,
    pub hash: u64,
}

/// Valor a passar como `last_hash` quando ainda não há frame anterior —
/// [`frame_hash`] nunca devolve `0`, então o primeiro frame sempre é enviado.
pub const NO_FRAME: u64 = 0;

/// Hash rápido (FNV-1a) do conteúdo do frame, para detectar tela parada.
///
/// Não precisa ser criptográfico: um falso positivo apenas manteria um frame
/// desatualizado na tela, e 64 bits tornam isso improvável na prática.
fn frame_hash(bytes: &[u8]) -> u64 {
    let mut acc: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        acc ^= *b as u64;
        acc = acc.wrapping_mul(0x100_0000_01b3);
    }
    // Reserva o 0 para o sentinela NO_FRAME.
    if acc == NO_FRAME {
        1
    } else {
        acc
    }
}

/// Converte um buffer RGBA para RGB e reduz para `max_width`, mantendo a
/// proporção.
///
/// Usa `thumbnail` (filtro de caixa) em vez de `resize(Triangle)`: medido em
/// ~17 ms contra ~83 ms num frame 1080p→720p, com qualidade equivalente para
/// redução — era, de longe, a etapa mais cara do pipeline.
fn rgba_to_rgb_scaled(
    rgba: Vec<u8>,
    width: u32,
    height: u32,
    max_width: u32,
) -> Result<RgbImage, String> {
    let mut rgb = Vec::with_capacity((width * height * 3) as usize);
    for px in rgba.chunks_exact(4) {
        rgb.extend_from_slice(&px[0..3]);
    }
    let image = RgbImage::from_raw(width, height, rgb).ok_or("buffer de imagem inválido")?;

    Ok(if width > max_width {
        let new_height = (height * max_width / width).max(1);
        imageops::thumbnail(&image, max_width, new_height)
    } else {
        image
    })
}

/// Converte, reduz e codifica em JPEG.
fn rgba_to_jpeg(
    rgba: Vec<u8>,
    width: u32,
    height: u32,
    max_width: u32,
    quality: u8,
) -> Result<Vec<u8>, String> {
    let image = rgba_to_rgb_scaled(rgba, width, height, max_width)?;
    encode_jpeg(image.as_raw(), image.width(), image.height(), quality)
}

/// Captura a tela em RGBA, devolvendo `(pixels, largura, altura)`.
#[cfg(windows)]
fn capture_rgba() -> Result<(Vec<u8>, u32, u32), String> {
    use xcap::Monitor;

    let monitors = Monitor::all().map_err(|e| e.to_string())?;
    let monitor = monitors
        .into_iter()
        .next()
        .ok_or("nenhum monitor encontrado")?;
    let image = monitor.capture_image().map_err(|e| e.to_string())?;
    let (width, height) = (image.width(), image.height());
    Ok((image.into_raw(), width, height))
}

/// Stub (não-Windows): gera um frame sintético — um gradiente com uma faixa
/// vertical que se move com o tempo, para dar movimento visível ao testar.
#[cfg(not(windows))]
fn capture_rgba() -> Result<(Vec<u8>, u32, u32), String> {
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
    Ok((rgba, width, height))
}

/// Captura a tela e devolve o JPEG pronto.
pub fn capture_frame(max_width: u32, quality: u8) -> Result<Vec<u8>, String> {
    let (rgba, width, height) = capture_rgba()?;
    rgba_to_jpeg(rgba, width, height, max_width, quality)
}

/// Captura a tela e só codifica o JPEG se o conteúdo mudou desde `last_hash`.
///
/// Numa tela parada (lendo um documento, vídeo pausado, computador ocioso) isso
/// poupa a codificação — a etapa mais cara depois do redimensionamento — e todo
/// o tráfego do frame, já que o app continua exibindo a imagem idêntica que já
/// tem. O hash é calculado sobre a imagem **já reduzida**, então o custo é
/// proporcional ao que de fato seria enviado.
pub fn capture_frame_dedup(max_width: u32, quality: u8, last_hash: u64) -> Result<Frame, String> {
    let (rgba, width, height) = capture_rgba()?;
    let image = rgba_to_rgb_scaled(rgba, width, height, max_width)?;
    let hash = frame_hash(image.as_raw());
    if hash == last_hash {
        return Ok(Frame { jpeg: None, hash });
    }
    let jpeg = encode_jpeg(image.as_raw(), image.width(), image.height(), quality)?;
    Ok(Frame {
        jpeg: Some(jpeg),
        hash,
    })
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
    fn dedup_sends_the_first_frame() {
        let frame = capture_frame_dedup(1280, 60, NO_FRAME).unwrap();
        assert!(is_jpeg(frame.jpeg.as_deref().unwrap()));
        assert_ne!(frame.hash, NO_FRAME);
    }

    #[test]
    fn dedup_skips_an_unchanged_screen() {
        // O stub anima com o relógio, então não dá para forçar dois frames
        // iguais: valida a regra nos dois desfechos possíveis.
        let first = capture_frame_dedup(1280, 60, NO_FRAME).unwrap();
        let again = capture_frame_dedup(1280, 60, first.hash).unwrap();
        if again.hash == first.hash {
            assert!(again.jpeg.is_none(), "tela igual não deve gastar encode");
        } else {
            assert!(again.jpeg.is_some(), "tela diferente precisa enviar frame");
        }
    }

    #[test]
    fn dedup_of_a_frozen_screen_skips_the_encode() {
        // Caminho puro, sem o stub animado: o mesmo buffer duas vezes.
        let rgba = vec![90u8; (64 * 32 * 4) as usize];
        let image = rgba_to_rgb_scaled(rgba.clone(), 64, 32, 64).unwrap();
        let hash = frame_hash(image.as_raw());
        let same = rgba_to_rgb_scaled(rgba, 64, 32, 64).unwrap();
        assert_eq!(frame_hash(same.as_raw()), hash);
    }

    #[test]
    fn frame_hash_reacts_to_content_and_avoids_the_sentinel() {
        assert_ne!(frame_hash(&[1, 2, 3]), frame_hash(&[1, 2, 4]));
        assert_eq!(frame_hash(&[1, 2, 3]), frame_hash(&[1, 2, 3]));
        assert_ne!(frame_hash(&[]), NO_FRAME);
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
