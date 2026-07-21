//! Ações de entrada (mouse) recebidas do backend.
//!
//! O formato de fio é espelhado no backend em `backend/app/input.py`. Por ora
//! cobre o mouse (Etapa 6); teclado e gestos entram nas próximas etapas.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InputAction {
    /// Movimento relativo do cursor (touchpad).
    MouseMove { dx: i32, dy: i32 },
    /// Clique de um botão do mouse.
    MouseClick { button: MouseButton },
    /// Rolagem vertical (positivo = para cima).
    MouseScroll { dy: i32 },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mouse_move_wire_format() {
        let action = InputAction::MouseMove { dx: 10, dy: -5 };
        let value: serde_json::Value = serde_json::to_value(&action).unwrap();
        assert_eq!(value["kind"], "mouse_move");
        assert_eq!(value["dx"], 10);
        assert_eq!(value["dy"], -5);
    }

    #[test]
    fn deserializes_click_with_button() {
        let action: InputAction =
            serde_json::from_str(r#"{"kind":"mouse_click","button":"right"}"#).unwrap();
        assert_eq!(
            action,
            InputAction::MouseClick {
                button: MouseButton::Right
            }
        );
    }

    #[test]
    fn deserializes_scroll() {
        let action: InputAction =
            serde_json::from_str(r#"{"kind":"mouse_scroll","dy":3}"#).unwrap();
        assert_eq!(action, InputAction::MouseScroll { dy: 3 });
    }
}
