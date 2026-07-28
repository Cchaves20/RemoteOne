//! Entrada pelo canal de dados do WebRTC (Fase 6 do `docs/webrtc-plano.md`).
//!
//! Hoje cada toque no celular percorre `HTTP → VPS → WebSocket → agente`: dois
//! saltos de rede mais o custo de abrir uma requisição HTTP por comando. Com a
//! conexão P2P já estabelecida para o vídeo, o mesmo comando vai por **um salto
//! direto**.
//!
//! ## Por que fora de ordem, mas confiável
//!
//! O canal é aberto com `ordered: false` e retransmissão ligada. Cada metade
//! dessa escolha resolve um problema diferente:
//!
//! - **Sem ordenação** evita bloqueio de cabeça de fila: um pacote perdido não
//!   segura os que vêm atrás. Num canal ordenado, perder um movimento de mouse
//!   travaria o clique que veio depois.
//! - **Com retransmissão** porque perder um clique é inaceitável. Movimento
//!   antigo não interessa, mas clique e tecla precisam chegar.
//!
//! O preço de não ordenar é que um movimento retransmitido pode chegar depois de
//! um mais novo, e o cursor pularia para trás. Daí o número de sequência: o
//! agente descarta **movimentos** atrasados, e nunca descarta cliques ou teclas.

use serde::{Deserialize, Serialize};

use crate::input::InputAction;

/// Uma ação vinda do canal de dados, com o número de sequência do app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InputEnvelope {
    /// Contador crescente do app, para detectar mensagens fora de ordem.
    pub seq: u64,
    pub action: InputAction,
}

/// Decide o que aplicar do canal de dados, ignorando o que chegou atrasado.
#[derive(Debug, Default)]
pub struct InputOrder {
    highest: u64,
}

impl InputOrder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Se a ação deve ser aplicada.
    ///
    /// Movimento com sequência menor que a maior já vista é notícia velha e é
    /// descartado. Clique, rolagem e tecla passam sempre: chegar fora de ordem é
    /// bem menos ruim que não chegar.
    pub fn accept(&mut self, envelope: &InputEnvelope) -> bool {
        let stale = envelope.seq <= self.highest;
        self.highest = self.highest.max(envelope.seq);
        if !stale {
            return true;
        }
        !matches!(
            envelope.action,
            InputAction::MouseMove { .. } | InputAction::MouseMoveTo { .. }
        )
    }

    /// Zera o controle — a sequência do app recomeça em cada sessão nova.
    pub fn reset(&mut self) {
        self.highest = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::MouseButton;

    fn mover(seq: u64) -> InputEnvelope {
        InputEnvelope {
            seq,
            action: InputAction::MouseMoveTo { x: 0.5, y: 0.5 },
        }
    }

    fn clicar(seq: u64) -> InputEnvelope {
        InputEnvelope {
            seq,
            action: InputAction::MouseClick {
                button: MouseButton::Left,
            },
        }
    }

    #[test]
    fn aceita_em_ordem() {
        let mut order = InputOrder::new();
        assert!(order.accept(&mover(1)));
        assert!(order.accept(&mover(2)));
        assert!(order.accept(&mover(3)));
    }

    #[test]
    fn descarta_movimento_atrasado() {
        // É o caso que o `ordered: false` cria: um movimento retransmitido
        // chegando depois de um mais novo faria o cursor pular para trás.
        let mut order = InputOrder::new();
        assert!(order.accept(&mover(5)));
        assert!(!order.accept(&mover(3)), "movimento velho não deve valer");
        assert!(!order.accept(&mover(5)), "repetido também não");
    }

    #[test]
    fn clique_atrasado_ainda_e_aplicado() {
        // Perder um clique é inaceitável; aplicá-lo fora de ordem é aceitável.
        let mut order = InputOrder::new();
        assert!(order.accept(&mover(10)));
        assert!(order.accept(&clicar(4)), "clique nunca é descartado");
    }

    #[test]
    fn tecla_atrasada_ainda_e_aplicada() {
        let mut order = InputOrder::new();
        assert!(order.accept(&mover(10)));
        let tecla = InputEnvelope {
            seq: 2,
            action: InputAction::KeyText { text: "a".into() },
        };
        assert!(order.accept(&tecla));
    }

    #[test]
    fn rolagem_atrasada_ainda_e_aplicada() {
        // Rolagem é incremental: descartar uma perde deslocamento de verdade.
        let mut order = InputOrder::new();
        assert!(order.accept(&mover(10)));
        let rolar = InputEnvelope {
            seq: 3,
            action: InputAction::MouseScroll { dy: -2 },
        };
        assert!(order.accept(&rolar));
    }

    #[test]
    fn reset_permite_sessao_nova_comecar_do_zero() {
        let mut order = InputOrder::new();
        assert!(order.accept(&mover(100)));
        order.reset();
        assert!(order.accept(&mover(1)), "sessão nova recomeça a contagem");
    }

    #[test]
    fn formato_de_fio() {
        // O app monta exatamente isto; a ação fica achatada com a tag `kind`.
        let json = r#"{"seq":7,"action":{"kind":"mouse_move_to","x":0.25,"y":0.75}}"#;
        let envelope: InputEnvelope = serde_json::from_str(json).unwrap();
        assert_eq!(envelope.seq, 7);
        assert_eq!(
            envelope.action,
            InputAction::MouseMoveTo { x: 0.25, y: 0.75 }
        );
    }
}
