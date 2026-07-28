//! Injeção de entrada (mouse e teclado) no sistema operacional.
//!
//! A implementação real usa o `enigo` e existe apenas no Windows — a única
//! plataforma disponível para teste real neste projeto. Linux e macOS têm um
//! stub que apenas registra a ação (permite desenvolver e testar todo o
//! caminho — backend → agente — sem uma sessão gráfica).

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

#[cfg(windows)]
mod imp {
    use super::InputInjector;
    use crate::input::{InputAction, MediaAction, Modifier, MouseButton, SpecialKey};
    use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};

    pub struct EnigoInjector {
        enigo: Enigo,
    }

    pub fn controller() -> Box<dyn InputInjector> {
        let enigo = Enigo::new(&Settings::default())
            .expect("não foi possível inicializar a injeção de entrada");
        Box::new(EnigoInjector { enigo })
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

    fn modifier_key(modifier: &Modifier) -> Key {
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
                InputAction::MouseClick { button } => {
                    let b = match button {
                        MouseButton::Left => Button::Left,
                        MouseButton::Right => Button::Right,
                        MouseButton::Middle => Button::Middle,
                    };
                    self.enigo
                        .button(b, Direction::Click)
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

#[cfg(not(windows))]
mod imp {
    use super::InputInjector;
    use crate::input::{InputAction, MediaAction};

    /// Stub: registra a ação em vez de injetá-la (sem sessão gráfica).
    pub struct StubInjector;

    pub fn controller() -> Box<dyn InputInjector> {
        Box::new(StubInjector)
    }

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

pub use imp::controller;
