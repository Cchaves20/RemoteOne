//! A janela e o ícone ao lado do relógio.
//!
//! O agente rodava sem cara nenhuma: sem ícone, sem janela, sem prova de que
//! estava de pé. Para saber, era preciso abrir um terminal e digitar `status`.
//! E o código de pareamento aparecia numa MessageBox disparada por um
//! `powershell.exe` - lenta, sem acento, e o padrão que antivírus marcam.
//!
//! ## Quem manda em quem
//!
//! A biblioteca de janelas precisa da **thread principal**, e o `tokio` não.
//! Por isso a inversão: a `main` vira a interface, e o agente ganha uma thread
//! própria com o seu runtime. O contrário - interface numa thread secundária -
//! funciona no Windows com uma opção especial do `winit`, mas é brigar com a
//! plataforma para economizar um `spawn`.
//!
//! **A interface nunca pode impedir o agente de rodar.** A thread do agente
//! sobe primeiro e é independente; se a janela não abrir, o agente continua
//! trabalhando e a `main` apenas dorme. Um computador que deixa de ser
//! alcançável porque a interface falhou seria uma troca péssima.
//!
//! ## A janela nasce escondida
//!
//! Quem instalou quer o agente subindo no login sem nada piscando na tela. A
//! janela existe desde o começo, mas invisível, e aparece quando alguém pede:
//! duplo clique no ícone da bandeja, o menu, o atalho do Menu Iniciar (que
//! chega aqui pela guarda de instância única) ou a chegada de um código de
//! pareamento. Fechar no X **esconde** em vez de sair - sair é só pelo menu da
//! bandeja, senão o computador sumiria do app sem ninguém entender por quê.

use std::sync::{Arc, Mutex};

/// O que a janela mostra. Escrito pela thread do agente, lido pela interface.
///
/// Um `Mutex` e não um canal: são valores que têm um estado atual, e não uma
/// sequência de eventos. Com canal, a janela teria que reconstruir o estado
/// a partir do histórico, e abrir a janela depois de duas horas mostraria o
/// que aconteceu no começo.
#[derive(Debug, Clone, Default)]
pub struct Estado {
    pub hostname: String,
    pub device_id: String,
    pub versao: String,
    pub backend: String,
    pub conectado: bool,
    /// Última falha de conexão, para a janela dizer o que houve.
    pub ultimo_erro: Option<String>,
    /// Se o "manter pronto" está ligado, e se está valendo agora.
    pub keep_awake: bool,
    pub segurando: bool,
    /// A automação que vai disparar em instantes, se houver.
    ///
    /// Escrito pelo laço de rede, lido pela bandeja — que é onde o aviso
    /// precisa aparecer. Na janela seria mais bonito, e numa máquina virtual
    /// sem placa de vídeo a janela **não abre**: um aviso que só funciona em
    /// computador com GPU não serve para um produto de acesso remoto.
    pub aviso: Option<AvisoDeAgenda>,
    /// Qual automação a pessoa pediu para cancelar hoje.
    ///
    /// A bandeja escreve, o laço de rede lê e limpa. Um campo e não um canal
    /// porque a bandeja nasce antes do laço e sobrevive às reconexões dele —
    /// um canal teria que ser recriado a cada uma.
    pub cancelar: Option<String>,
    /// A pessoa clicou em desinstalar (e confirmou).
    ///
    /// O laço de rede lê, avisa o servidor e marca `desparear_ok`. Quem de
    /// fato desinstala é a thread que a própria janela abriu — e isso é
    /// deliberado: se o computador estiver sem internet, o laço de rede nem
    /// está rodando, e um botão que só funciona online seria pior que nenhum.
    pub desinstalar: bool,
    /// O servidor confirmou que o computador saiu da conta.
    pub desparear_ok: bool,
}

/// O aviso de que uma automação vai rodar.
#[derive(Debug, Clone, PartialEq)]
pub struct AvisoDeAgenda {
    pub id: String,
    pub nome: String,
    /// Quando ela roda, em minuto do dia — a bandeja recalcula quanto falta em
    /// vez de receber uma contagem que envelheceria entre um desenho e outro.
    pub minuto_do_dia: u16,
}

/// Um estado compartilhado, pronto para ser clonado entre as duas threads.
pub type Compartilhado = Arc<Mutex<Estado>>;

pub fn compartilhar(inicial: Estado) -> Compartilhado {
    Arc::new(Mutex::new(inicial))
}

/// Sobe a interface. Só volta quando o usuário escolhe sair.
///
/// Fora do Windows não há bandeja nem instalação: o agente de desenvolvimento
/// roda no terminal, e a função apenas dorme para não deixar a `main` acabar.
pub fn rodar(estado: Compartilhado) {
    imp::rodar(estado);
}

#[cfg(windows)]
mod imp {
    use super::{AvisoDeAgenda, Compartilhado, Estado};
    use eframe::egui;
    use std::sync::OnceLock;
    use tray_icon::{
        menu::{Menu, MenuEvent, MenuId, MenuItem},
        TrayIcon, TrayIconBuilder, TrayIconEvent,
    };

    /// O contexto da interface, para as threads de eventos pedirem a janela.
    ///
    /// Um global porque há exatamente um, e o alternativo seria carregá-lo por
    /// dentro de três threads que não têm nada a ver umas com as outras.
    static CONTEXTO: OnceLock<egui::Context> = OnceLock::new();

    const SW_SHOW: i32 = 5;
    const SW_RESTORE: i32 = 9;

    #[link(name = "user32")]
    extern "system" {
        fn FindWindowExW(pai: isize, apos: isize, classe: *const u16, titulo: *const u16) -> isize;
        fn GetWindowThreadProcessId(janela: isize, pid: *mut u32) -> u32;
        fn ShowWindow(janela: isize, comando: i32) -> i32;
        fn SetForegroundWindow(janela: isize) -> i32;
        fn IsIconic(janela: isize) -> i32;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcessId() -> u32;
    }

    /// Acha a janela deste processo, mesmo escondida.
    ///
    /// Pelo título, e conferindo o **processo dono**: "Deskside" é um nome
    /// que uma pasta do Explorer pode ter, e mandar `ShowWindow` na janela de
    /// outra pessoa seria um jeito criativo de assombrar o usuário.
    fn achar_janela() -> Option<isize> {
        let titulo: Vec<u16> = "Deskside".encode_utf16().chain(std::iter::once(0)).collect();
        let meu_pid = unsafe { GetCurrentProcessId() };
        let mut atual = 0isize;
        loop {
            atual = unsafe { FindWindowExW(0, atual, std::ptr::null(), titulo.as_ptr()) };
            if atual == 0 {
                return None;
            }
            let mut pid = 0u32;
            unsafe { GetWindowThreadProcessId(atual, &mut pid) };
            if pid == meu_pid {
                return Some(atual);
            }
        }
    }

    /// Traz a janela para a frente. Chamável de qualquer thread.
    ///
    /// **Pelo Win32, e não só pelo `egui`.** Esta função já foi só um
    /// `send_viewport_cmd(Visible(true))`, e não funcionava: uma janela
    /// escondida não recebe `WM_PAINT`, então o `eframe` não chama `update`, e
    /// é dentro do `update` que os comandos de viewport são aplicados. O
    /// pedido ficava na fila para sempre. O sintoma era o pior tipo - o atalho
    /// simplesmente não fazia nada, sem erro nenhum.
    ///
    /// `ShowWindow` não passa pelo laço do `egui`: fala com o Windows direto.
    /// Uma vez visível, a janela volta a receber `WM_PAINT` e o `eframe`
    /// retoma o comando. Os comandos de viewport continuam sendo enviados
    /// depois, para o estado interno do `egui` concordar com a realidade.
    /// Espera o servidor confirmar e desinstala — mas **não espera para sempre**.
    ///
    /// Quem desinstala é esta thread, e não o laço de rede, por causa do caso
    /// que mais precisa do botão: o computador sem internet. Ali o laço nem
    /// está rodando, e um botão que só funciona online seria pior que nenhum —
    /// falharia calado, exatamente para quem já está desconfiado.
    ///
    /// A ordem é avisar primeiro e apagar depois. O contrário deixa o pior dos
    /// dois mundos se a rede cair no meio: o programa some do disco e o
    /// computador continua na conta, sem ninguém para desfazer o vínculo.
    ///
    /// Seis segundos de espera, e depois vai assim mesmo. Um botão de sair que
    /// depende de o servidor responder não é uma saída — é um pedido.
    fn desinstalar_em_segundo_plano(estado: Compartilhado) {
        use std::time::{Duration, Instant};

        std::thread::spawn(move || {
            if let Ok(mut e) = estado.lock() {
                e.desinstalar = true;
            }
            let limite = Instant::now() + Duration::from_secs(6);
            while Instant::now() < limite {
                if estado.lock().map(|e| e.desparear_ok).unwrap_or(false) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(200));
            }
            let _ = crate::setup::uninstall_completo();
            std::process::exit(0);
        });
    }

    pub fn mostrar_janela() {
        match achar_janela() {
            Some(janela) => unsafe {
                if IsIconic(janela) != 0 {
                    ShowWindow(janela, SW_RESTORE);
                } else {
                    ShowWindow(janela, SW_SHOW);
                }
                SetForegroundWindow(janela);
            },
            None => crate::diario("janela: não achei a janela deste processo"),
        }
        if let Some(ctx) = CONTEXTO.get() {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
            ctx.request_repaint();
        }
    }

    fn icone_bandeja() -> Option<tray_icon::Icon> {
        let png = include_bytes!("../assets/tray.png");
        let img = image::load_from_memory(png).ok()?.to_rgba8();
        let (largura, altura) = img.dimensions();
        tray_icon::Icon::from_rgba(img.into_raw(), largura, altura).ok()
    }

    fn icone_janela() -> Option<egui::IconData> {
        let png = include_bytes!("../assets/tray.png");
        let img = image::load_from_memory(png).ok()?.to_rgba8();
        let (width, height) = img.dimensions();
        Some(egui::IconData {
            rgba: img.into_raw(),
            width,
            height,
        })
    }

    struct App {
        estado: Compartilhado,
        /// Precisa continuar vivo: descartar o `TrayIcon` some com o ícone.
        _bandeja: Option<TrayIcon>,
        id_abrir: MenuId,
        id_sair: MenuId,
        id_desinstalar: MenuId,
        copiado: bool,
        /// A confirmação de desinstalar está à mostra.
        confirmando_saida: bool,
        /// Já clicou em desinstalar: a thread de saída está trabalhando.
        saindo: bool,
    }

    impl App {
        fn new(cc: &eframe::CreationContext<'_>, estado: Compartilhado) -> Self {
            let _ = CONTEXTO.set(cc.egui_ctx.clone());

            let abrir = MenuItem::new("Abrir o Deskside", true, None);
            // Desinstalar mora **na bandeja**, e não só na janela.
            //
            // A janela não abre em máquina sem placa de vídeo — é o caso do
            // MateBook, e é um caso que este arquivo já conhecia: o comentário
            // do campo `aviso` diz, com todas as letras, que "um aviso que só
            // funciona em computador com GPU não serve para um produto de
            // acesso remoto". O botão de sair do produto foi parar exatamente
            // ali, e nessas máquinas não havia como removê-lo pela interface.
            let desinstalar = MenuItem::new("Desinstalar o Deskside", true, None);
            let sair = MenuItem::new("Sair", true, None);
            let (id_abrir, id_sair) = (abrir.id().clone(), sair.id().clone());
            let id_desinstalar = desinstalar.id().clone();

            let menu = Menu::new();
            let _ = menu.append(&abrir);
            let _ = menu.append(&tray_icon::menu::PredefinedMenuItem::separator());
            let _ = menu.append(&desinstalar);
            let _ = menu.append(&sair);

            let mut construtor = TrayIconBuilder::new()
                .with_menu(Box::new(menu))
                .with_tooltip("Deskside");
            if let Some(icone) = icone_bandeja() {
                construtor = construtor.with_icon(icone);
            }
            // Sem bandeja o agente continua inteiro: perde-se o ícone, não o
            // controle remoto.
            let bandeja = construtor.build().ok();

            // As duas filas de eventos da bandeja são globais e bloqueantes.
            // Escutá-las aqui dentro do `update` não serviria: com a janela
            // escondida o `update` quase não roda, e o menu ficaria morto -
            // justamente quando ele é a única forma de abrir a janela.
            escutar_bandeja();

            // O atalho do Menu Iniciar chega por aqui: a segunda instância
            // sinaliza e sai, e quem abre a janela é este agente.
            std::thread::Builder::new()
                .name("deskside-atalho".into())
                .spawn(|| {
                    crate::instance::escutar_pedidos_de_janela(|| {
                        crate::diario("janela: pedida pelo atalho");
                        mostrar_janela();
                    })
                })
                .ok();

            // Um código de pareamento é a única coisa que justifica
            // interromper o usuário: é tarefa com prazo, e ninguém vai
            // adivinhar que precisa abrir a janela para vê-la.
            //
            // O aviso vem da rede, e não daqui: com a janela escondida o
            // `update` não roda, e conferir o código lá dentro era conferir
            // num lugar que só executa quando a janela **já** está aberta.
            crate::notify::ao_receber_codigo(|| {
                crate::diario("janela: pedida pelo código de pareamento");
                mostrar_janela();
            });

            // Pelo mesmo motivo: um aviso de cinco minutos que só aparece se a
            // janela já estiver aberta não avisa ninguém. Quem quer cancelar
            // precisa ver o aviso sem ter ido procurá-lo.
            ao_surgir_aviso(estado.clone(), |_| {
                crate::diario("janela: pedida por automação agendada");
                mostrar_janela();
            });

            crate::diario(&format!(
                "interface iniciada (bandeja: {})",
                if bandeja.is_some() { "sim" } else { "NÃO" }
            ));

            Self {
                estado,
                _bandeja: bandeja,
                id_abrir,
                id_sair,
                id_desinstalar,
                copiado: false,
                confirmando_saida: false,
                saindo: false,
            }
        }
    }

    /// Quantos minutos faltam para a automação avisada rodar.
    ///
    /// Recalculado a cada desenho a partir do relógio, e não recebido pronto:
    /// uma contagem guardada envelheceria entre um quadro e outro, e a janela
    /// diria "5 minutos" pelos cinco minutos inteiros.
    fn faltam_minutos(aviso: &AvisoDeAgenda) -> i32 {
        crate::agenda::agora_local()
            .map(|(_, _, agora)| aviso.minuto_do_dia as i32 - agora as i32)
            .unwrap_or(crate::agenda::AVISO_MINUTOS)
            .max(0)
    }

    /// Chama `ao_aparecer` uma vez para cada aviso novo da agenda.
    ///
    /// Uma thread que consulta, e não um canal: o aviso é um estado ("é isto
    /// que vai rodar"), não uma sequência de eventos, e quem escreve não pode
    /// esperar quem lê — quem publica o aviso é o mesmo laço que mantém o
    /// computador alcançável.
    fn ao_surgir_aviso(estado: Compartilhado, ao_aparecer: impl Fn(AvisoDeAgenda) + Send + 'static) {
        std::thread::Builder::new()
            .name("deskside-agenda".into())
            .spawn(move || {
                let mut mostrado: Option<String> = None;
                loop {
                    let atual = estado.lock().ok().and_then(|e| e.aviso.clone());
                    // O identificador é o que evita repetir: o mesmo aviso fica
                    // de pé por cinco minutos, e sem esta conferência a caixa
                    // reapareceria a cada consulta.
                    match atual {
                        Some(a) if mostrado.as_deref() != Some(&a.id) => {
                            mostrado = Some(a.id.clone());
                            ao_aparecer(a);
                        }
                        None => mostrado = None,
                        _ => {}
                    }
                    std::thread::sleep(std::time::Duration::from_secs(2));
                }
            })
            .ok();
    }

    /// Threads que ficam ouvindo o ícone da bandeja.
    fn escutar_bandeja() {
        std::thread::Builder::new()
            .name("deskside-bandeja".into())
            .spawn(|| {
                let fila = TrayIconEvent::receiver();
                while let Ok(evento) = fila.recv() {
                    // Duplo clique é o gesto que todo mundo já tenta primeiro.
                    if matches!(evento, TrayIconEvent::DoubleClick { .. }) {
                        mostrar_janela();
                    }
                }
            })
            .ok();
    }

    impl eframe::App for App {
        fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
            // Fechar no X esconde. Sair de verdade é só pelo menu da bandeja:
            // um X que encerrasse o agente faria o computador sumir do app, e
            // fechar uma janela é o gesto mais inocente que existe.
            if ctx.input(|i| i.viewport().close_requested()) {
                ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
                self.copiado = false;
            }

            while let Ok(evento) = MenuEvent::receiver().try_recv() {
                if evento.id == self.id_abrir {
                    mostrar_janela();
                } else if evento.id == self.id_desinstalar {
                    if caixa_de_desinstalar() {
                        desinstalar_em_segundo_plano(self.estado.clone());
                    }
                } else if evento.id == self.id_sair {
                    // O agente vive numa thread solta; encerrar o processo é o
                    // jeito honesto de parar tudo de uma vez.
                    std::process::exit(0);
                }
            }

            let estado = self.estado.lock().map(|e| e.clone()).unwrap_or_default();
            let codigo = crate::notify::codigo_pendente();

            egui::CentralPanel::default().show(ctx, |ui| {
                self.desenhar(ui, &estado, codigo);
            });

            // Escondida, a janela não recebe nada do sistema. Este pedido é o
            // que mantém o estado da tela vivo e faz a janela reagir a uma
            // conexão que cai enquanto ela está aberta.
            ctx.request_repaint_after(std::time::Duration::from_millis(700));
        }
    }

    impl App {
        fn desenhar(
            &mut self,
            ui: &mut egui::Ui,
            estado: &Estado,
            codigo: Option<(String, u64)>,
        ) {
            ui.add_space(8.0);
            ui.heading("Deskside");
            ui.label(
                egui::RichText::new(format!("versão {}", estado.versao))
                    .small()
                    .weak(),
            );
            ui.add_space(12.0);

            if let Some((code, expira_em)) = codigo {
                self.desenhar_pareamento(ui, &code, expira_em);
                ui.add_space(12.0);
            }

            if let Some(aviso) = estado.aviso.clone() {
                self.desenhar_aviso(ui, &aviso);
                ui.add_space(12.0);
            }

            ui.group(|ui| {
                ui.set_width(ui.available_width());
                let (cor, texto) = if estado.conectado {
                    (egui::Color32::from_rgb(0x2e, 0xa0, 0x43), "Conectado")
                } else {
                    (egui::Color32::from_rgb(0xd1, 0x24, 0x2f), "Sem conexão")
                };
                ui.horizontal(|ui| {
                    ui.colored_label(cor, "●");
                    ui.label(egui::RichText::new(texto).strong());
                });
                if !estado.conectado {
                    if let Some(erro) = &estado.ultimo_erro {
                        // O motivo importa: "sem conexão" sozinho manda a
                        // pessoa reiniciar o computador à toa.
                        ui.label(egui::RichText::new(erro).small().weak());
                    }
                }
            });

            ui.add_space(12.0);
            linha(ui, "Computador", &estado.hostname);
            linha(ui, "Servidor", &estado.backend);
            linha(ui, "Identificador", &estado.device_id);
            linha(
                ui,
                "Manter pronto",
                match (estado.keep_awake, estado.segurando) {
                    (false, _) => "desligado",
                    (true, true) => "ativo agora",
                    // Ligado sem estar segurando é o estado que confunde, e é
                    // exatamente o que se explica aqui em vez de esconder.
                    (true, false) => "ligado (na bateria, sem efeito)",
                },
            );

            ui.add_space(16.0);
            ui.label(
                egui::RichText::new(
                    "Fechar esta janela não encerra o Deskside. \
                     Para sair, use o ícone ao lado do relógio.",
                )
                .small()
                .weak(),
            );

            ui.add_space(20.0);
            self.desenhar_desinstalar(ui);
        }

        /// Sair de vez, e por que este botão existe.
        ///
        /// Um programa que roda escondido no logon, controla mouse e teclado e
        /// é difícil de remover é **comportamentalmente idêntico** a um vírus
        /// de acesso remoto. A coisa mais tranquilizadora que um software
        /// destes pode fazer é tornar a saída fácil e visível — e é aqui que a
        /// pessoa está quando decide.
        ///
        /// Já dava para desinstalar por "Aplicativos instalados", mas mandar
        /// alguém procurar em Configurações no momento em que ela desconfia do
        /// programa é atrito suficiente para ela desistir e continuar
        /// desconfiando.
        fn desenhar_desinstalar(&mut self, ui: &mut egui::Ui) {
            let vermelho = egui::Color32::from_rgb(0xd1, 0x24, 0x2f);

            if !self.confirmando_saida {
                // Discreto de propósito: é a única ação desta janela que não
                // pode ser clicada por engano, e o lugar de um botão perigoso
                // é no fim, pequeno, longe do resto.
                if ui
                    .add(egui::Button::new(
                        egui::RichText::new("Desinstalar o Deskside").small(),
                    ))
                    .clicked()
                {
                    self.confirmando_saida = true;
                }
                return;
            }

            ui.group(|ui| {
                ui.set_width(ui.available_width());
                ui.label(
                    egui::RichText::new("Desinstalar o Deskside?")
                        .strong()
                        .color(vermelho),
                );
                ui.add_space(4.0);
                // O que vai acontecer, item a item. Um "tem certeza?" seco faz
                // a pessoa clicar em sim sem saber o que perde.
                ui.label(
                    egui::RichText::new(
                        "• este computador sai da sua conta\n                         • o programa para de iniciar com o Windows\n                         • os arquivos do Deskside são apagados",
                    )
                    .small(),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new(
                        "Seus arquivos e programas não são tocados. \
                         Para voltar, é só instalar de novo e parear.",
                    )
                    .small()
                    .weak(),
                );
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if ui.button("Agora não").clicked() {
                        self.confirmando_saida = false;
                    }
                    if ui
                        .add(egui::Button::new(
                            egui::RichText::new("Desinstalar").color(egui::Color32::WHITE),
                        )
                        .fill(vermelho))
                        .clicked()
                    {
                        self.saindo = true;
                        desinstalar_em_segundo_plano(self.estado.clone());
                    }
                });
                if self.saindo {
                    ui.add_space(6.0);
                    ui.label(egui::RichText::new("Desinstalando...").small().weak());
                }
            });
        }

        /// A automação que vai rodar em instantes, com a saída de emergência.
        ///
        /// O botão é o recurso inteiro: uma automação que fecha tudo às 18h sem
        /// jeito de dizer "hoje não" é uma promessa de perder trabalho, e
        /// bastaria uma vez para ninguém mais agendar nada.
        fn desenhar_aviso(&mut self, ui: &mut egui::Ui, aviso: &AvisoDeAgenda) {
            ui.group(|ui| {
                ui.set_width(ui.available_width());
                ui.label(
                    egui::RichText::new("Automação agendada")
                        .strong()
                        .color(egui::Color32::from_rgb(0xd9, 0x7a, 0x00)),
                );
                ui.add_space(4.0);
                ui.label(egui::RichText::new(&aviso.nome).strong());
                let faltam = faltam_minutos(aviso);
                ui.label(
                    egui::RichText::new(if faltam > 1 {
                        format!("Roda em {faltam} minutos.")
                    } else {
                        "Roda em instantes.".to_string()
                    })
                    .small(),
                );
                ui.add_space(6.0);
                if ui.button("Cancelar por hoje").clicked() {
                    if let Ok(mut e) = self.estado.lock() {
                        e.cancelar = Some(aviso.id.clone());
                        // Sumir com o aviso agora, e não esperar o laço de rede
                        // confirmar: dez segundos de botão que já foi clicado e
                        // continua ali é o que faz a pessoa clicar de novo.
                        e.aviso = None;
                    }
                }
            });
        }

        fn desenhar_pareamento(&mut self, ui: &mut egui::Ui, code: &str, expira_em: u64) {
            ui.group(|ui| {
                ui.set_width(ui.available_width());
                ui.label(egui::RichText::new("Código de pareamento").strong());
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new(code)
                        .monospace()
                        .size(32.0)
                        .color(egui::Color32::from_rgb(0x4a, 0x7c, 0xff)),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new(format!(
                        "Digite este código no aplicativo. Expira em {} min.",
                        expira_em / 60
                    ))
                    .small(),
                );
                ui.add_space(6.0);
                if ui.button("Copiar").clicked() {
                    ui.ctx().copy_text(code.to_string());
                    self.copiado = true;
                }
                if self.copiado {
                    ui.label(egui::RichText::new("Copiado.").small().weak());
                }
            });
        }
    }

    fn linha(ui: &mut egui::Ui, rotulo: &str, valor: &str) {
        ui.horizontal(|ui| {
            ui.label(egui::RichText::new(rotulo).weak());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(valor);
            });
        });
    }

    pub fn rodar(estado: Compartilhado) {
        let mut viewport = egui::ViewportBuilder::default()
            .with_inner_size([420.0, 520.0])
            .with_resizable(false)
            // Nasce escondida: quem instalou quer o agente subindo no login
            // sem nada piscando na tela.
            .with_visible(false);
        if let Some(icone) = icone_janela() {
            viewport = viewport.with_icon(std::sync::Arc::new(icone));
        }

        let opcoes = eframe::NativeOptions {
            viewport,
            // DX12, e não OpenGL. Ver o comentário no Cargo.toml: a versão com
            // `glow` morria com "requires opengl 2.0+" em máquina virtual e em
            // sessão de Área de Trabalho Remota.
            renderer: eframe::Renderer::Wgpu,
            wgpu_options: configuracao_wgpu(),
            ..Default::default()
        };

        let estado_reserva = estado.clone();
        let resultado = eframe::run_native(
            "Deskside",
            opcoes,
            Box::new(|cc| Ok(Box::new(App::new(cc, estado)))),
        );

        // A janela não abrir não pode parar o agente, que roda noutra thread.
        if let Err(e) = resultado {
            crate::diario(&format!("A janela não abriu ({e}); indo para a bandeja simples."));
            bandeja_sem_placa_de_video(estado_reserva);
        }
    }

    /// Interface para máquina sem placa de vídeo nenhuma.
    ///
    /// Existe porque uma máquina virtual real respondeu **zero adaptadores**:
    /// sem Vulkan, sem DX12 e sem OpenGL 2.0, e nem o renderizador por
    /// software do Windows aparecia. Não é caso exótico - sessão de Área de
    /// Trabalho Remota, VM de nuvem e Windows enxuto caem no mesmo lugar, e
    /// num produto de controle remoto essas são justamente as máquinas onde
    /// alguém vai instalar o agente.
    ///
    /// O que se perde: a janela com o texto grande. O que se mantém: o ícone
    /// ao lado do relógio, o menu, o estado e o código de pareamento - tudo em
    /// caixas do próprio Windows, que desenham sem placa de vídeo. É menos
    /// bonito e é infinitamente melhor que nada, que era o que essas máquinas
    /// tinham.
    fn bandeja_sem_placa_de_video(estado: Compartilhado) {
        let abrir = MenuItem::new("Estado do Deskside", true, None);
        // Aqui é o **único** lugar de onde dá para desinstalar pela interface:
        // esta máquina não abre janela nenhuma.
        let desinstalar = MenuItem::new("Desinstalar o Deskside", true, None);
        let sair = MenuItem::new("Sair", true, None);
        let (id_abrir, id_sair) = (abrir.id().clone(), sair.id().clone());
        let id_desinstalar = desinstalar.id().clone();

        let menu = Menu::new();
        let _ = menu.append(&abrir);
        let _ = menu.append(&tray_icon::menu::PredefinedMenuItem::separator());
        let _ = menu.append(&desinstalar);
        let _ = menu.append(&sair);

        let mut construtor = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip("Deskside");
        if let Some(icone) = icone_bandeja() {
            construtor = construtor.with_icon(icone);
        }
        // O ícone tem que nascer nesta thread: é ela que vai bombear as
        // mensagens do Windows, e no Windows um ícone de bandeja pertence à
        // fila de mensagens de quem o criou.
        let _bandeja = construtor.build().ok();
        crate::diario(&format!(
            "bandeja simples ({})",
            if _bandeja.is_some() { "criada" } else { "FALHOU" }
        ));

        // Sem janela, estas três coisas viram caixas do Windows.
        let do_menu = estado.clone();
        std::thread::Builder::new()
            .name("deskside-menu".into())
            .spawn(move || {
                while let Ok(evento) = MenuEvent::receiver().recv() {
                    if evento.id == id_abrir {
                        caixa_de_estado(&do_menu);
                    } else if evento.id == id_desinstalar {
                        if caixa_de_desinstalar() {
                            desinstalar_em_segundo_plano(do_menu.clone());
                        }
                    } else if evento.id == id_sair {
                        std::process::exit(0);
                    }
                }
            })
            .ok();

        let do_duplo_clique = estado.clone();
        std::thread::Builder::new()
            .name("deskside-bandeja".into())
            .spawn(move || {
                while let Ok(evento) = TrayIconEvent::receiver().recv() {
                    if matches!(evento, TrayIconEvent::DoubleClick { .. }) {
                        caixa_de_estado(&do_duplo_clique);
                    }
                }
            })
            .ok();

        let do_atalho = estado.clone();
        std::thread::Builder::new()
            .name("deskside-atalho".into())
            .spawn(move || {
                crate::instance::escutar_pedidos_de_janela(|| caixa_de_estado(&do_atalho))
            })
            .ok();

        // Sem janela, o aviso da agenda também vira caixa - e é aqui que ele
        // mais importa: esta é a máquina em que a janela não abre, e um recurso
        // que só avisa em computador com placa de vídeo não serve.
        let da_agenda = estado.clone();
        ao_surgir_aviso(estado.clone(), move |aviso| {
            if !caixa_de_aviso(&aviso) {
                return;
            }
            if let Ok(mut e) = da_agenda.lock() {
                // A caixa fica aberta enquanto a pessoa decide, e nesse tempo a
                // automação pode ter rodado. Cancelar depois do disparo seria
                // registrar um cancelamento que não cancelou nada.
                if e.aviso.as_ref().is_some_and(|v| v.id == aviso.id) {
                    e.cancelar = Some(aviso.id.clone());
                    e.aviso = None;
                }
            }
        });

        crate::notify::ao_receber_codigo(|| {
            if let Some((code, expira)) = crate::notify::codigo_pendente() {
                caixa_de_pareamento(&code, expira);
            }
        });
        // Um código que chegou enquanto a janela tentava abrir não pode se
        // perder no meio da troca.
        if let Some((code, expira)) = crate::notify::codigo_pendente() {
            caixa_de_pareamento(&code, expira);
        }

        // O laço de mensagens. Sem ele o ícone aparece e não responde a nada:
        // no Windows quem entrega clique de bandeja é a fila de mensagens da
        // thread que criou o ícone, e ninguém mais.
        let mut msg = Msg::default();
        loop {
            let r = unsafe { GetMessageW(&mut msg, 0, 0, 0) };
            if r <= 0 {
                break;
            }
            unsafe {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }

    /// O estado do agente numa caixa do Windows.
    fn caixa_de_estado(estado: &Compartilhado) {
        let e = estado.lock().map(|e| e.clone()).unwrap_or_default();
        let texto = format!(
            "Deskside {}\n\n\
             {}\n\n\
             Computador: {}\n\
             Servidor: {}\n\
             Identificador: {}\n\
             Manter pronto: {}\n\n\
             Esta máquina não tem placa de vídeo disponível, por isso o \
             Deskside mostra o estado aqui em vez de numa janela própria. \
             O controle remoto funciona normalmente.",
            e.versao,
            if e.conectado {
                "Conectado".to_string()
            } else {
                match &e.ultimo_erro {
                    Some(erro) => format!("Sem conexão: {erro}"),
                    None => "Sem conexão".to_string(),
                }
            },
            e.hostname,
            e.backend,
            e.device_id,
            match (e.keep_awake, e.segurando) {
                (false, _) => "desligado",
                (true, true) => "ativo agora",
                (true, false) => "ligado (na bateria, sem efeito)",
            },
        );
        caixa(&texto);
    }

    /// Escolhe a placa de vídeo, aceitando as de software.
    ///
    /// Isto existe por causa de uma linha do `egui-wgpu`: por padrão ele pede
    /// um adaptador com `force_fallback_adapter: false`, e o WARP - o
    /// renderizador por software que **todo** Windows 10+ tem - nunca chega a
    /// ser considerado. Numa máquina virtual sem placa de vídeo acessível, a
    /// resposta é "no suitable adapter found" e a janela não abre, embora o
    /// Windows tenha ali o que desenhá-la.
    ///
    /// A ordem de preferência é a óbvia: placa dedicada, integrada, virtual e,
    /// por último, software. Uma janela que mostra cinco linhas de texto não
    /// perde nada rodando por software - e é a diferença entre existir e não
    /// existir na máquina de quem instalou.
    fn escolher_adaptador(
        adaptadores: &[eframe::wgpu::Adapter],
        superficie: Option<&eframe::wgpu::Surface<'_>>,
    ) -> Result<eframe::wgpu::Adapter, String> {
        use eframe::wgpu::DeviceType;

        let serve = |a: &eframe::wgpu::Adapter| match superficie {
            Some(s) => a.is_surface_supported(s),
            None => true,
        };
        let nota = |t: DeviceType| match t {
            DeviceType::DiscreteGpu => 0,
            DeviceType::IntegratedGpu => 1,
            DeviceType::VirtualGpu => 2,
            DeviceType::Cpu => 3,
            DeviceType::Other => 4,
        };

        let escolhido = adaptadores
            .iter()
            .filter(|a| serve(a))
            .min_by_key(|a| nota(a.get_info().device_type))
            .cloned();

        match escolhido {
            Some(a) => {
                let info = a.get_info();
                crate::diario(&format!(
                    "janela: usando {} ({:?}, {:?})",
                    info.name, info.device_type, info.backend
                ));
                Ok(a)
            }
            None => Err(format!(
                "nenhum adaptador serve a esta janela ({} encontrado(s))",
                adaptadores.len()
            )),
        }
    }

    fn configuracao_wgpu() -> eframe::egui_wgpu::WgpuConfiguration {
        let mut cfg = eframe::egui_wgpu::WgpuConfiguration::default();
        if let eframe::egui_wgpu::WgpuSetup::CreateNew(novo) = &mut cfg.wgpu_setup {
            novo.native_adapter_selector =
                Some(std::sync::Arc::new(|adaptadores, superficie| {
                    escolher_adaptador(adaptadores, superficie)
                }));
        }
        cfg
    }

    const MB_OK: u32 = 0x0000_0000;
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONINFORMATION: u32 = 0x0000_0040;
    const MB_ICONWARNING: u32 = 0x0000_0030;
    /// Sem isto o botão em foco é o "Sim", e um Enter distraído cancelaria a
    /// automação. O padrão tem que ser deixar acontecer o que foi agendado.
    const MB_DEFBUTTON2: u32 = 0x0000_0100;
    const MB_SETFOREGROUND: u32 = 0x0001_0000;
    const MB_TOPMOST: u32 = 0x0004_0000;
    const ID_YES: i32 = 6;

    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(dono: isize, texto: *const u16, titulo: *const u16, tipo: u32) -> i32;
    }

    /// Última linha de defesa: o código numa caixa do próprio Windows.
    fn caixa_de_pareamento(code: &str, expira_em: u64) {
        caixa(&format!(
            "Código de pareamento:\n\n{code}\n\nDigite este código no aplicativo.\n\
             Expira em {} min.",
            expira_em / 60
        ));
    }

    /// Pergunta se a automação agendada deve ser cancelada hoje. `true` = sim.
    ///
    /// Bloqueia de propósito, ao contrário de `caixa`: quem chama é a thread da
    /// agenda, criada só para isto, e a resposta é o motivo da caixa existir.
    /// Enquanto ela está aberta, essa thread não consulta o estado - e é
    /// exatamente o que se quer, porque a pergunta já está na tela.
    fn caixa_de_aviso(aviso: &AvisoDeAgenda) -> bool {
        let faltam = faltam_minutos(aviso);
        let texto = format!(
            "A automação \"{}\" vai rodar {}.\n\n\
             Cancelar por hoje?\n\n\
             Ela volta a valer amanhã no horário de sempre.",
            aviso.nome,
            if faltam > 1 {
                format!("em {faltam} minutos")
            } else {
                "em instantes".to_string()
            }
        );
        let texto: Vec<u16> = texto.encode_utf16().chain(std::iter::once(0)).collect();
        let titulo: Vec<u16> = "Deskside"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let resposta = unsafe {
            MessageBoxW(
                0,
                texto.as_ptr(),
                titulo.as_ptr(),
                MB_YESNO
                    | MB_ICONWARNING
                    | MB_DEFBUTTON2
                    | MB_SETFOREGROUND
                    | MB_TOPMOST,
            )
        };
        resposta == ID_YES
    }

    /// Pergunta se o Deskside deve se desinstalar. `true` = sim.
    ///
    /// Bloqueia quem chama, como a `caixa_de_aviso`: quem pergunta é a thread
    /// do menu da bandeja, e a resposta é o motivo da pergunta existir.
    ///
    /// O `MB_DEFBUTTON2` põe o foco no "Não". Um Enter distraído no menu não
    /// pode desinstalar o programa — o padrão de uma pergunta destrutiva é
    /// sempre não fazer nada.
    fn caixa_de_desinstalar() -> bool {
        let texto = "Desinstalar o Deskside deste computador?\n\n\
             • este computador sai da sua conta\n\
             • o programa para de iniciar com o Windows\n\
             • os arquivos do Deskside são apagados\n\n\
             Seus arquivos e programas não são tocados.\n\
             Para voltar, é só instalar de novo e parear.";
        let texto: Vec<u16> = texto.encode_utf16().chain(std::iter::once(0)).collect();
        let titulo: Vec<u16> = "Deskside"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let resposta = unsafe {
            MessageBoxW(
                0,
                texto.as_ptr(),
                titulo.as_ptr(),
                MB_YESNO
                    | MB_ICONWARNING
                    | MB_DEFBUTTON2
                    | MB_SETFOREGROUND
                    | MB_TOPMOST,
            )
        };
        resposta == ID_YES
    }

    /// Mostra um texto numa caixa do Windows, sem travar quem chamou.
    ///
    /// A thread própria não é zelo: `MessageBoxW` só volta quando alguém fecha
    /// a caixa, e quem chama aqui costuma ser a thread de rede do agente ou a
    /// que bombeia as mensagens da bandeja. Bloquear qualquer uma das duas
    /// pararia o controle remoto até alguém clicar em OK.
    fn caixa(texto: &str) {
        let texto = texto.to_string();
        std::thread::spawn(move || {
            let texto: Vec<u16> = texto.encode_utf16().chain(std::iter::once(0)).collect();
            let titulo: Vec<u16> = "Deskside"
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            unsafe {
                MessageBoxW(
                    0,
                    texto.as_ptr(),
                    titulo.as_ptr(),
                    MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST,
                )
            };
        });
    }

    /// A `MSG` do Windows. Só precisa do tamanho e da ordem certos: quem lê os
    /// campos é o próprio sistema.
    #[repr(C)]
    #[derive(Default)]
    struct Msg {
        hwnd: isize,
        message: u32,
        wparam: usize,
        lparam: isize,
        time: u32,
        pt_x: i32,
        pt_y: i32,
    }

    #[link(name = "user32")]
    extern "system" {
        fn GetMessageW(msg: *mut Msg, janela: isize, primeira: u32, ultima: u32) -> i32;
        fn TranslateMessage(msg: *const Msg) -> i32;
        fn DispatchMessageW(msg: *const Msg) -> isize;
    }
}

#[cfg(not(windows))]
mod imp {
    use super::Compartilhado;

    pub fn rodar(_estado: Compartilhado) {
        // No desenvolvimento o agente roda à vista, no terminal: a saída dele
        // já é a interface. Uma janela aqui seria peso sem uso.
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn o_estado_atravessa_as_threads() {
        let estado = compartilhar(Estado {
            hostname: "pc".into(),
            ..Default::default()
        });
        let copia = estado.clone();
        std::thread::spawn(move || {
            copia.lock().unwrap().conectado = true;
        })
        .join()
        .unwrap();
        assert!(estado.lock().unwrap().conectado);
        assert_eq!(estado.lock().unwrap().hostname, "pc");
    }
}
