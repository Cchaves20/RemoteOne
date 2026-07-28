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

impl SpecialKey {
    /// Resolve o nome que os atalhos usam (`key_combo`) numa tecla especial.
    ///
    /// Existe porque a tabela de nomes é lógica portável — dá para testá-la em
    /// qualquer plataforma —, enquanto a tradução para a tecla do sistema é só
    /// do Windows. Antes esta tabela vivia junto do `enigo` e cobria cinco
    /// nomes; `Shift + seta`, que é como se seleciona texto, não estava entre
    /// eles e falhava calada.
    pub fn from_name(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "enter" | "return" => Some(Self::Enter),
            "backspace" => Some(Self::Backspace),
            "tab" => Some(Self::Tab),
            "escape" | "esc" => Some(Self::Escape),
            "space" => Some(Self::Space),
            "delete" | "del" => Some(Self::Delete),
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            "home" => Some(Self::Home),
            "end" => Some(Self::End),
            "page_up" | "pageup" | "pgup" => Some(Self::PageUp),
            "page_down" | "pagedown" | "pgdn" => Some(Self::PageDown),
            "f1" => Some(Self::F1),
            "f2" => Some(Self::F2),
            "f3" => Some(Self::F3),
            "f4" => Some(Self::F4),
            "f5" => Some(Self::F5),
            "f6" => Some(Self::F6),
            "f7" => Some(Self::F7),
            "f8" => Some(Self::F8),
            "f9" => Some(Self::F9),
            "f10" => Some(Self::F10),
            "f11" => Some(Self::F11),
            "f12" => Some(Self::F12),
            _ => None,
        }
    }
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

/// Comandos de mídia: as teclas que um teclado multimídia tem a mais.
///
/// Ficam fora do [`InputAction`] de propósito. São teclas globais, atendidas por
/// quem estiver tocando som — não vão para a janela em foco, e por isso não
/// dependem de o computador estar sendo controlado. É a diferença que permite
/// pausar a música sem antes clicar no player.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaAction {
    PlayPause,
    Next,
    Previous,
    VolumeUp,
    VolumeDown,
    Mute,
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
    /// Apaga `backspaces` caracteres e digita `text`, **numa ação só**.
    ///
    /// É o que a barra de sugestões usa para trocar a palavra digitada. Precisa
    /// ser atômico porque o canal de dados é deliberadamente não ordenado (ver
    /// `datachannel.rs`): em mensagens separadas, o texto poderia chegar antes
    /// dos backspaces e o resultado sairia embaralhado.
    KeyReplace { backspaces: u32, text: String },
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

    #[test]
    fn atalho_aceita_as_teclas_de_selecao() {
        // Shift + seta é como se seleciona texto; Shift + Home/End seleciona
        // até o fim da linha. Nenhuma delas era aceita antes.
        assert_eq!(SpecialKey::from_name("left"), Some(SpecialKey::Left));
        assert_eq!(SpecialKey::from_name("right"), Some(SpecialKey::Right));
        assert_eq!(SpecialKey::from_name("up"), Some(SpecialKey::Up));
        assert_eq!(SpecialKey::from_name("down"), Some(SpecialKey::Down));
        assert_eq!(SpecialKey::from_name("home"), Some(SpecialKey::Home));
        assert_eq!(SpecialKey::from_name("end"), Some(SpecialKey::End));
    }

    #[test]
    fn atalho_aceita_apelidos_e_ignora_a_caixa() {
        assert_eq!(SpecialKey::from_name("ESC"), Some(SpecialKey::Escape));
        assert_eq!(SpecialKey::from_name("Del"), Some(SpecialKey::Delete));
        assert_eq!(SpecialKey::from_name("pgup"), Some(SpecialKey::PageUp));
        assert_eq!(
            SpecialKey::from_name("page_down"),
            Some(SpecialKey::PageDown)
        );
        assert_eq!(SpecialKey::from_name("f12"), Some(SpecialKey::F12));
    }

    #[test]
    fn atalho_cobre_todas_as_teclas_que_o_app_manda() {
        // O app manda o mesmo nome em `key_press` e em `key_combo`. Se uma
        // tecla existe num e não no outro, o atalho falha calado — que foi
        // exatamente o defeito.
        for nome in [
            "enter",
            "backspace",
            "tab",
            "escape",
            "space",
            "delete",
            "up",
            "down",
            "left",
            "right",
            "home",
            "end",
            "page_up",
            "page_down",
            "f1",
            "f2",
            "f3",
            "f4",
            "f5",
            "f6",
            "f7",
            "f8",
            "f9",
            "f10",
            "f11",
            "f12",
        ] {
            assert!(
                SpecialKey::from_name(nome).is_some(),
                "{nome} não é aceita em atalho"
            );
            // E o nome tem de ser o mesmo que o serde usa no fio.
            let json = format!("\"{nome}\"");
            let pelo_fio: Result<SpecialKey, _> = serde_json::from_str(&json);
            assert_eq!(
                pelo_fio.ok(),
                SpecialKey::from_name(nome),
                "{nome} tem nomes diferentes no fio e no atalho"
            );
        }
    }

    #[test]
    fn atalho_recusa_nome_desconhecido() {
        assert_eq!(SpecialKey::from_name("teclamágica"), None);
    }

    #[test]
    fn media_action_wire_format() {
        // O backend manda estas strings; se mudarem, o botão para de funcionar.
        assert_eq!(
            serde_json::to_value(MediaAction::PlayPause).unwrap(),
            "play_pause"
        );
        assert_eq!(
            serde_json::to_value(MediaAction::VolumeDown).unwrap(),
            "volume_down"
        );
        let action: MediaAction = serde_json::from_str(r#""previous""#).unwrap();
        assert_eq!(action, MediaAction::Previous);
    }
}
