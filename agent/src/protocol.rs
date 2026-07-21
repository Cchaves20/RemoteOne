//! Protocolo de mensagens do WebSocket agente ↔ backend.
//!
//! O formato de fio precisa ser idêntico ao do backend em
//! `backend/app/protocol.py`. Os testes abaixo fixam o JSON exato.

use serde::{Deserialize, Serialize};

use crate::input::InputAction;

/// Mensagens que o agente envia ao backend.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello {
        device_id: String,
        hostname: String,
        os: String,
        agent_version: String,
    },
    Heartbeat,
}

/// Mensagens que o backend envia ao agente.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome {
        server_version: String,
    },
    Ack,
    Error {
        message: String,
    },
    /// Código de pareamento a ser exibido ao usuário (dispositivo não pareado).
    PairCode {
        code: String,
        expires_in_seconds: u64,
    },
    /// O dispositivo foi vinculado a uma conta.
    Paired {
        user_email: String,
    },
    /// Comando de entrada a ser injetado no computador (Etapa 6).
    Input {
        action: InputAction,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_serializes_with_type_tag() {
        let hello = ClientMessage::Hello {
            device_id: "dev-1".into(),
            hostname: "dell-g5".into(),
            os: "windows".into(),
            agent_version: "0.1.0".into(),
        };
        let value: serde_json::Value = serde_json::to_value(&hello).unwrap();
        assert_eq!(value["type"], "hello");
        assert_eq!(value["device_id"], "dev-1");
        assert_eq!(value["os"], "windows");
    }

    #[test]
    fn heartbeat_serializes_to_just_the_tag() {
        let json = serde_json::to_string(&ClientMessage::Heartbeat).unwrap();
        assert_eq!(json, r#"{"type":"heartbeat"}"#);
    }

    #[test]
    fn deserializes_welcome() {
        let msg: ServerMessage =
            serde_json::from_str(r#"{"type":"welcome","server_version":"0.1.0"}"#).unwrap();
        assert_eq!(
            msg,
            ServerMessage::Welcome {
                server_version: "0.1.0".into()
            }
        );
    }

    #[test]
    fn deserializes_ack_and_error() {
        let ack: ServerMessage = serde_json::from_str(r#"{"type":"ack"}"#).unwrap();
        assert_eq!(ack, ServerMessage::Ack);

        let err: ServerMessage =
            serde_json::from_str(r#"{"type":"error","message":"xis"}"#).unwrap();
        assert_eq!(
            err,
            ServerMessage::Error {
                message: "xis".into()
            }
        );
    }

    #[test]
    fn deserializes_pair_code_and_paired() {
        let pc: ServerMessage = serde_json::from_str(
            r#"{"type":"pair_code","code":"ABC23XYZK","expires_in_seconds":600}"#,
        )
        .unwrap();
        assert_eq!(
            pc,
            ServerMessage::PairCode {
                code: "ABC23XYZK".into(),
                expires_in_seconds: 600
            }
        );

        let paired: ServerMessage =
            serde_json::from_str(r#"{"type":"paired","user_email":"caio@example.com"}"#).unwrap();
        assert_eq!(
            paired,
            ServerMessage::Paired {
                user_email: "caio@example.com".into()
            }
        );
    }
}
