//! A captura contínua da tela do Mac, pelo ScreenCaptureKit.
//!
//! ## Por que não o `xcap`, como no Windows
//!
//! Por dois motivos, os dois vistos num Mac de verdade:
//!
//! - **A barra "está controlando" aparecia na imagem do celular**, cobrindo o
//!   que a pessoa olhava. O painel pede para ficar fora de capturas
//!   (`NSWindowSharingType::None`, ver `barra.rs`), mas os macOS mais novos
//!   ignoram esse pedido na captura que o `xcap` usa (`AVCaptureScreenInput`).
//!   Aqui o filtro do ScreenCaptureKit **exclui as janelas do próprio
//!   Deskside**: a barra continua na tela do Mac, para quem está diante dele,
//!   e some da imagem que vai ao celular, em qualquer versão.
//! - **O `AVCaptureScreenInput` está sendo aposentado** pela Apple; numa versão
//!   futura do macOS a imagem poderia simplesmente vir preta.
//!
//! O som já vinha pelo ScreenCaptureKit (`audio.rs`); a imagem agora também.
//!
//! ## O que fica de fora
//!
//! Todas as janelas do processo do Deskside: a barra, a janela de
//! configurações e o ícone da barra de menus. Nenhuma delas é o que alguém
//! controlando pelo celular precisa ver.
//!
//! Se o ScreenCaptureKit não estiver disponível (macOS anterior ao 12.3) ou
//! recusar, `capture.rs` volta para o `xcap`.

/// Teto de largura do que se pede ao Mac. O vídeo vai até 1280 e a lupa até
/// 1920 (ver `client.rs`): pedir a tela Retina inteira (3024 px num MacBook
/// Pro de 14") seria gastar cópia e conversão em pixels que vão fora logo
/// depois.
pub const LARGURA_MAXIMA: u32 = 1920;

/// O tamanho a pedir: a tela em pixels, reduzida a [`LARGURA_MAXIMA`] mantendo
/// a proporção, e com lados pares (os codificadores de vídeo exigem).
///
/// `largura` e `altura` vêm em pontos, como o macOS mede as telas; `escala` é
/// quantos pixels há em cada ponto (2 numa tela Retina).
pub fn tamanho_pedido(largura: f64, altura: f64, escala: f64) -> (u32, u32) {
    let escala = if escala.is_finite() && escala > 0.0 {
        escala
    } else {
        1.0
    };
    let mut l = (largura * escala).round().max(2.0);
    let mut a = (altura * escala).round().max(2.0);
    if l > LARGURA_MAXIMA as f64 {
        a = (a * LARGURA_MAXIMA as f64 / l).round();
        l = LARGURA_MAXIMA as f64;
    }
    let par = |v: f64| ((v as u32).max(2)) & !1;
    (par(l), par(a))
}

/// Converte um quadro BGRA (o formato da tela no Mac) em RGBA, que é o que o
/// resto da captura espera.
///
/// `por_linha` pode ser maior que `largura * 4`: o sistema alinha cada linha
/// da imagem, e os bytes do alinhamento não são pixels.
pub fn bgra_para_rgba(origem: &[u8], largura: usize, altura: usize, por_linha: usize) -> Vec<u8> {
    let util = largura * 4;
    let mut rgba = vec![0u8; util * altura];
    if por_linha < util {
        return rgba;
    }
    for (y, destino) in rgba.chunks_exact_mut(util).enumerate() {
        let inicio = y * por_linha;
        let Some(linha) = origem.get(inicio..inicio + util) else {
            break;
        };
        let (fonte, _) = linha.as_chunks::<4>();
        let (alvo, _) = destino.as_chunks_mut::<4>();
        for (px, saida) in fonte.iter().zip(alvo.iter_mut()) {
            *saida = [px[2], px[1], px[0], 255];
        }
    }
    rgba
}

#[cfg(target_os = "macos")]
pub use imp::Gravador;

#[cfg(target_os = "macos")]
mod imp {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::ProtocolObject;
    use objc2::{define_class, msg_send, AllocAnyThread, DefinedClass};
    use objc2_core_media::{CMSampleBuffer, CMTime};
    use objc2_core_video::{
        kCVPixelFormatType_32BGRA, CVPixelBufferGetBaseAddress, CVPixelBufferGetBytesPerRow,
        CVPixelBufferGetHeight, CVPixelBufferGetWidth, CVPixelBufferLockBaseAddress,
        CVPixelBufferLockFlags, CVPixelBufferUnlockBaseAddress,
    };
    use objc2_foundation::{NSArray, NSError, NSObject, NSObjectProtocol};
    use objc2_screen_capture_kit::{
        SCContentFilter, SCRunningApplication, SCShareableContent, SCStream, SCStreamConfiguration,
        SCStreamDelegate, SCStreamOutput, SCStreamOutputType,
    };

    /// A captura em curso. Sair de escopo a encerra.
    pub struct Gravador {
        parar: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for Gravador {
        fn drop(&mut self) {
            self.parar.store(true, Ordering::Relaxed);
            if let Some(t) = self.thread.take() {
                let _ = t.join();
            }
        }
    }

    struct Estado {
        tx: mpsc::Sender<xcap::Frame>,
        /// O primeiro quadro vai para o diário: é a prova de que a captura
        /// entregou alguma coisa.
        avisou: bool,
    }

    define_class!(
        // SAFETY: NSObject não exige nada de quem herda dele, e esta classe
        // não implementa `Drop`.
        #[unsafe(super(NSObject))]
        #[name = "DesksideSaidaDeTela"]
        #[ivars = Mutex<Estado>]
        struct SaidaDeTela;

        unsafe impl NSObjectProtocol for SaidaDeTela {}

        unsafe impl SCStreamOutput for SaidaDeTela {
            #[unsafe(method(stream:didOutputSampleBuffer:ofType:))]
            fn chegou(&self, _stream: &SCStream, amostra: &CMSampleBuffer, tipo: SCStreamOutputType) {
                if tipo != SCStreamOutputType::Screen {
                    return;
                }
                // Tela parada: o sistema manda amostras sem imagem, e não há o
                // que fazer com elas.
                let Some(quadro) = quadro(amostra) else {
                    return;
                };
                if let Ok(mut estado) = self.ivars().lock() {
                    if !estado.avisou {
                        estado.avisou = true;
                        crate::diario(&format!(
                            "Tela do Mac: primeiro quadro, {}x{}",
                            quadro.width, quadro.height
                        ));
                    }
                    let _ = estado.tx.send(quadro);
                }
            }
        }

        unsafe impl SCStreamDelegate for SaidaDeTela {
            #[unsafe(method(stream:didStopWithError:))]
            fn parou(&self, _stream: &SCStream, erro: &NSError) {
                crate::diario(&format!(
                    "Tela do Mac: a captura parou: {}",
                    erro.localizedDescription()
                ));
            }
        }
    );

    impl SaidaDeTela {
        fn nova(estado: Estado) -> Retained<Self> {
            let this = Self::alloc().set_ivars(Mutex::new(estado));
            unsafe { msg_send![super(this), init] }
        }
    }

    /// Copia a imagem da amostra para um quadro RGBA.
    fn quadro(amostra: &CMSampleBuffer) -> Option<xcap::Frame> {
        let imagem = unsafe { amostra.image_buffer() }?;
        let bloqueio = CVPixelBufferLockFlags::ReadOnly;
        if unsafe { CVPixelBufferLockBaseAddress(&imagem, bloqueio) } != 0 {
            return None;
        }
        let largura = CVPixelBufferGetWidth(&imagem);
        let altura = CVPixelBufferGetHeight(&imagem);
        let por_linha = CVPixelBufferGetBytesPerRow(&imagem);
        let base = CVPixelBufferGetBaseAddress(&imagem) as *const u8;
        let rgba = if base.is_null() || largura == 0 || altura == 0 {
            None
        } else {
            // SAFETY: com o endereço travado, o sistema garante `altura`
            // linhas de `por_linha` bytes a partir de `base`.
            let origem = unsafe { std::slice::from_raw_parts(base, por_linha * altura) };
            Some(super::bgra_para_rgba(origem, largura, altura, por_linha))
        };
        unsafe { CVPixelBufferUnlockBaseAddress(&imagem, bloqueio) };
        Some(xcap::Frame::new(largura as u32, altura as u32, rgba?))
    }

    /// Espera um bloco de conclusão do sistema, com prazo.
    fn esperar<T>(rx: &mpsc::Receiver<T>, o_que: &str) -> Result<T, String> {
        rx.recv_timeout(Duration::from_secs(5))
            .map_err(|_| format!("o Mac não respondeu ao {o_que}"))
    }

    fn erro(e: *mut NSError) -> Option<String> {
        unsafe { e.as_ref() }.map(|e| e.localizedDescription().to_string())
    }

    fn abrir(
        tela_pedida: Option<u32>,
        escala: f64,
        intervalo: Duration,
        tx: mpsc::Sender<xcap::Frame>,
    ) -> Result<(Retained<SCStream>, Retained<SaidaDeTela>), String> {
        // O filtro que exclui um aplicativo existe desde o macOS 12.3.
        if !objc2::available!(macos = 12.3) {
            return Err("o ScreenCaptureKit exige macOS 12.3 ou mais novo".into());
        }

        // 1. O que existe para capturar.
        let (conteudo_tx, conteudo_rx) =
            mpsc::channel::<Result<Retained<SCShareableContent>, String>>();
        let ao_listar = RcBlock::new(move |conteudo: *mut SCShareableContent, e: *mut NSError| {
            let r = match unsafe { Retained::retain(conteudo) } {
                Some(c) => Ok(c),
                None => Err(erro(e).unwrap_or_else(|| "sem tela para capturar".into())),
            };
            let _ = conteudo_tx.send(r);
        });
        unsafe { SCShareableContent::getShareableContentWithCompletionHandler(&ao_listar) };
        let conteudo = esperar(&conteudo_rx, "pedido das telas")?
            .map_err(|e| format!("sem acesso à captura do Mac ({e}); libere a Gravação de Tela"))?;

        // 2. A tela: a pedida pelo celular, ou a primeira.
        let telas = unsafe { conteudo.displays() };
        let tela = tela_pedida
            .and_then(|id| telas.iter().find(|t| unsafe { t.displayID() } == id))
            .or_else(|| telas.firstObject())
            .ok_or("o Mac não listou nenhuma tela")?;

        // 3. Fora da imagem: o próprio Deskside.
        let eu = std::process::id() as i64;
        let deskside: Vec<Retained<SCRunningApplication>> = unsafe { conteudo.applications() }
            .iter()
            .filter(|a| unsafe { a.processID() } as i64 == eu)
            .collect();
        if deskside.is_empty() {
            crate::diario(
                "Tela do Mac: o Deskside não apareceu na lista do sistema; a barra pode entrar na imagem",
            );
        }
        let excluir = NSArray::from_retained_slice(&deskside);
        let filtro = unsafe {
            SCContentFilter::initWithDisplay_excludingApplications_exceptingWindows(
                SCContentFilter::alloc(),
                &tela,
                &excluir,
                &NSArray::new(),
            )
        };

        // 4. Como: pixels BGRA, no ritmo pedido, com o cursor.
        let (largura, altura) = super::tamanho_pedido(
            unsafe { tela.width() } as f64,
            unsafe { tela.height() } as f64,
            escala,
        );
        let por_segundo = (1.0 / intervalo.as_secs_f64().max(0.001))
            .round()
            .clamp(1.0, 60.0);
        let config = unsafe { SCStreamConfiguration::new() };
        unsafe {
            config.setWidth(largura as usize);
            config.setHeight(altura as usize);
            config.setPixelFormat(kCVPixelFormatType_32BGRA);
            config.setMinimumFrameInterval(CMTime::new(1, por_segundo as i32));
            config.setShowsCursor(true);
            config.setQueueDepth(3);
        }

        let saida = SaidaDeTela::nova(Estado { tx, avisou: false });
        let fluxo = unsafe {
            SCStream::initWithFilter_configuration_delegate(
                SCStream::alloc(),
                &filtro,
                &config,
                Some(ProtocolObject::from_ref(&*saida)),
            )
        };
        let fila = dispatch2::DispatchQueue::new("br.com.deskside.tela", None);
        unsafe {
            fluxo.addStreamOutput_type_sampleHandlerQueue_error(
                ProtocolObject::from_ref(&*saida),
                SCStreamOutputType::Screen,
                Some(&fila),
            )
        }
        .map_err(|e| format!("não consegui ligar a captura: {}", e.localizedDescription()))?;

        // 5. Começa.
        let (inicio_tx, inicio_rx) = mpsc::channel::<Option<String>>();
        let ao_comecar = RcBlock::new(move |e: *mut NSError| {
            let _ = inicio_tx.send(erro(e));
        });
        unsafe { fluxo.startCaptureWithCompletionHandler(Some(&ao_comecar)) };
        if let Some(e) = esperar(&inicio_rx, "início da captura")? {
            return Err(format!("o Mac não começou a captura da tela: {e}"));
        }
        crate::diario(&format!(
            "Tela do Mac: capturando {largura}x{altura} a até {por_segundo} quadros/s, sem as janelas do Deskside"
        ));
        Ok((fluxo, saida))
    }

    impl Gravador {
        /// Liga a captura e devolve o canal dos quadros.
        ///
        /// Numa thread própria, como o som: os objetos do ScreenCaptureKit
        /// nascem, vivem e param na mesma.
        pub fn iniciar(
            tela: Option<u32>,
            escala: f64,
            intervalo: Duration,
        ) -> Result<(Self, mpsc::Receiver<xcap::Frame>), String> {
            let parar = Arc::new(AtomicBool::new(false));
            let sinal = Arc::clone(&parar);
            let (quadros_tx, quadros_rx) = mpsc::channel::<xcap::Frame>();
            let (pronto_tx, pronto_rx) = mpsc::channel::<Result<(), String>>();

            let thread =
                std::thread::spawn(move || match abrir(tela, escala, intervalo, quadros_tx) {
                    Err(e) => {
                        let _ = pronto_tx.send(Err(e));
                    }
                    Ok((fluxo, _saida)) => {
                        let _ = pronto_tx.send(Ok(()));
                        while !sinal.load(Ordering::Relaxed) {
                            std::thread::sleep(Duration::from_millis(100));
                        }
                        let (fim_tx, fim_rx) = mpsc::channel::<()>();
                        let ao_parar = RcBlock::new(move |_e: *mut NSError| {
                            let _ = fim_tx.send(());
                        });
                        unsafe { fluxo.stopCaptureWithCompletionHandler(Some(&ao_parar)) };
                        let _ = fim_rx.recv_timeout(Duration::from_secs(2));
                    }
                });

            match pronto_rx.recv_timeout(Duration::from_secs(12)) {
                Ok(Ok(())) => Ok((
                    Self {
                        parar,
                        thread: Some(thread),
                    },
                    quadros_rx,
                )),
                Ok(Err(e)) => Err(e),
                Err(_) => Err("o Mac não respondeu ao pedido de captura da tela".to_string()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tela_retina_cabe_no_teto_sem_perder_a_proporcao() {
        // MacBook Pro de 14": 1512x982 pontos, 2 pixels por ponto.
        let (l, a) = tamanho_pedido(1512.0, 982.0, 2.0);
        assert_eq!(l, LARGURA_MAXIMA);
        assert_eq!(a, 1246);
        assert_eq!(a % 2, 0);
    }

    #[test]
    fn tela_pequena_vai_inteira_e_com_lados_pares() {
        assert_eq!(tamanho_pedido(1280.0, 800.0, 1.0), (1280, 800));
        assert_eq!(tamanho_pedido(1023.0, 767.0, 1.0), (1022, 766));
        // Escala inválida não derruba: vale como 1.
        assert_eq!(tamanho_pedido(1280.0, 800.0, f64::NAN), (1280, 800));
    }

    #[test]
    fn bgra_vira_rgba_e_ignora_o_alinhamento_das_linhas() {
        // 2x2 pixels, cada linha com 4 bytes de alinhamento no fim.
        let origem = [
            1, 2, 3, 9, 4, 5, 6, 9, 0, 0, 0, 0, //
            7, 8, 9, 9, 10, 11, 12, 9, 0, 0, 0, 0,
        ];
        let rgba = bgra_para_rgba(&origem, 2, 2, 12);
        assert_eq!(
            rgba,
            vec![3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255]
        );
    }

    #[test]
    fn origem_curta_nao_estoura() {
        let rgba = bgra_para_rgba(&[1, 2, 3, 4], 2, 2, 8);
        assert_eq!(rgba.len(), 16);
    }
}
