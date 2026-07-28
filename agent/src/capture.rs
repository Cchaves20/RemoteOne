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

/// Fonte de captura, resolvida **uma vez** e reutilizada a cada quadro.
///
/// Existe por causa de um erro medido: a versão anterior chamava
/// `Monitor::all()` — que enumera todos os monitores do sistema — a cada
/// quadro, 30 vezes por segundo. A captura aparecia em 70–94 ms nas
/// estatísticas, mais caro que codificar. Resolver o monitor uma vez e guardá-lo
/// tira esse trabalho do caminho quente.
pub struct Screen {
    #[cfg(windows)]
    monitor: xcap::Monitor,
}

impl Screen {
    /// Resolve o monitor a ser capturado. Chame uma vez por sessão.
    #[cfg(windows)]
    pub fn new() -> Result<Self, String> {
        let monitor = xcap::Monitor::all()
            .map_err(|e| e.to_string())?
            .into_iter()
            .next()
            .ok_or("nenhum monitor encontrado")?;
        Ok(Self { monitor })
    }

    #[cfg(not(windows))]
    pub fn new() -> Result<Self, String> {
        Ok(Self {})
    }

    /// Captura a tela em RGBA, devolvendo `(pixels, largura, altura)`.
    #[cfg(windows)]
    fn grab_rgba(&self) -> Result<(Vec<u8>, u32, u32), String> {
        let image = self.monitor.capture_image().map_err(|e| e.to_string())?;
        let (width, height) = (image.width(), image.height());
        Ok((image.into_raw(), width, height))
    }

    /// Stub (não-Windows): gera um frame sintético — um gradiente com uma faixa
    /// vertical que se move com o tempo, para dar movimento visível ao testar.
    #[cfg(not(windows))]
    fn grab_rgba(&self) -> Result<(Vec<u8>, u32, u32), String> {
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

    /// Captura já reduzida e em RGB, pronta para codificar.
    pub fn frame(&self, max_width: u32) -> Result<CapturedFrame, String> {
        let (rgba, width, height) = self.grab_rgba()?;
        let image = rgba_to_rgb_scaled(rgba, width, height, max_width)?;
        let (width, height) = (image.width(), image.height());
        Ok(CapturedFrame {
            rgb: image.into_raw(),
            width,
            height,
        })
    }
}

/// Captura contínua: a sessão fica **aberta** entre os quadros.
///
/// É a diferença que decidiu o desempenho. O `capture_image()` do xcap é API de
/// captura pontual: por baixo ele cria um dispositivo Direct3D11, um pool de
/// quadros, uma sessão de captura, espera um quadro e destrói tudo — **a cada
/// chamada**. Medido no agente, isso custava 70–100 ms por quadro. O
/// `video_recorder()` abre a sessão uma vez e entrega os quadros por um canal.
struct ContinuousCapture {
    #[cfg(windows)]
    recorder: xcap::VideoRecorder,
    #[cfg(windows)]
    frames: std::sync::mpsc::Receiver<xcap::Frame>,
    /// Quanto esperar por um quadro antes de devolver o controle ao laço.
    timeout: std::time::Duration,
    #[cfg(not(windows))]
    screen: Screen,
}

impl ContinuousCapture {
    #[cfg(windows)]
    fn start(interval: std::time::Duration) -> Result<Self, String> {
        let monitor = xcap::Monitor::all()
            .map_err(|e| e.to_string())?
            .into_iter()
            .next()
            .ok_or("nenhum monitor encontrado")?;
        let (recorder, frames) = monitor
            .video_recorder()
            .map_err(|e| format!("não consegui abrir a captura contínua: {e}"))?;
        recorder
            .start()
            .map_err(|e| format!("não consegui iniciar a captura: {e}"))?;
        Ok(Self {
            recorder,
            frames,
            // Generoso de propósito: numa tela parada o WGC não entrega quadro
            // nenhum, e isso é normal, não erro.
            timeout: (interval * 20).max(std::time::Duration::from_millis(500)),
        })
    }

    #[cfg(not(windows))]
    fn start(interval: std::time::Duration) -> Result<Self, String> {
        Ok(Self {
            timeout: interval,
            screen: Screen::new()?,
        })
    }

    /// Próximo quadro já reduzido, ou `None` se nada chegou no prazo.
    #[cfg(windows)]
    fn next_frame(&mut self, max_width: u32) -> Result<Option<CapturedFrame>, String> {
        use std::sync::mpsc::{RecvTimeoutError, TryRecvError};
        let mut frame = match self.frames.recv_timeout(self.timeout) {
            Ok(frame) => frame,
            Err(RecvTimeoutError::Timeout) => return Ok(None),
            Err(RecvTimeoutError::Disconnected) => {
                return Err("a captura contínua foi encerrada".to_string())
            }
        };
        // O canal do gravador é ilimitado e o WGC entrega no ritmo do monitor,
        // mais rápido do que se consegue reduzir e codificar. Sem esvaziar a
        // fila, cada volta processa o quadro **mais antigo** e o atraso cresce
        // sem limite — reduzir todos seria gastar CPU para exibir imagem velha.
        // O que vale é sempre o último.
        loop {
            match self.frames.try_recv() {
                Ok(newer) => frame = newer,
                // Fila vazia, ou o gravador acabou: em ambos os casos o quadro
                // em mãos é o mais recente que existe. Se foi encerrado, a
                // próxima chamada devolve o erro.
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }
        // `raw` já vem em RGBA: o xcap converte de BGRA antes de entregar.
        let image = rgba_to_rgb_scaled(frame.raw, frame.width, frame.height, max_width)?;
        let (width, height) = (image.width(), image.height());
        Ok(Some(CapturedFrame {
            rgb: image.into_raw(),
            width,
            height,
        }))
    }

    #[cfg(not(windows))]
    fn next_frame(&mut self, max_width: u32) -> Result<Option<CapturedFrame>, String> {
        // O stub é síncrono: gera na hora e respeita o ritmo pedido.
        let frame = self.screen.frame(max_width)?;
        std::thread::sleep(self.timeout);
        Ok(Some(frame))
    }
}

#[cfg(windows)]
impl Drop for ContinuousCapture {
    fn drop(&mut self) {
        if let Err(e) = self.recorder.stop() {
            eprintln!("Falha ao encerrar a captura: {e}");
        }
    }
}

/// Captura pontual: resolve o monitor, captura e descarta.
///
/// Serve para uso de uma vez (exemplos, testes). No caminho quente use
/// [`Screen`], que resolve o monitor só uma vez.
fn capture_rgba() -> Result<(Vec<u8>, u32, u32), String> {
    Screen::new()?.grab_rgba()
}

/// Captura a tela e devolve o JPEG pronto.
pub fn capture_frame(max_width: u32, quality: u8) -> Result<Vec<u8>, String> {
    let (rgba, width, height) = capture_rgba()?;
    rgba_to_jpeg(rgba, width, height, max_width, quality)
}

/// Um quadro capturado e já reduzido, pronto para codificar.
pub struct CapturedFrame {
    pub rgb: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Captura contínua numa thread própria, publicando sempre o quadro mais
/// recente.
///
/// Existe porque capturar e codificar em série faz o ritmo ser a **soma** dos
/// dois. Com a captura correndo à parte, o custo por quadro do laço principal
/// passa a ser só a codificação, e o intervalo fica mais regular — que é o que
/// se percebe como imagem menos travada.
///
/// Só o quadro mais recente é guardado: se a codificação não acompanha, o certo
/// é pular para o presente em vez de acumular atraso.
pub struct FramePump {
    latest: std::sync::Arc<std::sync::Mutex<Option<CapturedFrame>>>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    /// Custo acumulado das capturas e quantas foram, para o resumo periódico.
    /// Sem isto, não há como distinguir "a captura é lenta" de "o codificador é
    /// lento" — e a resposta certa é diferente em cada caso.
    cost: std::sync::Arc<CaptureCost>,
    worker: Option<std::thread::JoinHandle<()>>,
}

/// Custo de captura observado, compartilhado com a thread.
#[derive(Default)]
pub struct CaptureCost {
    micros: std::sync::atomic::AtomicU64,
    frames: std::sync::atomic::AtomicU64,
}

impl CaptureCost {
    /// Média em milissegundos desde a última leitura, zerando os contadores.
    pub fn take_average_ms(&self) -> Option<f64> {
        use std::sync::atomic::Ordering::Relaxed;
        let frames = self.frames.swap(0, Relaxed);
        let micros = self.micros.swap(0, Relaxed);
        if frames == 0 {
            return None;
        }
        Some(micros as f64 / frames as f64 / 1000.0)
    }
}

/// Quanto ainda falta esperar antes de valer a pena preparar outro quadro.
///
/// Zero se nenhum quadro saiu ainda ou se o prazo já passou.
fn remaining_budget(
    published: Option<std::time::Instant>,
    budget: std::time::Duration,
) -> std::time::Duration {
    match published {
        Some(last) => budget.saturating_sub(last.elapsed()),
        None => std::time::Duration::ZERO,
    }
}

impl FramePump {
    /// Começa a capturar em `max_width`, mirando `fps` quadros por segundo.
    ///
    /// Falha se não houver monitor — melhor saber na hora de ligar do que
    /// descobrir por uma thread que captura nada em silêncio.
    pub fn start(max_width: u32, fps: u32) -> Result<Self, String> {
        let latest = std::sync::Arc::new(std::sync::Mutex::new(None));
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let interval = std::time::Duration::from_micros(1_000_000 / fps.clamp(1, 60) as u64);

        let cost = std::sync::Arc::new(CaptureCost::default());
        let slot = std::sync::Arc::clone(&latest);
        let halt = std::sync::Arc::clone(&stop);
        let meter = std::sync::Arc::clone(&cost);
        // A fonte de captura nasce **dentro** da thread e o resultado volta por
        // este canal. Não é preciosismo: no Windows ela guarda handles que não
        // são `Send` e por isso não podem atravessar a fronteira de thread.
        // Assim nasce onde vive, e quem chamou ainda descobre na hora se falhou.
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        // Folga de 25% sobre o intervalo pedido: o quadro fica pronto um pouco
        // antes do tique que vai consumi-lo, sem reduzir dois para entregar um.
        let budget = interval.mul_f32(0.75);
        let worker = std::thread::spawn(move || {
            use std::sync::atomic::Ordering::Relaxed;
            let mut source = match ContinuousCapture::start(interval) {
                Ok(source) => {
                    let _ = ready_tx.send(Ok(()));
                    source
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
            };
            let mut published: Option<std::time::Instant> = None;
            while !halt.load(Relaxed) {
                // Não adianta preparar mais quadros do que o laço principal
                // consome — o excedente é CPU gasta em imagem descartada. Espera
                // o resto do intervalo; os quadros do WGC acumulam no canal e o
                // `next_frame` pega o mais recente.
                let wait = remaining_budget(published, budget);
                if !wait.is_zero() {
                    std::thread::sleep(wait);
                    if halt.load(Relaxed) {
                        break;
                    }
                }
                let started = std::time::Instant::now();
                match source.next_frame(max_width) {
                    Ok(Some(frame)) => {
                        meter
                            .micros
                            .fetch_add(started.elapsed().as_micros() as u64, Relaxed);
                        meter.frames.fetch_add(1, Relaxed);
                        published = Some(std::time::Instant::now());
                        if let Ok(mut guard) = slot.lock() {
                            *guard = Some(frame); // substitui o anterior
                        }
                    }
                    // Sem quadro novo dentro do prazo: a tela não mudou. Volta ao
                    // laço para checar a parada.
                    Ok(None) => {}
                    Err(e) => {
                        eprintln!("Falha ao capturar a tela: {e}");
                        std::thread::sleep(std::time::Duration::from_millis(200));
                    }
                }
            }
        });

        match ready_rx.recv() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err("a thread de captura morreu ao iniciar".to_string()),
        }

        Ok(Self {
            latest,
            stop,
            cost,
            worker: Some(worker),
        })
    }

    /// Retira o quadro mais recente, se houver um ainda não consumido.
    pub fn take(&self) -> Option<CapturedFrame> {
        self.latest.lock().ok()?.take()
    }

    /// Custo médio de captura desde a última leitura.
    pub fn cost(&self) -> &CaptureCost {
        &self.cost
    }
}

impl Drop for FramePump {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// Captura a tela já reduzida, em RGB e sem compressão: `(pixels, largura,
/// altura)`.
///
/// É a saída do pipeline logo antes da codificação. Serve para alimentar um
/// codificador que não seja o JPEG — hoje, a medição do H.264 em
/// `examples/bench_h264.rs`; adiante, o próprio encoder de vídeo.
pub fn capture_rgb(max_width: u32) -> Result<(Vec<u8>, u32, u32), String> {
    let (rgba, width, height) = capture_rgba()?;
    let image = rgba_to_rgb_scaled(rgba, width, height, max_width)?;
    let (w, h) = (image.width(), image.height());
    Ok((image.into_raw(), w, h))
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
    let (width, height) = (image.width(), image.height());
    let frame = CapturedFrame {
        rgb: image.into_raw(),
        width,
        height,
    };
    jpeg_if_changed(&frame, quality, last_hash)
}

/// Codifica um quadro **já capturado e reduzido** em JPEG, ou devolve só o hash
/// se ele é idêntico ao anterior.
///
/// É a metade do [`capture_frame_dedup`] que não captura, para o caminho JPEG
/// poder consumir os quadros do [`FramePump`] em vez de abrir a sua própria
/// captura a cada quadro.
pub fn jpeg_if_changed(
    frame: &CapturedFrame,
    quality: u8,
    last_hash: u64,
) -> Result<Frame, String> {
    let hash = frame_hash(&frame.rgb);
    if hash == last_hash {
        return Ok(Frame { jpeg: None, hash });
    }
    let jpeg = encode_jpeg(&frame.rgb, frame.width, frame.height, quality)?;
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

    fn quadro(valor: u8) -> CapturedFrame {
        CapturedFrame {
            rgb: vec![valor; 8 * 8 * 3],
            width: 8,
            height: 8,
        }
    }

    #[test]
    fn jpeg_if_changed_codifica_quadro_novo() {
        let frame = jpeg_if_changed(&quadro(30), 60, NO_FRAME).unwrap();
        assert!(is_jpeg(frame.jpeg.as_deref().unwrap()));
        assert_ne!(frame.hash, NO_FRAME);
    }

    #[test]
    fn jpeg_if_changed_pula_quadro_identico() {
        let primeiro = jpeg_if_changed(&quadro(30), 60, NO_FRAME).unwrap();
        let repetido = jpeg_if_changed(&quadro(30), 60, primeiro.hash).unwrap();
        assert!(repetido.jpeg.is_none(), "tela igual não deve gastar encode");
        assert_eq!(repetido.hash, primeiro.hash);
        // Conteúdo diferente com o mesmo hash anterior: tem de codificar.
        let outro = jpeg_if_changed(&quadro(200), 60, primeiro.hash).unwrap();
        assert!(outro.jpeg.is_some());
    }

    #[test]
    fn budget_espera_o_intervalo_e_nao_espera_atrasado() {
        use std::time::{Duration, Instant};
        // Nada saiu ainda: prepara na hora.
        assert_eq!(
            remaining_budget(None, Duration::from_millis(100)),
            Duration::ZERO
        );
        // Quadro pronto agora: espera quase o intervalo inteiro.
        let falta = remaining_budget(Some(Instant::now()), Duration::from_millis(100));
        assert!(
            falta > Duration::from_millis(80) && falta <= Duration::from_millis(100),
            "esperou {falta:?}"
        );
        // Já passou do prazo (a codificação demorou): não espera mais nada, e
        // sobretudo não estoura o `Duration`.
        let atrasado = Instant::now() - Duration::from_millis(500);
        assert_eq!(
            remaining_budget(Some(atrasado), Duration::from_millis(100)),
            Duration::ZERO
        );
    }

    #[test]
    fn frame_hash_reacts_to_content_and_avoids_the_sentinel() {
        assert_ne!(frame_hash(&[1, 2, 3]), frame_hash(&[1, 2, 4]));
        assert_eq!(frame_hash(&[1, 2, 3]), frame_hash(&[1, 2, 3]));
        assert_ne!(frame_hash(&[]), NO_FRAME);
    }

    #[test]
    fn pump_entrega_quadros_e_sempre_o_mais_recente() {
        let pump = FramePump::start(1280, 30).unwrap();
        // Espera a thread produzir algo.
        let mut primeiro = None;
        for _ in 0..100 {
            if let Some(frame) = pump.take() {
                primeiro = Some(frame);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let primeiro = primeiro.expect("a captura não produziu quadro em 1s");
        assert!(primeiro.width > 0 && primeiro.height > 0);
        assert_eq!(
            primeiro.rgb.len(),
            (primeiro.width * primeiro.height * 3) as usize
        );

        // `take` consome: sem quadro novo, devolve None na hora.
        assert!(
            pump.take().is_none(),
            "o mesmo quadro não deve ser entregue duas vezes"
        );
    }

    #[test]
    fn pump_para_a_thread_ao_ser_descartado() {
        // Se o Drop não parasse a thread, ela seguiria capturando para sempre —
        // com o custo de CPU que isso implica depois de o app sair.
        let pump = FramePump::start(1280, 30).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let stop = std::sync::Arc::clone(&pump.stop);
        drop(pump);
        assert!(
            stop.load(std::sync::atomic::Ordering::Relaxed),
            "o Drop precisa sinalizar a parada"
        );
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
