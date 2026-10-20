//! Com que teclas sai cada caractere no teclado configurado no computador.
//!
//! No Wayland, o agente manda o teclado pelo **símbolo** de cada tecla, e o
//! compositor procura uma tecla do layout do computador que produza aquele
//! símbolo. Quando não existe — o "é" num teclado inglês (EUA), por exemplo —
//! ele descarta o caractere **em silêncio**. O teste na máquina virtual mostrou
//! isso, e a primeira saída tentada (digitar pelo código Unicode, com
//! Ctrl+Shift+U) piorou tudo: onde o atalho não é tratado, o programa aberto
//! recebe Ctrl, Shift e letras como atalhos, e o mouse saiu pulando e clicando.
//!
//! O caminho daqui usa só teclas que o layout tem, como uma pessoa digitaria:
//!
//! - **tecla própria**: o "ç" no ABNT2, o "é" num teclado francês;
//! - **acento + letra**: o "é" no ABNT2 e no inglês internacional sai de "´"
//!   seguido de "e" — as teclas "mortas";
//! - **impossível**: o layout não tem como fazer o caractere. O agente não
//!   inventa atalho; o caractere fica de fora e o celular é avisado uma vez.
//!
//! O layout vem das configurações do GNOME (a fonte de entrada em uso), e na
//! falta delas, do sistema. O mapa de teclas é calculado pela mesma biblioteca
//! que o compositor usa (`libxkbcommon`), com os arquivos de layout do próprio
//! computador.

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use unicode_normalization::UnicodeNormalization;
use xkbcommon::xkb;

/// Como um caractere é digitado no layout atual.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Plano {
    /// Uma tecla (com Shift ou AltGr, se preciso — isso o compositor resolve).
    Direto(u32),
    /// A tecla morta do acento, e depois a letra.
    Morto { acento: u32, base: u32 },
    /// O layout não tem como fazer este caractere.
    Impossivel,
}

/// O layout em uso e os símbolos que ele alcança.
pub struct Teclado {
    /// "br", "us", "us+intl": como aparece nas mensagens.
    pub nome: String,
    simbolos: HashSet<u32>,
}

impl Teclado {
    /// Monta o mapa de um layout. `None` se a biblioteca não o conhece.
    pub fn de(layout: &str, variante: &str) -> Option<Teclado> {
        let contexto = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let mapa = xkb::Keymap::new_from_names(
            &contexto,
            "evdev",
            "pc105",
            layout,
            variante,
            None,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )?;
        let mut simbolos = HashSet::new();
        let (min, max) = (mapa.min_keycode().raw(), mapa.max_keycode().raw());
        for codigo in min..=max {
            let tecla = xkb::Keycode::new(codigo);
            // Só o primeiro grupo: é o layout em uso. Os outros seriam fontes
            // de entrada que o compositor não está usando agora.
            for nivel in 0..mapa.num_levels_for_key(tecla, 0) {
                for simbolo in mapa.key_get_syms_by_level(tecla, 0, nivel) {
                    simbolos.insert(simbolo.raw());
                }
            }
        }
        let nome = if variante.is_empty() {
            layout.to_string()
        } else {
            format!("{layout}+{variante}")
        };
        Some(Teclado { nome, simbolos })
    }

    fn tem(&self, simbolo: u32) -> bool {
        self.simbolos.contains(&simbolo)
    }

    /// Como digitar `c` neste layout.
    ///
    /// O ASCII imprimível vai direto, sem consulta: está em todo layout
    /// latino, e é o que já funcionava antes desta conferência existir.
    pub fn plano(&self, c: char) -> Plano {
        if c.is_ascii() {
            return Plano::Direto(simbolo_do_caractere(c));
        }
        let direto = simbolo_do_caractere(c);
        if self.tem(direto) {
            return Plano::Direto(direto);
        }
        // Letra + um acento só: "é" = "e" + U+0301.
        let mut partes = std::iter::once(c).nfd();
        if let (Some(base), Some(marca), None) = (partes.next(), partes.next(), partes.next()) {
            if let Some(acento) = tecla_morta(marca) {
                let base = simbolo_do_caractere(base);
                if self.tem(acento) && self.tem(base) {
                    return Plano::Morto { acento, base };
                }
            }
        }
        Plano::Impossivel
    }
}

/// O símbolo (keysym) que produz este caractere.
pub fn simbolo_do_caractere(c: char) -> u32 {
    match c {
        '\n' | '\r' => 0xFF0D,
        '\t' => 0xFF09,
        '\u{8}' => 0xFF08,
        // A mesma tabela que o compositor usa para achar a tecla: "é" é
        // `eacute` (0xE9), "ő" é `odoubleacute` (0x1F5), e o resto do Unicode
        // cai na faixa 0x0100_0000 + código.
        c => xkb::utf32_to_keysym(c as u32).raw(),
    }
}

/// A tecla morta que põe este acento sobre a letra seguinte.
fn tecla_morta(marca: char) -> Option<u32> {
    Some(match marca {
        '\u{0300}' => 0xFE50, // grave: à
        '\u{0301}' => 0xFE51, // agudo: é
        '\u{0302}' => 0xFE52, // circunflexo: ê
        '\u{0303}' => 0xFE53, // til: ã
        '\u{0308}' => 0xFE57, // trema: ü
        '\u{0327}' => 0xFE5B, // cedilha: ç
        _ => return None,
    })
}

/// Lê, do que o GNOME grava, a fonte de entrada em uso.
///
/// O formato é o do `gsettings get`: `[('xkb', 'br'), ('xkb', 'us')]`. A
/// primeira fonte do tipo `xkb` é a que vale — no `mru-sources`, a usada por
/// último, que é a atual. As de outro tipo (`ibus`, para japonês e afins) não
/// são layouts de teclado.
pub fn layout_do_gsettings(texto: &str) -> Option<(String, String)> {
    let mut resto = texto;
    while let Some(i) = resto.find("('") {
        resto = &resto[i + 2..];
        let fim = resto.find('\'')?;
        let tipo = &resto[..fim];
        resto = &resto[fim + 1..];
        let inicio = resto.find('\'')? + 1;
        let fim = resto[inicio..].find('\'')? + inicio;
        let valor = &resto[inicio..fim];
        resto = &resto[fim + 1..];
        if tipo == "xkb" && !valor.is_empty() {
            return Some(match valor.split_once('+') {
                Some((layout, variante)) => (layout.to_string(), variante.to_string()),
                None => (valor.to_string(), String::new()),
            });
        }
    }
    None
}

/// Lê o layout de um arquivo no formato do `/etc/default/keyboard`.
pub fn layout_do_sistema(texto: &str) -> Option<(String, String)> {
    let valor = |chave: &str| {
        texto.lines().find_map(|l| {
            let v = l.trim().strip_prefix(chave)?.strip_prefix('=')?;
            Some(v.trim().trim_matches('"').to_string())
        })
    };
    // Vários layouts ("br,us"): o primeiro é o padrão.
    let layout = valor("XKBLAYOUT")?.split(',').next()?.trim().to_string();
    let variante = valor("XKBVARIANT")
        .unwrap_or_default()
        .split(',')
        .next()
        .unwrap_or("")
        .trim()
        .to_string();
    (!layout.is_empty()).then_some((layout, variante))
}

fn gsettings(chave: &str) -> Option<String> {
    let saida = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.input-sources", chave])
        .output()
        .ok()?;
    saida
        .status
        .success()
        .then(|| String::from_utf8_lossy(&saida.stdout).to_string())
}

/// O layout em uso agora: o do GNOME, ou o do sistema, ou o inglês (EUA).
fn ler_layout() -> (String, String) {
    gsettings("mru-sources")
        .and_then(|t| layout_do_gsettings(&t))
        .or_else(|| gsettings("sources").and_then(|t| layout_do_gsettings(&t)))
        .or_else(|| {
            std::fs::read_to_string("/etc/default/keyboard")
                .ok()
                .and_then(|t| layout_do_sistema(&t))
        })
        .unwrap_or_else(|| ("us".to_string(), String::new()))
}

/// O teclado atual, relido de tempos em tempos: a pessoa pode trocar a fonte
/// de entrada com o agente rodando, e consultar a cada letra custaria um
/// processo por tecla.
pub fn atual() -> std::sync::Arc<Teclado> {
    static CACHE: Mutex<Option<(Instant, std::sync::Arc<Teclado>)>> = Mutex::new(None);
    const VALIDADE: Duration = Duration::from_secs(5);
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((quando, teclado)) = cache.as_ref() {
        if quando.elapsed() < VALIDADE {
            return teclado.clone();
        }
    }
    let (layout, variante) = ler_layout();
    let teclado = std::sync::Arc::new(
        Teclado::de(&layout, &variante)
            .or_else(|| Teclado::de("us", ""))
            // Nem o inglês compilou: sem os arquivos de layout. O ASCII
            // continua indo direto; o resto, pela tentativa de antes.
            .unwrap_or(Teclado {
                nome: layout,
                simbolos: HashSet::new(),
            }),
    );
    *cache = Some((Instant::now(), teclado.clone()));
    teclado
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_a_fonte_de_entrada_do_gnome() {
        assert_eq!(
            layout_do_gsettings("[('xkb', 'br'), ('xkb', 'us')]\n"),
            Some(("br".into(), "".into()))
        );
        assert_eq!(
            layout_do_gsettings("[('ibus', 'mozc-jp'), ('xkb', 'us+intl')]"),
            Some(("us".into(), "intl".into()))
        );
        assert_eq!(layout_do_gsettings("@a(ss) []"), None);
    }

    #[test]
    fn le_o_layout_do_sistema() {
        let arquivo = "XKBMODEL=\"pc105\"\nXKBLAYOUT=\"br,us\"\nXKBVARIANT=\"abnt2,\"\n";
        assert_eq!(
            layout_do_sistema(arquivo),
            Some(("br".into(), "abnt2".into()))
        );
        assert_eq!(layout_do_sistema("XKBMODEL=pc105"), None);
    }

    // Os testes abaixo compilam layouts de verdade, com os arquivos do
    // sistema (pacote xkb-data). Sem eles, não há o que conferir.
    fn teclado(layout: &str, variante: &str) -> Option<Teclado> {
        let t = Teclado::de(layout, variante);
        if t.is_none() {
            eprintln!("layout {layout} indisponível nesta máquina; teste pulado");
        }
        t
    }

    #[test]
    fn abnt2_tem_cedilha_propria_e_acentos_por_tecla_morta() {
        let Some(br) = teclado("br", "") else { return };
        assert_eq!(br.plano('ç'), Plano::Direto(0xE7));
        assert_eq!(
            br.plano('é'),
            Plano::Morto {
                acento: 0xFE51,
                base: 0x65
            }
        );
        assert_eq!(
            br.plano('ã'),
            Plano::Morto {
                acento: 0xFE53,
                base: 0x61
            }
        );
        assert_eq!(
            br.plano('Ê'),
            Plano::Morto {
                acento: 0xFE52,
                base: 0x45
            }
        );
        assert_eq!(br.plano('a'), Plano::Direto(0x61));
    }

    #[test]
    fn ingles_eua_nao_faz_acento() {
        let Some(us) = teclado("us", "") else { return };
        assert_eq!(us.plano('é'), Plano::Impossivel);
        assert_eq!(us.plano('ç'), Plano::Impossivel);
        assert_eq!(us.plano('a'), Plano::Direto(0x61));
    }

    #[test]
    fn ingles_internacional_faz_os_acentos() {
        let Some(intl) = teclado("us", "intl") else {
            return;
        };
        assert_ne!(intl.plano('é'), Plano::Impossivel);
        assert_ne!(intl.plano('ã'), Plano::Impossivel);
        assert_ne!(intl.plano('ç'), Plano::Impossivel);
    }
}
