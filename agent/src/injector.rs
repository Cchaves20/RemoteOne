//! Injeção de entrada (mouse e teclado) no sistema operacional.
//!
//! A implementação real usa o `enigo`, no Windows, no Mac e no Linux com X11.
//! No Mac ela só tem efeito depois de a pessoa liberar o Deskside em
//! "Acessibilidade" (ver `permissoes_mac.rs`): sem isso o sistema descarta os
//! eventos **em silêncio**, sem erro nenhum para devolver.
//!
//! No Linux com Wayland, mouse e teclado vão pelo portal do sistema, na mesma
//! sessão que entrega a tela (ver `wayland.rs`). Sem sessão gráfica nenhuma
//! (servidor, CI), um stub apenas registra a ação — o que permite desenvolver e
//! testar todo o caminho, backend → agente.

use crate::input::{InputAction, MediaAction};

/// Aplica ações de entrada (mouse/teclado) no computador.
pub trait InputInjector {
    fn apply(&mut self, action: &InputAction) -> Result<(), String>;

    /// Aciona uma tecla de mídia (play/pause, faixa, volume).
    ///
    /// Método próprio, e não uma variante de [`InputAction`], porque o alvo é
    /// diferente: estas teclas são globais e não vão para a janela em foco.
    fn media(&mut self, action: MediaAction) -> Result<(), String>;
}

#[cfg(any(windows, target_os = "macos", target_os = "linux"))]
mod imp {
    use super::InputInjector;
    use crate::input::{InputAction, MediaAction, Modifier, MouseButton, SpecialKey};
    use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};

    pub struct EnigoInjector {
        enigo: Enigo,
        /// Botões apertados e ainda não soltos. Existe por causa do `Drop`
        /// abaixo, que é a rede de segurança contra o pior defeito possível
        /// aqui: a conexão cair no meio de uma seleção e o computador ficar
        /// com o botão do mouse preso, arrastando tudo o que o cursor tocar.
        held: std::collections::HashSet<MouseButton>,
    }

    #[cfg(any(windows, target_os = "macos"))]
    pub fn controller() -> Box<dyn InputInjector> {
        let enigo = Enigo::new(&Settings::default())
            .expect("não foi possível inicializar a injeção de entrada");
        Box::new(EnigoInjector {
            enigo,
            held: std::collections::HashSet::new(),
        })
    }

    /// No Linux, conforme a sessão gráfica: Wayland pelo portal, X11 pelo
    /// `enigo`, e o stub quando não há tela nenhuma.
    #[cfg(target_os = "linux")]
    pub fn controller() -> Box<dyn InputInjector> {
        if crate::wayland::ativo() {
            return Box::new(super::wayland::Injetor::default());
        }
        if std::env::var_os("DISPLAY").is_some() {
            match Enigo::new(&Settings::default()) {
                Ok(enigo) => {
                    return Box::new(EnigoInjector {
                        enigo,
                        held: std::collections::HashSet::new(),
                    })
                }
                Err(e) => eprintln!("Sem mouse e teclado no X11: {e}"),
            }
        }
        Box::new(super::stub::StubInjector)
    }

    impl Drop for EnigoInjector {
        fn drop(&mut self) {
            // O injetor vive enquanto a conexão vive: quando ela cai, isto
            // roda. Soltar aqui cobre todo caminho de saída de uma vez, sem
            // depender de o app conseguir mandar o `mouse_release`.
            for button in self.held.clone() {
                let _ = self.enigo.button(mouse_button(&button), Direction::Release);
            }
        }
    }

    fn special_key(key: &SpecialKey) -> Key {
        match key {
            SpecialKey::Enter => Key::Return,
            SpecialKey::Backspace => Key::Backspace,
            SpecialKey::Tab => Key::Tab,
            SpecialKey::Escape => Key::Escape,
            SpecialKey::Space => Key::Space,
            SpecialKey::Delete => Key::Delete,
            SpecialKey::Up => Key::UpArrow,
            SpecialKey::Down => Key::DownArrow,
            SpecialKey::Left => Key::LeftArrow,
            SpecialKey::Right => Key::RightArrow,
            SpecialKey::Home => Key::Home,
            SpecialKey::End => Key::End,
            SpecialKey::PageUp => Key::PageUp,
            SpecialKey::PageDown => Key::PageDown,
            SpecialKey::F1 => Key::F1,
            SpecialKey::F2 => Key::F2,
            SpecialKey::F3 => Key::F3,
            SpecialKey::F4 => Key::F4,
            SpecialKey::F5 => Key::F5,
            SpecialKey::F6 => Key::F6,
            SpecialKey::F7 => Key::F7,
            SpecialKey::F8 => Key::F8,
            SpecialKey::F9 => Key::F9,
            SpecialKey::F10 => Key::F10,
            SpecialKey::F11 => Key::F11,
            SpecialKey::F12 => Key::F12,
        }
    }

    /// Tecla multimídia correspondente à ação.
    ///
    /// Todas estas variantes do `enigo` existem nas três plataformas (as
    /// específicas de macOS, como `MediaFast`, ficaram de fora justamente por
    /// isso), então este mapa não precisa de `cfg`.
    fn media_key(action: MediaAction) -> Key {
        match action {
            MediaAction::PlayPause => Key::MediaPlayPause,
            MediaAction::Next => Key::MediaNextTrack,
            MediaAction::Previous => Key::MediaPrevTrack,
            MediaAction::VolumeUp => Key::VolumeUp,
            MediaAction::VolumeDown => Key::VolumeDown,
            MediaAction::Mute => Key::VolumeMute,
        }
    }

    fn mouse_button(button: &MouseButton) -> Button {
        match button {
            MouseButton::Left => Button::Left,
            MouseButton::Right => Button::Right,
            MouseButton::Middle => Button::Middle,
        }
    }

    fn modifier_key(modifier: &Modifier) -> Key {
        // Os atalhos chegam na língua do Windows; ver `Modifier::no_mac`.
        #[cfg(target_os = "macos")]
        let modifier = &modifier.no_mac();
        match modifier {
            Modifier::Ctrl => Key::Control,
            Modifier::Alt => Key::Alt,
            Modifier::Shift => Key::Shift,
            Modifier::Meta => Key::Meta,
        }
    }

    /// Resolve a tecla de um atalho: um único caractere vira Unicode; caso
    /// contrário tenta interpretar como nome de tecla especial.
    fn combo_key(key: &str) -> Result<Key, String> {
        let mut chars = key.chars();
        let first = chars.next();
        if let (Some(c), None) = (first, chars.next()) {
            return Ok(Key::Unicode(c));
        }
        // A tabela de nomes é a mesma do `key_press`, e vive no `input.rs`
        // justamente para não haver duas: uma tecla que funciona sozinha e
        // falha em atalho é um defeito difícil de perceber.
        SpecialKey::from_name(key)
            .map(|especial| special_key(&especial))
            .ok_or_else(|| format!("tecla de atalho desconhecida: {key}"))
    }

    impl EnigoInjector {
        fn key_combo(&mut self, modifiers: &[Modifier], key: &str) -> Result<(), String> {
            let resolved = combo_key(key)?;
            for m in modifiers {
                self.enigo
                    .key(modifier_key(m), Direction::Press)
                    .map_err(|e| e.to_string())?;
            }
            let result = self
                .enigo
                .key(resolved, Direction::Click)
                .map_err(|e| e.to_string());
            // Solta os modificadores mesmo se o clique falhar.
            for m in modifiers.iter().rev() {
                let _ = self.enigo.key(modifier_key(m), Direction::Release);
            }
            result
        }
    }

    impl InputInjector for EnigoInjector {
        fn apply(&mut self, action: &InputAction) -> Result<(), String> {
            // O toque do celular não pode cair na barra de controle, que ele
            // nem vê: ela sai do caminho e o clique chega ao que está embaixo.
            // Ver `barra::desviar`.
            if matches!(
                action,
                InputAction::MouseClick { .. }
                    | InputAction::MousePress { .. }
                    | InputAction::MouseRelease { .. }
                    | InputAction::MouseScroll { .. }
            ) {
                crate::barra::desviar();
            }
            match action {
                InputAction::MouseMove { dx, dy } => self
                    .enigo
                    .move_mouse(*dx, *dy, Coordinate::Rel)
                    .map_err(|e| e.to_string()),
                InputAction::MouseMoveTo { x, y } => {
                    // Fração da tela (0–1) → pixel absoluto na tela principal.
                    let (w, h) = self.enigo.main_display().map_err(|e| e.to_string())?;
                    let px = (x.clamp(0.0, 1.0) * w as f64).round() as i32;
                    let py = (y.clamp(0.0, 1.0) * h as f64).round() as i32;
                    self.enigo
                        .move_mouse(px, py, Coordinate::Abs)
                        .map_err(|e| e.to_string())
                }
                InputAction::MouseClick { button } => self
                    .enigo
                    .button(mouse_button(button), Direction::Click)
                    .map_err(|e| e.to_string()),
                InputAction::MousePress { button, clicks } => {
                    let b = mouse_button(button);
                    // Os cliques completos vêm antes; o último aperto fica
                    // segurando, e é ele que faz o arrasto virar seleção.
                    for _ in 1..(*clicks).clamp(1, 3) {
                        self.enigo
                            .button(b, Direction::Click)
                            .map_err(|e| e.to_string())?;
                    }
                    self.held.insert(*button);
                    self.enigo
                        .button(b, Direction::Press)
                        .map_err(|e| e.to_string())
                }
                InputAction::MouseRelease { button } => {
                    self.held.remove(button);
                    self.enigo
                        .button(mouse_button(button), Direction::Release)
                        .map_err(|e| e.to_string())
                }
                InputAction::MouseScroll { dy } => self
                    .enigo
                    .scroll(-*dy, Axis::Vertical)
                    .map_err(|e| e.to_string()),
                InputAction::KeyText { text } => self.enigo.text(text).map_err(|e| e.to_string()),
                InputAction::KeyPress { key } => self
                    .enigo
                    .key(special_key(key), Direction::Click)
                    .map_err(|e| e.to_string()),
                InputAction::KeyCombo { modifiers, key } => self.key_combo(modifiers, key),
                InputAction::KeyReplace { backspaces, text } => {
                    // Teto de segurança: uma mensagem com um número absurdo não
                    // deve prender o agente apagando a tela do usuário.
                    for _ in 0..(*backspaces).min(64) {
                        self.enigo
                            .key(Key::Backspace, Direction::Click)
                            .map_err(|e| e.to_string())?;
                    }
                    self.enigo.text(text).map_err(|e| e.to_string())
                }
            }
        }

        fn media(&mut self, action: MediaAction) -> Result<(), String> {
            self.enigo
                .key(media_key(action), Direction::Click)
                .map_err(|e| e.to_string())
        }
    }
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod stub {
    use super::InputInjector;
    use crate::input::{InputAction, MediaAction};

    /// Stub: registra a ação em vez de injetá-la (sem sessão gráfica).
    pub struct StubInjector;

    impl InputInjector for StubInjector {
        fn apply(&mut self, action: &InputAction) -> Result<(), String> {
            println!("[input-stub] {action:?}");
            Ok(())
        }

        fn media(&mut self, action: MediaAction) -> Result<(), String> {
            println!("[media-stub] {action:?}");
            Ok(())
        }
    }
}

/// Os símbolos de tecla do X (keysyms), que é como o portal do Wayland
/// recebe o teclado.
///
/// Pelo símbolo e não pela posição da tecla: "ç" é o mesmo símbolo em qualquer
/// layout, e é o compositor quem acha a tecla (e o Shift) que o produz no
/// teclado configurado no computador. Pela posição, o mesmo código daria "ç"
/// num teclado brasileiro e ";" num americano.
///
/// Lógica pura, testada em qualquer plataforma.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) mod keysym {
    use crate::input::{MediaAction, Modifier, MouseButton, SpecialKey};

    /// O símbolo de um caractere.
    ///
    /// O Latin-1 tem símbolo igual ao próprio código; o resto do Unicode usa
    /// a faixa `0x0100_0000 + código`, que o X define exatamente para isso.
    pub fn do_caractere(c: char) -> i32 {
        match c {
            '\n' | '\r' => 0xFF0D,
            '\t' => 0xFF09,
            '\u{8}' => 0xFF08,
            c if (' '..='~').contains(&c) || ('\u{a0}'..='\u{ff}').contains(&c) => c as i32,
            c => 0x0100_0000 + c as i32,
        }
    }

    pub fn especial(tecla: &SpecialKey) -> i32 {
        match tecla {
            SpecialKey::Enter => 0xFF0D,
            SpecialKey::Backspace => 0xFF08,
            SpecialKey::Tab => 0xFF09,
            SpecialKey::Escape => 0xFF1B,
            SpecialKey::Space => 0x20,
            SpecialKey::Delete => 0xFFFF,
            SpecialKey::Up => 0xFF52,
            SpecialKey::Down => 0xFF54,
            SpecialKey::Left => 0xFF51,
            SpecialKey::Right => 0xFF53,
            SpecialKey::Home => 0xFF50,
            SpecialKey::End => 0xFF57,
            SpecialKey::PageUp => 0xFF55,
            SpecialKey::PageDown => 0xFF56,
            SpecialKey::F1 => 0xFFBE,
            SpecialKey::F2 => 0xFFBF,
            SpecialKey::F3 => 0xFFC0,
            SpecialKey::F4 => 0xFFC1,
            SpecialKey::F5 => 0xFFC2,
            SpecialKey::F6 => 0xFFC3,
            SpecialKey::F7 => 0xFFC4,
            SpecialKey::F8 => 0xFFC5,
            SpecialKey::F9 => 0xFFC6,
            SpecialKey::F10 => 0xFFC7,
            SpecialKey::F11 => 0xFFC8,
            SpecialKey::F12 => 0xFFC9,
        }
    }

    /// Os modificadores do lado esquerdo, que é o que um atalho usa.
    pub fn modificador(m: &Modifier) -> i32 {
        match m {
            Modifier::Ctrl => 0xFFE3,
            Modifier::Shift => 0xFFE1,
            Modifier::Alt => 0xFFE9,
            Modifier::Meta => 0xFFEB,
        }
    }

    /// A tecla principal de um atalho: um caractere ou um nome ("tab").
    ///
    /// A letra vai **minúscula**: em Ctrl+C o Shift, se houver, já vem como
    /// modificador. Mandar "C" maiúsculo faria o compositor apertar Shift por
    /// conta própria, e Ctrl+C viraria Ctrl+Shift+C (que no terminal é outra
    /// coisa).
    pub fn do_atalho(tecla: &str) -> Option<i32> {
        let mut letras = tecla.chars();
        if let (Some(c), None) = (letras.next(), letras.next()) {
            return Some(do_caractere(c.to_lowercase().next().unwrap_or(c)));
        }
        SpecialKey::from_name(tecla).map(|t| especial(&t))
    }

    pub fn midia(acao: MediaAction) -> i32 {
        match acao {
            MediaAction::PlayPause => 0x1008FF14,
            MediaAction::Next => 0x1008FF17,
            MediaAction::Previous => 0x1008FF16,
            MediaAction::VolumeUp => 0x1008FF13,
            MediaAction::VolumeDown => 0x1008FF11,
            MediaAction::Mute => 0x1008FF12,
        }
    }

    /// O código do botão no evdev do Linux.
    pub fn botao(b: &MouseButton) -> i32 {
        match b {
            MouseButton::Left => 0x110,
            MouseButton::Right => 0x111,
            MouseButton::Middle => 0x112,
        }
    }
}

/// Mouse e teclado no Wayland, pela sessão do portal que a captura abriu.
#[cfg(target_os = "linux")]
mod wayland {
    use super::keysym;
    use super::InputInjector;
    use crate::input::{InputAction, MediaAction, MouseButton};
    use crate::wayland::Sessao;
    use std::sync::Arc;

    #[derive(Default)]
    pub struct Injetor {
        /// Botões apertados e não soltos, pelo mesmo motivo do `enigo`: a
        /// conexão cair no meio de um arrasto não pode deixar o botão preso.
        segurados: std::collections::HashSet<MouseButton>,
        avisou: bool,
        /// Já disse ao celular que o teclado do computador não tem acentos.
        avisou_teclado: bool,
    }

    /// O recado ao celular quando o layout do computador não faz um caractere.
    fn aviso_de_teclado(layout: &str) -> String {
        let nome = match layout {
            "us" => "Inglês (EUA)",
            "gb" => "Inglês (Reino Unido)",
            outro => outro,
        };
        format!(
            "O teclado deste computador está como \"{nome}\", que não tem acentos nem \
             \"ç\": eles não chegam. No computador, em Configurações › Teclado, \
             adicione \"Português (Brasil)\" e deixe-o em primeiro."
        )
    }

    impl Injetor {
        /// A sessão em uso. Sem ela (ninguém com a tela aberta) não há para
        /// onde mandar, e isso se diz uma vez só no diário.
        fn sessao(&mut self) -> Result<Arc<Sessao>, String> {
            match crate::wayland::atual() {
                Some(s) => {
                    self.avisou = false;
                    Ok(s)
                }
                None => {
                    if !self.avisou {
                        self.avisou = true;
                        crate::diario(
                            "Wayland: mouse e teclado só funcionam com a tela aberta no app",
                        );
                    }
                    Err("a tela do computador não está aberta".to_string())
                }
            }
        }

        fn clicar(s: &Sessao, b: &MouseButton) {
            s.botao(keysym::botao(b), true);
            s.botao(keysym::botao(b), false);
        }

        /// Digita um texto com as teclas que o layout do computador tem: a
        /// tecla própria, ou acento + letra (ver `teclado_linux`).
        ///
        /// O que o layout não alcança fica de fora — o compositor descartaria
        /// de qualquer jeito —, e o celular é avisado uma vez por conexão,
        /// dizendo o que fazer.
        fn digitar(&mut self, s: &Sessao, texto: &str) {
            use crate::teclado_linux::Plano;
            let teclado = crate::teclado_linux::atual();
            for c in texto.chars() {
                match teclado.plano(c) {
                    Plano::Direto(simbolo) => {
                        s.tecla(simbolo as i32, true);
                        s.tecla(simbolo as i32, false);
                    }
                    Plano::Morto { acento, base } => {
                        s.tecla(acento as i32, true);
                        s.tecla(acento as i32, false);
                        s.tecla(base as i32, true);
                        s.tecla(base as i32, false);
                    }
                    Plano::Impossivel => {
                        if !self.avisou_teclado {
                            self.avisou_teclado = true;
                            crate::diario(&format!(
                                "Wayland: \"{c}\" não existe no teclado {}",
                                teclado.nome
                            ));
                            crate::aviso::avisar(&aviso_de_teclado(&teclado.nome));
                        }
                    }
                }
            }
        }
    }

    impl InputInjector for Injetor {
        fn apply(&mut self, action: &InputAction) -> Result<(), String> {
            let s = self.sessao()?;
            match action {
                InputAction::MouseMove { dx, dy } => s.mover(*dx as f64, *dy as f64),
                InputAction::MouseMoveTo { x, y } => s.mover_para(
                    x.clamp(0.0, 1.0) * s.largura as f64,
                    y.clamp(0.0, 1.0) * s.altura as f64,
                ),
                InputAction::MouseClick { button } => Self::clicar(&s, button),
                InputAction::MousePress { button, clicks } => {
                    for _ in 1..(*clicks).clamp(1, 3) {
                        Self::clicar(&s, button);
                    }
                    self.segurados.insert(*button);
                    s.botao(keysym::botao(button), true);
                }
                InputAction::MouseRelease { button } => {
                    self.segurados.remove(button);
                    s.botao(keysym::botao(button), false);
                }
                // O mesmo sentido do `enigo`: o app manda positivo para cima.
                InputAction::MouseScroll { dy } => s.rolar(-*dy),
                InputAction::KeyText { text } => self.digitar(&s, text),
                InputAction::KeyPress { key } => {
                    let simbolo = keysym::especial(key);
                    s.tecla(simbolo, true);
                    s.tecla(simbolo, false);
                }
                InputAction::KeyCombo { modifiers, key } => {
                    let simbolo = keysym::do_atalho(key)
                        .ok_or_else(|| format!("tecla de atalho desconhecida: {key}"))?;
                    for m in modifiers {
                        s.tecla(keysym::modificador(m), true);
                    }
                    s.tecla(simbolo, true);
                    s.tecla(simbolo, false);
                    for m in modifiers.iter().rev() {
                        s.tecla(keysym::modificador(m), false);
                    }
                }
                InputAction::KeyReplace { backspaces, text } => {
                    for _ in 0..(*backspaces).min(64) {
                        s.tecla(0xFF08, true);
                        s.tecla(0xFF08, false);
                    }
                    self.digitar(&s, text);
                }
            }
            Ok(())
        }

        fn media(&mut self, action: MediaAction) -> Result<(), String> {
            let s = self.sessao()?;
            let simbolo = keysym::midia(action);
            s.tecla(simbolo, true);
            s.tecla(simbolo, false);
            Ok(())
        }
    }

    impl Drop for Injetor {
        fn drop(&mut self) {
            if let Some(s) = crate::wayland::atual() {
                for b in &self.segurados {
                    s.botao(keysym::botao(b), false);
                }
            }
        }
    }
}

pub use imp::controller;

#[cfg(test)]
mod tests {
    use super::keysym;
    use crate::input::{Modifier, SpecialKey};

    #[test]
    fn latin1_e_o_proprio_codigo() {
        assert_eq!(keysym::do_caractere('a'), 0x61);
        assert_eq!(keysym::do_caractere('A'), 0x41);
        assert_eq!(keysym::do_caractere('ç'), 0xE7);
        assert_eq!(keysym::do_caractere('é'), 0xE9);
    }

    #[test]
    fn fora_do_latin1_usa_a_faixa_unicode() {
        assert_eq!(keysym::do_caractere('€'), 0x0100_20AC);
        assert_eq!(keysym::do_caractere('ñ'), 0xF1);
        assert_eq!(keysym::do_caractere('😀'), 0x0101_F600);
    }

    #[test]
    fn quebra_de_linha_vira_enter() {
        assert_eq!(keysym::do_caractere('\n'), 0xFF0D);
        assert_eq!(keysym::especial(&SpecialKey::Enter), 0xFF0D);
    }

    #[test]
    fn atalho_manda_a_letra_minuscula() {
        assert_eq!(keysym::do_atalho("C"), Some(0x63));
        assert_eq!(keysym::do_atalho("tab"), Some(0xFF09));
        assert_eq!(keysym::do_atalho("nada"), None);
        assert_eq!(keysym::modificador(&Modifier::Ctrl), 0xFFE3);
    }
}
