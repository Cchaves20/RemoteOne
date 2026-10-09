//! As duas permissões que o Mac exige de um programa de controle remoto.
//!
//! - **Gravação de Tela**: sem ela, a captura não falha — devolve a imagem só
//!   com o papel de parede e a barra de menus, sem janela nenhuma. O app
//!   mostraria "uma tela" e ninguém entenderia o que está errado.
//! - **Acessibilidade**: sem ela, os cliques e as teclas que o agente manda são
//!   descartados pelo sistema **em silêncio**. Nem o `enigo` fica sabendo.
//!
//! Nenhuma das duas pode ser ligada pelo próprio programa: o Mac só deixa
//! pedir. O pedido abre a caixa do sistema uma vez e põe o Deskside na lista de
//! Ajustes do Sistema › Privacidade e Segurança, desligado; quem liga é a
//! pessoa. Por isso o agente pergunta o estado e a janela explica o que falta
//! (ver `gui.rs`), em vez de supor que deu certo.
//!
//! ## E a assinatura
//!
//! O Mac guarda a permissão pela assinatura do programa. Um agente com
//! assinatura diferente a cada versão perderia as duas a cada atualização —
//! por isso a distribuição precisa sair sempre com o mesmo Developer ID (ver
//! `docs/agente-mac.md`).

use std::ffi::c_void;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(opcoes: *const c_void) -> bool;
}

/// Uma das duas permissões, com o endereço do painel que a liga.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Permissao {
    GravacaoDeTela,
    Acessibilidade,
}

impl Permissao {
    pub const TODAS: [Permissao; 2] = [Permissao::GravacaoDeTela, Permissao::Acessibilidade];

    /// O nome como aparece nos Ajustes do Sistema, para a pessoa achar.
    pub fn nome(self) -> &'static str {
        match self {
            Permissao::GravacaoDeTela => "Gravação de Tela",
            Permissao::Acessibilidade => "Acessibilidade",
        }
    }

    /// Para que serve, na frase que a janela mostra.
    pub fn para_que(self) -> &'static str {
        match self {
            Permissao::GravacaoDeTela => "para o celular ver a tela",
            Permissao::Acessibilidade => "para o celular mexer o mouse e digitar",
        }
    }

    fn painel(self) -> &'static str {
        match self {
            Permissao::GravacaoDeTela => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            }
            Permissao::Acessibilidade => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
        }
    }

    /// Se a pessoa já liberou. Só pergunta, não abre caixa nenhuma.
    pub fn liberada(self) -> bool {
        unsafe {
            match self {
                Permissao::GravacaoDeTela => CGPreflightScreenCaptureAccess(),
                Permissao::Acessibilidade => AXIsProcessTrusted(),
            }
        }
    }

    /// Pede ao sistema: abre a caixa dele (só na primeira vez) e põe o
    /// Deskside na lista dos Ajustes.
    pub fn pedir(self) {
        unsafe {
            match self {
                Permissao::GravacaoDeTela => {
                    CGRequestScreenCaptureAccess();
                }
                Permissao::Acessibilidade => {
                    pedir_acessibilidade();
                }
            }
        }
    }

    /// Abre os Ajustes do Sistema direto no painel desta permissão.
    pub fn abrir_ajustes(self) {
        if let Err(e) = std::process::Command::new("/usr/bin/open")
            .arg(self.painel())
            .spawn()
        {
            crate::diario(&format!("não consegui abrir os Ajustes do Sistema: {e}"));
        }
    }
}

/// `AXIsProcessTrustedWithOptions` com `kAXTrustedCheckOptionPrompt`, que é o
/// que faz aparecer a caixa. O valor da constante é o próprio texto da chave,
/// e um `NSDictionary` é aceito onde se pede `CFDictionary` (são o mesmo
/// objeto por baixo).
unsafe fn pedir_acessibilidade() -> bool {
    use objc2_foundation::{NSDictionary, NSNumber, NSString};
    let chave = NSString::from_str("AXTrustedCheckOptionPrompt");
    let sim = NSNumber::new_bool(true);
    let opcoes = NSDictionary::from_slices(&[&*chave], &[&*sim]);
    AXIsProcessTrustedWithOptions(objc2::rc::Retained::as_ptr(&opcoes).cast())
}

/// Fecha e abre o Deskside de novo.
///
/// Existe porque o Mac só aplica a Gravação de Tela a um processo **novo**:
/// liberar nos Ajustes com o agente aberto não muda nada até ele reiniciar, e
/// pedir à pessoa que saia pelo menu e ache o programa de novo é pedir demais.
///
/// Quem abre a cópia nova é um `sh` solto, um segundo depois de este processo
/// sair — antes disso a guarda de instância a mandaria embora.
pub fn reabrir() {
    let exe = std::env::current_exe().unwrap_or_default();
    // `.../Deskside.app/Contents/MacOS/deskside-agent` → `.../Deskside.app`.
    let pacote = exe
        .ancestors()
        .nth(3)
        .filter(|p| p.extension().is_some_and(|e| e == "app"))
        .map(|p| p.to_path_buf());
    let comando = match pacote {
        Some(app) => format!("sleep 1; /usr/bin/open {}", aspas(&app.to_string_lossy())),
        None => format!("sleep 1; {} &", aspas(&exe.to_string_lossy())),
    };
    match std::process::Command::new("/bin/sh")
        .args(["-c", &comando])
        .spawn()
    {
        Ok(_) => std::process::exit(0),
        Err(e) => crate::diario(&format!("não consegui reabrir: {e}")),
    }
}

/// Um caminho entre aspas simples para o `sh`, com as aspas de dentro
/// escapadas do único jeito que o `sh` aceita.
fn aspas(texto: &str) -> String {
    format!("'{}'", texto.replace('\'', "'\\''"))
}

/// As permissões que ainda faltam.
pub fn faltando() -> Vec<Permissao> {
    Permissao::TODAS
        .into_iter()
        .filter(|p| !p.liberada())
        .collect()
}

/// Na partida do agente: registra o estado no diário e pede o que faltar.
///
/// Pedir aqui, e não só quando o celular tentar usar, porque a caixa do
/// sistema aparece no Mac — e quem está no Mac é a pessoa instalando, não a
/// que vai controlar do sofá mais tarde.
pub fn conferir_na_partida() {
    for p in Permissao::TODAS {
        let liberada = p.liberada();
        crate::diario(&format!(
            "permissão {}: {}",
            p.nome(),
            if liberada { "liberada" } else { "falta" }
        ));
        if !liberada {
            p.pedir();
        }
    }
}
