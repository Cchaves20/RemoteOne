//! A barra "está controlando este computador", com o botão "Desconectar".
//!
//! É a defesa contra o golpe da "mão fantasma": alguém controlando o
//! computador de outra pessoa sem ela perceber. Enquanto houver alguém com a
//! tela aberta pelo app, uma barra fica no alto da tela, por cima de tudo, e o
//! botão dela fecha a tela de quem está vendo **e** encerra o login daquele
//! aparelho (ver `backend/app/controle.py`) — só fechar a tela não adiantaria,
//! porque quem invadiu reconectaria no segundo seguinte.
//!
//! ## Nativa, e não na janela do Deskside
//!
//! A janela do Deskside é desenhada pela placa de vídeo e **não abre** em
//! máquina sem uma (ver `gui::bandeja_sem_placa_de_video`) — e computador de
//! acesso remoto é justamente onde isso acontece: máquina virtual, Área de
//! Trabalho Remota. Uma barra de segurança que some nessas máquinas não serve.
//! Por isso ela é feita com os componentes do próprio sistema: uma janela do
//! Windows desenhada pelo GDI, e um painel da AppKit no Mac.
//!
//! ## Fora da imagem que vai ao celular
//!
//! Quem está do outro lado não precisa ver a barra cobrindo o que ele está
//! olhando. No Windows 10 de 2020 em diante ela fica fora de qualquer captura
//! de tela; no Mac, o pedido equivalente vale em parte das versões.
//!
//! ## O toque do celular passa por baixo
//!
//! Escondida da imagem, a barra continuava lá para o mouse: um toque do
//! celular no alto da tela caía no "Desconectar" que ninguém via, e quem
//! estava controlando era desconectado sem entender por quê. Agora, antes de
//! apertar, soltar ou rolar o mouse a pedido do celular, o agente confere se o
//! cursor está sobre a barra e, se estiver, a tira do caminho por um instante
//! (ver [`desviar`]). O toque chega ao que está embaixo — que é o que o
//! celular está vendo —, e só quem está diante do computador consegue clicar
//! em "Desconectar".
//!
//! ## Sem botão de fechar
//!
//! Só o "Desconectar". Uma barra que se fecha sem desconectar esconderia
//! exatamente o aviso que ela existe para dar.

use crate::gui::Compartilhado;
use crate::protocol::Controlador;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Por quanto tempo a barra sai do caminho depois de um toque do celular
/// sobre ela. Cobre o apertar e soltar de um clique e o duplo clique; depois
/// disso ela volta.
const DESVIO: Duration = Duration::from_millis(1500);

static DESVIO_ATE: Mutex<Option<Instant>> = Mutex::new(None);

/// A barra está fora do caminho de um toque do celular agora?
#[cfg_attr(not(any(windows, target_os = "macos")), allow(dead_code))]
fn desviando() -> bool {
    DESVIO_ATE
        .lock()
        .ok()
        .and_then(|d| *d)
        .is_some_and(|ate| Instant::now() < ate)
}

#[cfg_attr(not(any(windows, target_os = "macos")), allow(dead_code))]
fn marcar_desvio() {
    if let Ok(mut d) = DESVIO_ATE.lock() {
        *d = Some(Instant::now() + DESVIO);
    }
}

/// Tira a barra do caminho se o cursor estiver sobre ela.
///
/// O injetor chama isto antes de apertar, soltar ou rolar o mouse a pedido do
/// celular. **Volta só depois de a barra sumir**: o Windows decide para quem
/// vai o clique pela janela que está sob o cursor no momento em que o recebe,
/// e com a barra ainda ali o toque iria para o botão dela.
pub fn desviar() {
    imp::desviar();
}

/// A frase da barra, ou vazia quando ninguém está controlando.
///
/// Todas as telas abertas são da mesma conta (o computador pertence a uma),
/// então o nome é um só e o que varia é o aparelho.
pub fn texto(quem: &[Controlador]) -> String {
    if quem.is_empty() {
        return String::new();
    }
    let nome = quem
        .iter()
        .map(|c| c.nome.trim())
        .find(|n| !n.is_empty())
        .unwrap_or("");
    let mut aparelhos: Vec<&str> = Vec::new();
    for c in quem {
        let a = c.aparelho.trim();
        if !a.is_empty() && !aparelhos.contains(&a) {
            aparelhos.push(a);
        }
    }
    let de_onde = if aparelhos.is_empty() {
        String::new()
    } else {
        format!(" ({})", aparelhos.join(", "))
    };
    if nome.is_empty() {
        format!("Este computador está sendo controlado pelo Deskside{de_onde}")
    } else {
        format!("{nome} está controlando este computador{de_onde}")
    }
}

/// O clique em "Desconectar": pede ao laço de rede e esconde a barra na hora.
///
/// Esconder antes de o servidor confirmar é deliberado: o laço de rede derruba
/// a tela deste lado no tique seguinte, e um botão que continua ali depois de
/// clicado faz a pessoa clicar de novo, achando que não pegou.
#[cfg_attr(not(any(windows, target_os = "macos")), allow(dead_code))]
fn desconectar(estado: &Compartilhado) {
    if let Ok(mut e) = estado.lock() {
        e.encerrar_controle = true;
        e.controladores.clear();
    }
}

/// Sobe a barra. Chamada uma vez, ao abrir a interface.
///
/// Independente da janela do Deskside: sobe mesmo quando ela não abre.
pub fn iniciar(estado: Compartilhado) {
    imp::iniciar(estado);
}

#[cfg(windows)]
mod imp {
    use super::{desconectar, desviando, marcar_desvio, texto};
    use crate::gui::Compartilhado;
    use std::sync::atomic::{AtomicIsize, Ordering};
    use std::sync::OnceLock;

    static ESTADO: OnceLock<Compartilhado> = OnceLock::new();
    /// A janela da barra, para o injetor (outra thread) conferir onde ela está.
    static JANELA: AtomicIsize = AtomicIsize::new(0);

    type Hwnd = isize;

    #[repr(C)]
    #[derive(Default)]
    struct Ponto {
        x: i32,
        y: i32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct Retangulo {
        esquerda: i32,
        topo: i32,
        direita: i32,
        base: i32,
    }

    #[repr(C)]
    struct ClasseDeJanela {
        tamanho: u32,
        estilo: u32,
        procedimento: unsafe extern "system" fn(Hwnd, u32, usize, isize) -> isize,
        extra_classe: i32,
        extra_janela: i32,
        instancia: isize,
        icone: isize,
        cursor: isize,
        fundo: isize,
        menu: *const u16,
        nome: *const u16,
        icone_pequeno: isize,
    }

    #[repr(C)]
    struct Mensagem {
        janela: Hwnd,
        mensagem: u32,
        wparam: usize,
        lparam: isize,
        tempo: u32,
        x: i32,
        y: i32,
    }

    #[link(name = "user32")]
    extern "system" {
        fn RegisterClassExW(classe: *const ClasseDeJanela) -> u16;
        fn CreateWindowExW(
            estilo_ext: u32,
            classe: *const u16,
            titulo: *const u16,
            estilo: u32,
            x: i32,
            y: i32,
            largura: i32,
            altura: i32,
            pai: Hwnd,
            menu: isize,
            instancia: isize,
            parametro: *const core::ffi::c_void,
        ) -> Hwnd;
        fn DefWindowProcW(janela: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize;
        fn GetMessageW(msg: *mut Mensagem, janela: Hwnd, min: u32, max: u32) -> i32;
        fn TranslateMessage(msg: *const Mensagem) -> i32;
        fn DispatchMessageW(msg: *const Mensagem) -> isize;
        fn ShowWindow(janela: Hwnd, comando: i32) -> i32;
        fn IsWindowVisible(janela: Hwnd) -> i32;
        fn SetWindowPos(
            janela: Hwnd,
            depois_de: Hwnd,
            x: i32,
            y: i32,
            largura: i32,
            altura: i32,
            opcoes: u32,
        ) -> i32;
        fn SetWindowTextW(janela: Hwnd, texto: *const u16) -> i32;
        fn SetTimer(janela: Hwnd, id: usize, ms: u32, funcao: *const core::ffi::c_void) -> usize;
        fn GetSystemMetrics(qual: i32) -> i32;
        fn SendMessageW(janela: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize;
        fn SetWindowDisplayAffinity(janela: Hwnd, afinidade: u32) -> i32;
        fn LoadCursorW(instancia: isize, nome: usize) -> isize;
        fn GetDC(janela: Hwnd) -> isize;
        fn GetCursorPos(ponto: *mut Ponto) -> i32;
        fn GetWindowRect(janela: Hwnd, retangulo: *mut Retangulo) -> i32;
        fn ReleaseDC(janela: Hwnd, dc: isize) -> i32;
    }

    #[link(name = "gdi32")]
    extern "system" {
        fn CreateSolidBrush(cor: u32) -> isize;
        #[allow(clippy::too_many_arguments)]
        fn CreateFontW(
            altura: i32,
            largura: i32,
            escape: i32,
            orientacao: i32,
            peso: i32,
            italico: u32,
            sublinhado: u32,
            riscado: u32,
            charset: u32,
            precisao: u32,
            recorte: u32,
            qualidade: u32,
            familia: u32,
            nome: *const u16,
        ) -> isize;
        fn SetTextColor(dc: isize, cor: u32) -> u32;
        fn SetBkColor(dc: isize, cor: u32) -> u32;
        fn GetDeviceCaps(dc: isize, indice: i32) -> i32;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetModuleHandleW(nome: *const u16) -> isize;
    }

    const WS_POPUP: u32 = 0x8000_0000;
    const WS_CHILD: u32 = 0x4000_0000;
    const WS_VISIBLE: u32 = 0x1000_0000;
    const WS_EX_TOPMOST: u32 = 0x0000_0008;
    const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
    const WS_EX_NOACTIVATE: u32 = 0x0800_0000;
    const SS_LEFTNOWORDWRAP: u32 = 0x0000_000C;
    const SS_CENTERIMAGE: u32 = 0x0000_0200;
    const SS_ENDELLIPSIS: u32 = 0x0000_4000;
    const BS_PUSHBUTTON: u32 = 0;
    const WM_CLOSE: u32 = 0x0010;
    const WM_SETFONT: u32 = 0x0030;
    const WM_COMMAND: u32 = 0x0111;
    const WM_TIMER: u32 = 0x0113;
    const WM_CTLCOLORSTATIC: u32 = 0x0138;
    const SW_HIDE: i32 = 0;
    const SW_SHOWNOACTIVATE: i32 = 4;
    const HWND_TOPMOST: Hwnd = -1;
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOACTIVATE: u32 = 0x0010;
    const SM_CXSCREEN: i32 = 0;
    const LOGPIXELSX: i32 = 88;
    const IDC_ARROW: usize = 32512;
    /// Fora de qualquer captura de tela (Windows 10 2004 em diante). Em
    /// versões anteriores o pedido falha sem efeito, e a barra aparece no
    /// celular — o que não atrapalha nada além da vista.
    const WDA_EXCLUDEFROMCAPTURE: u32 = 0x0000_0011;
    const ID_BOTAO: usize = 1;

    /// Vermelho escuro com texto branco: chama a atenção sem parecer erro.
    const FUNDO: u32 = rgb(0xB3, 0x26, 0x1E);
    const BRANCO: u32 = rgb(0xFF, 0xFF, 0xFF);

    const fn rgb(r: u32, g: u32, b: u32) -> u32 {
        r | (g << 8) | (b << 16)
    }

    fn largo(texto: &str) -> Vec<u16> {
        texto.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// O que a janela precisa lembrar entre uma mensagem e outra.
    struct Barra {
        janela: Hwnd,
        rotulo: Hwnd,
        pincel: isize,
        mostrado: String,
    }

    static mut BARRA: Option<Barra> = None;

    pub fn iniciar(estado: Compartilhado) {
        if ESTADO.set(estado).is_err() {
            return;
        }
        // Thread própria, com a sua fila de mensagens: a janela do Windows
        // pertence à thread que a cria, e a principal é do `egui`.
        let _ = std::thread::Builder::new()
            .name("deskside-barra".into())
            .spawn(|| unsafe { rodar() });
    }

    unsafe fn rodar() {
        let instancia = GetModuleHandleW(std::ptr::null());
        let nome_da_classe = largo("DesksideBarraDeControle");
        let pincel = CreateSolidBrush(FUNDO);
        let classe = ClasseDeJanela {
            tamanho: std::mem::size_of::<ClasseDeJanela>() as u32,
            estilo: 0,
            procedimento: procedimento,
            extra_classe: 0,
            extra_janela: 0,
            instancia,
            icone: 0,
            cursor: LoadCursorW(0, IDC_ARROW),
            fundo: pincel,
            menu: std::ptr::null(),
            nome: nome_da_classe.as_ptr(),
            icone_pequeno: 0,
        };
        if RegisterClassExW(&classe) == 0 {
            crate::diario("barra de controle: não consegui registrar a janela");
            return;
        }

        // A escala da tela: o agente pede pixels físicos (a captura precisa
        // deles), então 100% e 200% precisam de tamanhos diferentes.
        let dc = GetDC(0);
        let dpi = if dc != 0 {
            GetDeviceCaps(dc, LOGPIXELSX)
        } else {
            96
        };
        if dc != 0 {
            ReleaseDC(0, dc);
        }
        let px = |n: i32| n * dpi.max(96) / 96;

        let largura_da_tela = GetSystemMetrics(SM_CXSCREEN);
        let largura = px(620).min(largura_da_tela - px(16));
        let altura = px(44);
        let x = (largura_da_tela - largura) / 2;
        let y = px(8);

        let titulo = largo("Deskside");
        let janela = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            nome_da_classe.as_ptr(),
            titulo.as_ptr(),
            WS_POPUP,
            x,
            y,
            largura,
            altura,
            0,
            0,
            instancia,
            std::ptr::null(),
        );
        if janela == 0 {
            crate::diario("barra de controle: a janela não abriu");
            return;
        }
        let largura_do_botao = px(118);
        let estatico = largo("STATIC");
        let vazio = largo("");
        let rotulo = CreateWindowExW(
            0,
            estatico.as_ptr(),
            vazio.as_ptr(),
            WS_CHILD | WS_VISIBLE | SS_LEFTNOWORDWRAP | SS_CENTERIMAGE | SS_ENDELLIPSIS,
            px(14),
            0,
            largura - largura_do_botao - px(28),
            altura,
            janela,
            0,
            instancia,
            std::ptr::null(),
        );
        let classe_botao = largo("BUTTON");
        let texto_botao = largo("Desconectar");
        let botao = CreateWindowExW(
            0,
            classe_botao.as_ptr(),
            texto_botao.as_ptr(),
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            largura - largura_do_botao - px(8),
            px(7),
            largura_do_botao,
            altura - px(14),
            janela,
            ID_BOTAO as isize,
            instancia,
            std::ptr::null(),
        );
        let familia = largo("Segoe UI");
        let fonte = CreateFontW(
            -px(15),
            0,
            0,
            0,
            600,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            familia.as_ptr(),
        );
        let fonte_do_botao = CreateFontW(
            -px(14),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            familia.as_ptr(),
        );
        SendMessageW(rotulo, WM_SETFONT, fonte as usize, 1);
        SendMessageW(botao, WM_SETFONT, fonte_do_botao as usize, 1);
        SetWindowDisplayAffinity(janela, WDA_EXCLUDEFROMCAPTURE);

        JANELA.store(janela, Ordering::SeqCst);
        BARRA = Some(Barra {
            janela,
            rotulo,
            pincel,
            mostrado: String::new(),
        });
        // Consulta o estado a cada 0,4 s, na própria fila desta janela: sem
        // canal entre threads, e a barra nunca fica mais de meio segundo
        // atrás de quem conectou.
        SetTimer(janela, 1, 400, std::ptr::null());
        crate::diario("barra de controle pronta");

        let mut msg = std::mem::zeroed::<Mensagem>();
        while GetMessageW(&mut msg, 0, 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    unsafe extern "system" fn procedimento(
        janela: Hwnd,
        msg: u32,
        wparam: usize,
        lparam: isize,
    ) -> isize {
        #[allow(static_mut_refs)]
        let barra = BARRA.as_mut();
        match (msg, barra) {
            (WM_TIMER, Some(barra)) => {
                atualizar(barra);
                0
            }
            (WM_COMMAND, Some(barra)) if wparam & 0xFFFF == ID_BOTAO => {
                if let Some(estado) = ESTADO.get() {
                    desconectar(estado);
                }
                ShowWindow(barra.janela, SW_HIDE);
                barra.mostrado.clear();
                0
            }
            // O texto em branco sobre o vermelho da barra.
            (WM_CTLCOLORSTATIC, Some(barra)) => {
                let dc = wparam as isize;
                SetTextColor(dc, BRANCO);
                SetBkColor(dc, FUNDO);
                barra.pincel
            }
            // Alt+F4 não fecha: a barra some quando o controle acaba.
            (WM_CLOSE, _) => 0,
            _ => DefWindowProcW(janela, msg, wparam, lparam),
        }
    }

    pub fn desviar() {
        let janela = JANELA.load(Ordering::SeqCst);
        if janela == 0 {
            return;
        }
        unsafe {
            // Escondida porque ninguém está controlando: não há o que desviar.
            if IsWindowVisible(janela) == 0 && !desviando() {
                return;
            }
            let mut cursor = Ponto::default();
            let mut quadro = Retangulo::default();
            if GetCursorPos(&mut cursor) == 0 || GetWindowRect(janela, &mut quadro) == 0 {
                return;
            }
            let dentro = cursor.x >= quadro.esquerda
                && cursor.x < quadro.direita
                && cursor.y >= quadro.topo
                && cursor.y < quadro.base;
            if dentro {
                marcar_desvio();
                // Síncrono de propósito: a janela é de outra thread, e o
                // `ShowWindow` só volta depois de ela sumir de fato.
                ShowWindow(janela, SW_HIDE);
            }
        }
    }

    unsafe fn atualizar(barra: &mut Barra) {
        let atual = ESTADO
            .get()
            .and_then(|e| e.lock().ok().map(|e| texto(&e.controladores)))
            .unwrap_or_default();
        if atual.is_empty() {
            if IsWindowVisible(barra.janela) != 0 {
                ShowWindow(barra.janela, SW_HIDE);
            }
            barra.mostrado.clear();
            return;
        }
        if atual != barra.mostrado {
            let linha = largo(&format!("●  {atual}"));
            SetWindowTextW(barra.rotulo, linha.as_ptr());
            barra.mostrado = atual;
        }
        // Fora do caminho de um toque do celular: volta quando o desvio acabar.
        if desviando() {
            return;
        }
        if IsWindowVisible(barra.janela) == 0 {
            ShowWindow(barra.janela, SW_SHOWNOACTIVATE);
        }
        // Reafirma "por cima de tudo" a cada volta: outro programa que também
        // pede para ficar no topo passaria na frente da barra.
        SetWindowPos(
            barra.janela,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{desconectar, desviando, marcar_desvio, texto};
    use crate::gui::Compartilhado;
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::{define_class, msg_send, sel, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{
        NSBackingStoreType, NSButton, NSColor, NSEvent, NSFont, NSLineBreakMode, NSPanel, NSScreen,
        NSStatusWindowLevel, NSTextField, NSWindowCollectionBehavior, NSWindowSharingType,
        NSWindowStyleMask,
    };
    use objc2_foundation::{NSObject, NSPoint, NSRect, NSSize, NSString};
    use std::cell::RefCell;
    use std::sync::OnceLock;

    static ESTADO: OnceLock<Compartilhado> = OnceLock::new();

    const LARGURA: f64 = 620.0;
    const ALTURA: f64 = 44.0;
    const LARGURA_DO_BOTAO: f64 = 118.0;

    define_class!(
        // SAFETY: NSObject não exige nada de quem herda dele, e esta classe
        // não implementa `Drop`.
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[name = "DesksideAlvoDaBarra"]
        struct Alvo;

        impl Alvo {
            #[unsafe(method(desconectar:))]
            fn desconectar(&self, _remetente: Option<&AnyObject>) {
                if let Some(estado) = ESTADO.get() {
                    desconectar(estado);
                }
                BARRA.with(|b| {
                    if let Some(b) = b.borrow_mut().as_mut() {
                        b.painel.orderOut(None);
                        b.mostrado.clear();
                    }
                });
            }
        }
    );

    impl Alvo {
        fn novo(mtm: MainThreadMarker) -> Retained<Self> {
            let this = Self::alloc(mtm).set_ivars(());
            unsafe { msg_send![super(this), init] }
        }
    }

    struct Barra {
        painel: Retained<NSPanel>,
        rotulo: Retained<NSTextField>,
        /// O botão só guarda uma referência fraca ao alvo: sem esta, o clique
        /// iria para um objeto já liberado.
        _alvo: Retained<Alvo>,
        mostrado: String,
    }

    thread_local! {
        /// A barra vive na thread principal, a única onde a AppKit aceita ser
        /// chamada.
        static BARRA: RefCell<Option<Barra>> = const { RefCell::new(None) };
    }

    pub fn iniciar(estado: Compartilhado) {
        if ESTADO.set(estado).is_err() {
            return;
        }
        // Quem consulta o estado é uma thread à parte; quem mexe no painel é a
        // principal, pela fila dela.
        let _ = std::thread::Builder::new()
            .name("deskside-barra".into())
            .spawn(|| {
                let mut anterior = String::new();
                let mut desviada = false;
                loop {
                    let atual = ESTADO
                        .get()
                        .and_then(|e| e.lock().ok().map(|e| texto(&e.controladores)))
                        .unwrap_or_default();
                    // Também quando um desvio acaba: é o que traz a barra de
                    // volta depois do toque do celular.
                    let agora_desviada = desviando();
                    if atual != anterior || (desviada && !agora_desviada) {
                        anterior = atual.clone();
                        dispatch2::DispatchQueue::main().exec_async(move || aplicar(&atual));
                    }
                    desviada = agora_desviada;
                    std::thread::sleep(std::time::Duration::from_millis(400));
                }
            });
    }

    pub fn desviar() {
        // Na thread principal, e esperando: a AppKit só aceita ser chamada
        // ali, e o clique só pode sair depois de a barra sumir.
        dispatch2::DispatchQueue::main().exec_sync(|| {
            if MainThreadMarker::new().is_none() {
                return;
            }
            BARRA.with(|celula| {
                let celula = celula.borrow();
                let Some(barra) = celula.as_ref() else {
                    return;
                };
                if !barra.painel.isVisible() && !desviando() {
                    return;
                }
                // As duas medidas na mesma régua: pontos, com a origem no
                // canto de baixo da tela principal.
                let cursor = NSEvent::mouseLocation();
                let quadro = barra.painel.frame();
                let dentro = cursor.x >= quadro.origin.x
                    && cursor.x < quadro.origin.x + quadro.size.width
                    && cursor.y >= quadro.origin.y
                    && cursor.y < quadro.origin.y + quadro.size.height;
                if dentro {
                    marcar_desvio();
                    barra.painel.orderOut(None);
                }
            });
        });
    }

    fn aplicar(atual: &str) {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        BARRA.with(|celula| {
            let mut celula = celula.borrow_mut();
            if atual.is_empty() {
                if let Some(b) = celula.as_mut() {
                    b.painel.orderOut(None);
                    b.mostrado.clear();
                }
                return;
            }
            let barra = celula.get_or_insert_with(|| criar(mtm));
            if barra.mostrado != atual {
                barra
                    .rotulo
                    .setStringValue(&NSString::from_str(&format!("●  {atual}")));
                barra.mostrado = atual.to_string();
            }
            if !desviando() {
                barra.painel.orderFrontRegardless();
            }
        });
    }

    fn criar(mtm: MainThreadMarker) -> Barra {
        // No alto da tela principal, centralizada, logo abaixo da barra de
        // menus (o `visibleFrame` já a desconta).
        let area = NSScreen::mainScreen(mtm)
            .map(|t| t.visibleFrame())
            .unwrap_or(NSRect::new(
                NSPoint::new(0.0, 0.0),
                NSSize::new(1280.0, 800.0),
            ));
        let largura = LARGURA.min(area.size.width - 16.0);
        let quadro = NSRect::new(
            NSPoint::new(
                area.origin.x + (area.size.width - largura) / 2.0,
                area.origin.y + area.size.height - ALTURA - 8.0,
            ),
            NSSize::new(largura, ALTURA),
        );
        let painel = NSPanel::initWithContentRect_styleMask_backing_defer(
            NSPanel::alloc(mtm),
            quadro,
            NSWindowStyleMask::Borderless | NSWindowStyleMask::NonactivatingPanel,
            NSBackingStoreType::Buffered,
            false,
        );
        unsafe { painel.setReleasedWhenClosed(false) };
        painel.setLevel(NSStatusWindowLevel);
        painel.setFloatingPanel(true);
        painel.setHidesOnDeactivate(false);
        painel.setCollectionBehavior(
            NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::FullScreenAuxiliary
                | NSWindowCollectionBehavior::Stationary,
        );
        // Fora da imagem que vai ao celular, onde o macOS respeitar o pedido.
        painel.setSharingType(NSWindowSharingType::None);
        painel.setBackgroundColor(Some(&NSColor::colorWithSRGBRed_green_blue_alpha(
            0.70, 0.15, 0.12, 1.0,
        )));

        let rotulo = NSTextField::labelWithString(&NSString::from_str(""), mtm);
        rotulo.setTextColor(Some(&NSColor::whiteColor()));
        rotulo.setFont(Some(&NSFont::boldSystemFontOfSize(13.0)));
        rotulo.setLineBreakMode(NSLineBreakMode::ByTruncatingTail);
        rotulo.setFrame(NSRect::new(
            NSPoint::new(14.0, 12.0),
            NSSize::new(largura - LARGURA_DO_BOTAO - 28.0, 20.0),
        ));

        let alvo = Alvo::novo(mtm);
        let botao = unsafe {
            NSButton::buttonWithTitle_target_action(
                &NSString::from_str("Desconectar"),
                Some(&alvo),
                Some(sel!(desconectar:)),
                mtm,
            )
        };
        botao.setFrame(NSRect::new(
            NSPoint::new(largura - LARGURA_DO_BOTAO - 8.0, 8.0),
            NSSize::new(LARGURA_DO_BOTAO, ALTURA - 16.0),
        ));

        if let Some(conteudo) = painel.contentView() {
            conteudo.addSubview(&rotulo);
            conteudo.addSubview(&botao);
        }
        crate::diario("barra de controle pronta");
        Barra {
            painel,
            rotulo,
            _alvo: alvo,
            mostrado: String::new(),
        }
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
mod imp {
    use crate::gui::Compartilhado;

    /// Fora do Windows e do Mac o agente roda no terminal, sem interface.
    pub fn iniciar(_estado: Compartilhado) {}

    pub fn desviar() {}
}

#[cfg(test)]
mod tests {
    use super::texto;
    use crate::protocol::Controlador;

    fn c(nome: &str, aparelho: &str) -> Controlador {
        Controlador {
            nome: nome.into(),
            aparelho: aparelho.into(),
        }
    }

    #[test]
    fn ninguem_vendo_nao_mostra_nada() {
        assert_eq!(texto(&[]), "");
    }

    #[test]
    fn diz_quem_e_de_qual_aparelho() {
        assert_eq!(
            texto(&[c("Caio", "iPhone · iOS 18.1")]),
            "Caio está controlando este computador (iPhone · iOS 18.1)"
        );
    }

    #[test]
    fn dois_aparelhos_da_mesma_conta() {
        assert_eq!(
            texto(&[c("Caio", "iPhone"), c("Caio", "iPad"), c("Caio", "iPhone")]),
            "Caio está controlando este computador (iPhone, iPad)"
        );
    }

    #[test]
    fn app_antigo_sem_aparelho_e_conta_sem_nome() {
        assert_eq!(
            texto(&[c("Caio", "")]),
            "Caio está controlando este computador"
        );
        assert_eq!(
            texto(&[c("", "")]),
            "Este computador está sendo controlado pelo Deskside"
        );
    }
}
