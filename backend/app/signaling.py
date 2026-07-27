"""Sinalização de WebRTC: repasse de SDP e candidatos ICE entre app e agente.

O backend **não participa** da negociação — ele encaminha e nada mais. Quem
negocia são as duas pontas, e o objetivo do WebRTC é justamente que elas passem
a falar direto, sem o servidor no meio do vídeo.

Isso tem uma consequência boa: como o papel do backend é só traduzir e rotear,
esta parte inteira pode ser testada sem WebRTC nenhum — é o que faz a Fase 1 do
plano ser a mais verificável de todas (ver `docs/webrtc-plano.md`).

A rota de ida (app → agente) leva um `session_id` atribuído pelo backend, porque
um agente pode estar negociando com vários apps ao mesmo tempo. Na volta, o
`session_id` é usado para achar o app certo e então **removido**: o app tem uma
conexão só e não precisa saber que esse identificador existe.
"""

from typing import Any

# O que o app pode mandar pelo canal de sinalização. Qualquer outro `type` é
# recusado em vez de repassado — o agente confia no que vem do backend.
VIEWER_MESSAGE_TYPES = frozenset({"webrtc_offer", "webrtc_ice"})


class SignalingError(ValueError):
    """Mensagem de sinalização malformada, recusada antes de ser repassada."""


def is_signaling(message: Any) -> bool:
    """Se a mensagem crua do app é sinalização de WebRTC."""
    return isinstance(message, dict) and message.get("type") in VIEWER_MESSAGE_TYPES


def to_agent(message: dict, session_id: str) -> dict:
    """Valida o que o app mandou e monta a mensagem que vai ao agente.

    Lança [`SignalingError`] se algo essencial faltar ou vier com o tipo errado.
    """
    kind = message.get("type")
    if kind == "webrtc_offer":
        sdp = message.get("sdp")
        if not isinstance(sdp, str) or not sdp:
            raise SignalingError("webrtc_offer sem sdp")
        return {"type": "webrtc_offer", "session_id": session_id, "sdp": sdp}

    if kind == "webrtc_ice":
        candidate = message.get("candidate")
        # Candidato vazio é o sinal de "acabaram os candidatos": vale repassar.
        if not isinstance(candidate, str):
            raise SignalingError("webrtc_ice sem candidate")
        sdp_mid = message.get("sdp_mid")
        if sdp_mid is not None and not isinstance(sdp_mid, str):
            raise SignalingError("webrtc_ice com sdp_mid inválido")
        index = message.get("sdp_mline_index")
        # bool é subclasse de int em Python; um True aqui seria um erro calado.
        if index is not None and (not isinstance(index, int) or isinstance(index, bool)):
            raise SignalingError("webrtc_ice com sdp_mline_index inválido")
        return {
            "type": "webrtc_ice",
            "session_id": session_id,
            "candidate": candidate,
            "sdp_mid": sdp_mid,
            "sdp_mline_index": index,
        }

    raise SignalingError(f"tipo de sinalização desconhecido: {kind!r}")


def to_viewer(message: dict) -> dict:
    """Monta o que vai ao app, sem o `session_id` (que é assunto do backend)."""
    return {k: v for k, v in message.items() if k != "session_id"}


def close_session(session_id: str) -> dict:
    """Avisa o agente que o app saiu e a conexão daquela sessão pode cair."""
    return {"type": "webrtc_close", "session_id": session_id}
