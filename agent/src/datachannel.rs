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

// --- as perguntas da tela -------------------------------------------------

/// O canal das perguntas que o app faz com a tela aberta: o programa em
/// primeiro plano (a cada 3 s), os programas abertos (a cada 10 s) e as
/// métricas (a cada 2 s, com o painel aberto).
///
/// Elas passavam pelo servidor — HTTP até o VPS, WebSocket até aqui e de volta
/// —, e eram quase toda a carga dele: com 1.000 celulares de tela aberta, ~400
/// pedidos por segundo (ver `docs/teste-de-carga.md`). Por aqui vão direto.
///
/// Canal à parte do de entrada, e **ordenado**: uma pergunta e sua resposta
/// não têm a pressa do mouse, e perder uma não é opção.
///
/// O agente avisa que entende o canal com `{"tipo":"pronto"}` ao abri-lo. Um
/// agente antigo ignora o canal e nunca avisa — e o app, sem o aviso, continua
/// perguntando pelo servidor, que segue funcionando como sempre.
pub const PERGUNTAS_CHANNEL: &str = "perguntas";

/// O que o app quer saber.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tipo {
    PrimeiroPlano,
    ProgramasAbertos,
    Metricas,
}

/// Uma pergunta do app. `id` casa a resposta.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Pergunta {
    pub id: u64,
    pub tipo: Tipo,
}

/// O aviso de que este agente responde pelo canal.
pub fn pronto() -> String {
    r#"{"tipo":"pronto"}"#.to_string()
}

/// A resposta, no mesmo formato que o servidor devolve para a mesma pergunta
/// — o app lê as duas com o mesmo código.
pub fn resposta(id: u64, valor: serde_json::Value) -> String {
    serde_json::json!({ "id": id, "resposta": valor }).to_string()
}

/// Uma pergunta que este agente não sabe responder (de um app mais novo, por
/// exemplo). O app volta ao caminho do servidor para ela.
pub fn erro(id: Option<u64>, motivo: &str) -> String {
    serde_json::json!({ "id": id, "erro": motivo }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_as_perguntas_do_app() {
        let p: Pergunta = serde_json::from_str(r#"{"id":7,"tipo":"primeiro_plano"}"#).unwrap();
        assert_eq!(p, Pergunta { id: 7, tipo: Tipo::PrimeiroPlano });
        let p: Pergunta =
            serde_json::from_str(r#"{"id":8,"tipo":"programas_abertos"}"#).unwrap();
        assert_eq!(p.tipo, Tipo::ProgramasAbertos);
        let p: Pergunta = serde_json::from_str(r#"{"id":9,"tipo":"metricas"}"#).unwrap();
        assert_eq!(p.tipo, Tipo::Metricas);
        // Um tipo de um app mais novo não é pergunta que este agente responda.
        assert!(serde_json::from_str::<Pergunta>(r#"{"id":1,"tipo":"novo"}"#).is_err());
    }

    #[test]
    fn responde_no_formato_que_o_app_le() {
        let r: serde_json::Value =
            serde_json::from_str(&resposta(7, serde_json::json!({ "app": null }))).unwrap();
        assert_eq!(r, serde_json::json!({ "id": 7, "resposta": { "app": null } }));
        let e: serde_json::Value = serde_json::from_str(&erro(Some(3), "x")).unwrap();
        assert_eq!(e, serde_json::json!({ "id": 3, "erro": "x" }));
        let p: serde_json::Value = serde_json::from_str(&pronto()).unwrap();
        assert_eq!(p, serde_json::json!({ "tipo": "pronto" }));
    }
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
