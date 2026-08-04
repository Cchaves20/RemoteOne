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
    use super::{Compartilhado, Estado};
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

    /// Traz a janela para a frente. Chamável de qualquer thread.
    pub fn mostrar_janela() {
        if let Some(ctx) = CONTEXTO.get() {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
            // Acorda o laço de eventos: escondida, a janela não redesenha
            // sozinha, e sem isto o comando ficaria na fila até alguém mexer.
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
        copiado: bool,
    }

    impl App {
        fn new(cc: &eframe::CreationContext<'_>, estado: Compartilhado) -> Self {
            let _ = CONTEXTO.set(cc.egui_ctx.clone());

            let abrir = MenuItem::new("Abrir o RemoteOne", true, None);
            let sair = MenuItem::new("Sair", true, None);
            let (id_abrir, id_sair) = (abrir.id().clone(), sair.id().clone());

            let menu = Menu::new();
            let _ = menu.append(&abrir);
            let _ = menu.append(&tray_icon::menu::PredefinedMenuItem::separator());
            let _ = menu.append(&sair);

            let mut construtor = TrayIconBuilder::new()
                .with_menu(Box::new(menu))
                .with_tooltip("RemoteOne");
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
                .name("remoteone-atalho".into())
                .spawn(|| crate::instance::escutar_pedidos_de_janela(mostrar_janela))
                .ok();

            Self {
                estado,
                _bandeja: bandeja,
                id_abrir,
                id_sair,
                copiado: false,
            }
        }
    }

    /// Threads que ficam ouvindo o ícone da bandeja.
    fn escutar_bandeja() {
        std::thread::Builder::new()
            .name("remoteone-bandeja".into())
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
                } else if evento.id == self.id_sair {
                    // O agente vive numa thread solta; encerrar o processo é o
                    // jeito honesto de parar tudo de uma vez.
                    std::process::exit(0);
                }
            }

            let estado = self.estado.lock().map(|e| e.clone()).unwrap_or_default();
            let codigo = crate::notify::codigo_pendente();

            // Um código novo é a única coisa aqui que justifica interromper o
            // usuário: é uma tarefa com prazo, e ninguém vai adivinhar que
            // precisa abrir a janela para vê-la.
            if codigo.is_some() && !ctx.input(|i| i.viewport().focused.unwrap_or(false)) {
                mostrar_janela();
            }

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
            ui.heading("RemoteOne");
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
                    "Fechar esta janela não encerra o RemoteOne. \
                     Para sair, use o ícone ao lado do relógio.",
                )
                .small()
                .weak(),
            );
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
            ..Default::default()
        };

        let resultado = eframe::run_native(
            "RemoteOne",
            opcoes,
            Box::new(|cc| Ok(Box::new(App::new(cc, estado)))),
        );

        // A janela não abrir não pode parar o agente, que roda noutra thread.
        // Dormir para sempre é o comportamento certo: o processo continua, o
        // computador continua alcançável, e só a interface se perdeu.
        if let Err(e) = resultado {
            eprintln!("A janela não abriu ({e}); o agente continua rodando.");
            loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            }
        }
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
