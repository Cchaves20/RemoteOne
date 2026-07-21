//! Injeção de mouse no sistema operacional (camada de plataforma).
//!
//! A implementação real usa o `enigo` e existe apenas no Windows — a única
//! plataforma disponível para teste real neste projeto. Linux e macOS têm um
//! stub que apenas registra a ação (permite desenvolver e testar todo o
//! caminho — backend → agente — sem uma sessão gráfica).

use crate::input::InputAction;

/// Aplica ações de mouse no computador.
pub trait MouseController {
    fn apply(&mut self, action: &InputAction) -> Result<(), String>;
}

#[cfg(windows)]
mod imp {
    use super::MouseController;
    use crate::input::{InputAction, MouseButton};
    use enigo::{Axis, Button, Coordinate, Direction, Enigo, Mouse, Settings};

    pub struct EnigoMouse {
        enigo: Enigo,
    }

    pub fn controller() -> Box<dyn MouseController> {
        let enigo = Enigo::new(&Settings::default())
            .expect("não foi possível inicializar a injeção de entrada");
        Box::new(EnigoMouse { enigo })
    }

    impl MouseController for EnigoMouse {
        fn apply(&mut self, action: &InputAction) -> Result<(), String> {
            match action {
                InputAction::MouseMove { dx, dy } => self
                    .enigo
                    .move_mouse(*dx, *dy, Coordinate::Rel)
                    .map_err(|e| e.to_string()),
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
            }
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::MouseController;
    use crate::input::InputAction;

    /// Stub: registra a ação em vez de injetá-la (sem sessão gráfica).
    pub struct StubMouse;

    pub fn controller() -> Box<dyn MouseController> {
        Box::new(StubMouse)
    }

    impl MouseController for StubMouse {
        fn apply(&mut self, action: &InputAction) -> Result<(), String> {
            println!("[mouse-stub] {action:?}");
            Ok(())
        }
    }
}

pub use imp::controller;
