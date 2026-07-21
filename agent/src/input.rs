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

/// Teclas especiais (não-imprimíveis).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpecialKey {
    Enter,
    Backspace,
    Tab,
    Escape,
    Space,
    Delete,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
}

/// Teclas modificadoras usadas em atalhos.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Modifier {
    Ctrl,
    Alt,
    Shift,
    Meta,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InputAction {
    /// Movimento relativo do cursor (touchpad).
    MouseMove { dx: i32, dy: i32 },
    /// Move o cursor para uma posição absoluta, em fração da tela (0.0–1.0).
    /// Usado no modo "toque direto" (tocar leva o cursor até o ponto).
    MouseMoveTo { x: f64, y: f64 },
    /// Clique de um botão do mouse.
    MouseClick { button: MouseButton },
    /// Rolagem vertical (positivo = para cima).
    MouseScroll { dy: i32 },
    /// Digitação de texto (uma ou mais letras).
    KeyText { text: String },
    /// Pressiona uma tecla especial.
    KeyPress { key: SpecialKey },
    /// Atalho: modificadores + uma tecla (`key` = um caractere ou nome de tecla).
    KeyCombo {
        modifiers: Vec<Modifier>,
        key: String,
    },
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

    #[test]
    fn deserializes_move_to() {
        let action: InputAction =
            serde_json::from_str(r#"{"kind":"mouse_move_to","x":0.5,"y":0.25}"#).unwrap();
        assert_eq!(action, InputAction::MouseMoveTo { x: 0.5, y: 0.25 });
    }

    #[test]
    fn deserializes_key_text() {
        let action: InputAction =
            serde_json::from_str(r#"{"kind":"key_text","text":"Olá"}"#).unwrap();
        assert_eq!(
            action,
            InputAction::KeyText {
                text: "Olá".into()
            }
        );
    }

    #[test]
    fn deserializes_key_press_special() {
        let action: InputAction =
            serde_json::from_str(r#"{"kind":"key_press","key":"page_down"}"#).unwrap();
        assert_eq!(
            action,
            InputAction::KeyPress {
                key: SpecialKey::PageDown
            }
        );
    }

    #[test]
    fn deserializes_key_combo() {
        let action: InputAction =
            serde_json::from_str(r#"{"kind":"key_combo","modifiers":["ctrl","shift"],"key":"c"}"#)
                .unwrap();
        assert_eq!(
            action,
            InputAction::KeyCombo {
                modifiers: vec![Modifier::Ctrl, Modifier::Shift],
                key: "c".into()
            }
        );
    }
}
