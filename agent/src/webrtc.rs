//! Sinalização de WebRTC no agente (Fase 1 do `docs/webrtc-plano.md`).
//!
//! Nesta fase o agente **reconhece** a sinalização e controla quais sessões
//! estão abertas, mas ainda **não negocia**: a conexão de verdade entra na
//! Fase 2, com o `webrtc-rs` e o codificador H.264. A separação é de propósito
//! — o roteamento de sessões é lógica pura e pode ser testado agora, enquanto
//! a negociação depende de biblioteca nativa e de duas máquinas.
//!
//! Um agente pode estar negociando com vários apps ao mesmo tempo (o
//! `session_id` vem do backend justamente para isso), então o registro é um
//! mapa e não um único slot.

use std::collections::HashMap;

/// O que se sabe de uma sessão em negociação.
///
/// Na Fase 2 este tipo passa a carregar a `RTCPeerConnection` de verdade; hoje
/// guarda o suficiente para acompanhar a negociação pelos logs.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Session {
    /// Candidatos ICE recebidos do app até agora.
    pub candidates: usize,
    /// Se o app já sinalizou que seus candidatos acabaram.
    pub remote_done: bool,
}

/// Sessões de WebRTC abertas com este agente, indexadas pelo `session_id`.
#[derive(Debug, Default)]
pub struct Sessions {
    open: HashMap<String, Session>,
}

impl Sessions {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registra a oferta de um app. Devolve `true` se a sessão é nova.
    ///
    /// Uma oferta repetida na mesma sessão é renegociação, não erro: o estado é
    /// zerado e a sessão continua a mesma.
    pub fn offer(&mut self, session_id: &str) -> bool {
        self.open
            .insert(session_id.to_string(), Session::default())
            .is_none()
    }

    /// Contabiliza um candidato ICE do app.
    ///
    /// Devolve `false` se a sessão é desconhecida — o que significa candidato
    /// atrasado de uma sessão já encerrada, e é para ser ignorado, não tratado
    /// como falha.
    pub fn candidate(&mut self, session_id: &str, candidate: &str) -> bool {
        match self.open.get_mut(session_id) {
            None => false,
            Some(session) => {
                // Candidato vazio é o "acabaram os meus candidatos".
                if candidate.is_empty() {
                    session.remote_done = true;
                } else {
                    session.candidates += 1;
                }
                true
            }
        }
    }

    /// Encerra uma sessão. Devolve `true` se havia o que encerrar.
    pub fn close(&mut self, session_id: &str) -> bool {
        self.open.remove(session_id).is_some()
    }

    pub fn get(&self, session_id: &str) -> Option<&Session> {
        self.open.get(session_id)
    }

    pub fn len(&self) -> usize {
        self.open.len()
    }

    pub fn is_empty(&self) -> bool {
        self.open.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offer_abre_a_sessao_e_a_repetida_e_renegociacao() {
        let mut sessions = Sessions::new();
        assert!(sessions.offer("s1"), "primeira oferta abre a sessão");
        assert!(!sessions.offer("s1"), "a segunda é renegociação, não nova");
        assert_eq!(sessions.len(), 1);
    }

    #[test]
    fn renegociar_zera_o_estado_anterior() {
        let mut sessions = Sessions::new();
        sessions.offer("s1");
        sessions.candidate("s1", "candidate:1 ...");
        sessions.candidate("s1", "");
        sessions.offer("s1");
        assert_eq!(sessions.get("s1"), Some(&Session::default()));
    }

    #[test]
    fn candidatos_sao_contados_e_o_vazio_encerra_o_lado_remoto() {
        let mut sessions = Sessions::new();
        sessions.offer("s1");
        assert!(sessions.candidate("s1", "candidate:1 ..."));
        assert!(sessions.candidate("s1", "candidate:2 ..."));
        assert!(sessions.candidate("s1", ""));
        let session = sessions.get("s1").unwrap();
        assert_eq!(session.candidates, 2);
        assert!(session.remote_done);
    }

    #[test]
    fn candidato_de_sessao_desconhecida_e_recusado() {
        // Acontece de verdade: candidato que chega depois do app sair.
        let mut sessions = Sessions::new();
        assert!(!sessions.candidate("fantasma", "candidate:1 ..."));
    }

    #[test]
    fn close_remove_e_e_idempotente() {
        let mut sessions = Sessions::new();
        sessions.offer("s1");
        assert!(sessions.close("s1"));
        assert!(!sessions.close("s1"), "fechar de novo não é erro");
        assert!(sessions.is_empty());
    }

    #[test]
    fn sessoes_sao_independentes() {
        let mut sessions = Sessions::new();
        sessions.offer("s1");
        sessions.offer("s2");
        sessions.candidate("s1", "candidate:1 ...");
        assert_eq!(sessions.get("s1").unwrap().candidates, 1);
        assert_eq!(sessions.get("s2").unwrap().candidates, 0);
        sessions.close("s1");
        assert_eq!(sessions.len(), 1);
        assert!(sessions.get("s2").is_some());
    }
}
