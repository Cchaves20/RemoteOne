"""A ligação real do `viewer_ws` com a sinalização.

Os testes de `test_signaling.py` cobrem tradução e roteamento em isolamento.
Faltava o elo do meio: a oferta que sai do app chega mesmo ao agente pelo
WebSocket do espectador? É o que estes testes exercitam.

Sem threads de propósito: o agente é um dublê registrado no `ConnectionManager`,
então o `TestClient` só precisa cuidar do lado do espectador.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager, viewers
from app.db import SessionLocal
from app.main import app
from app.models import Device, User

client = TestClient(app)


def _register(email: str) -> tuple[str, int]:
    tokens = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "senhaSegura123"}
    ).json()
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return tokens["access_token"], user_id


def _pair(user_id: int, device_id: str) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name="pc",
                os="windows",
                hostname="pc",
            )
        )
        db.commit()


class FakeAgent:
    """Agente conectado, do ponto de vista do backend."""

    def __init__(self):
        self.sent = []

    async def send_json(self, message):
        self.sent.append(message)

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


def test_oferta_do_app_chega_ao_agente_com_session_id():
    token, user_id = _register("sinal-ws-1@example.com")
    _pair(user_id, "dev-sig-1")
    agent = FakeAgent()
    manager.register("dev-sig-1", agent)
    try:
        with client.websocket_connect("/ws/viewer/dev-sig-1") as ws:
            ws.send_json({"token": token})
            ws.send_json({"type": "webrtc_offer", "sdp": "v=0\r\nfake"})
            # Um round-trip qualquer garante que o servidor já processou o envio
            # anterior: o backend responde a mensagens desconhecidas com nada,
            # então usamos o próprio fechamento como barreira.
            ws.send_json({"type": "webrtc_ice", "candidate": "candidate:1 host"})
            ws.close()

        offers = agent.of_type("webrtc_offer")
        assert offers, f"nenhuma oferta chegou ao agente; recebido: {agent.sent}"
        assert offers[0]["sdp"] == "v=0\r\nfake"
        session_id = offers[0]["session_id"]
        assert session_id, "a oferta precisa levar um session_id"

        ices = agent.of_type("webrtc_ice")
        assert ices, "o candidato ICE não foi repassado"
        assert ices[0]["session_id"] == session_id, "sessão diferente da oferta"
        assert ices[0]["candidate"] == "candidate:1 host"
    finally:
        manager.unregister("dev-sig-1", agent)


def test_saida_do_app_avisa_o_agente_para_fechar_a_sessao():
    token, user_id = _register("sinal-ws-2@example.com")
    _pair(user_id, "dev-sig-2")
    agent = FakeAgent()
    manager.register("dev-sig-2", agent)
    try:
        with client.websocket_connect("/ws/viewer/dev-sig-2") as ws:
            ws.send_json({"token": token})
            ws.send_json({"type": "webrtc_offer", "sdp": "v=0"})
            ws.close()

        closes = agent.of_type("webrtc_close")
        assert closes, f"nenhum webrtc_close; recebido: {agent.sent}"
        offers = agent.of_type("webrtc_offer")
        assert closes[0]["session_id"] == offers[0]["session_id"]
    finally:
        manager.unregister("dev-sig-2", agent)


def test_resposta_do_agente_volta_ao_app():
    """O caminho de volta: o agente responde e o app recebe, sem o session_id."""
    token, user_id = _register("sinal-ws-3@example.com")
    _pair(user_id, "dev-sig-3")
    agent = FakeAgent()
    manager.register("dev-sig-3", agent)
    try:
        with client.websocket_connect("/ws/viewer/dev-sig-3") as ws:
            ws.send_json({"token": token})
            ws.send_json({"type": "webrtc_offer", "sdp": "v=0"})
            # Descobre a sessão pelo que o agente recebeu e simula a resposta
            # dele, empurrando pela fila do viewer (é o que o agent_ws faz).
            offers = agent.of_type("webrtc_offer")
            assert offers, f"a oferta não chegou; recebido: {agent.sent}"
            session_id = offers[0]["session_id"]

            viewer = viewers.by_session(session_id, "dev-sig-3")
            assert viewer is not None, "a sessão não está no registro"
            viewer.signal({"type": "webrtc_answer", "sdp": "v=0 resposta"})

            answer = ws.receive_json()
            assert answer == {"type": "webrtc_answer", "sdp": "v=0 resposta"}
            assert "session_id" not in answer, "o app não deve ver o session_id"
    finally:
        manager.unregister("dev-sig-3", agent)


def test_oferta_malformada_vira_erro_para_o_app_e_nao_vai_ao_agente():
    token, user_id = _register("sinal-ws-4@example.com")
    _pair(user_id, "dev-sig-4")
    agent = FakeAgent()
    manager.register("dev-sig-4", agent)
    try:
        with client.websocket_connect("/ws/viewer/dev-sig-4") as ws:
            ws.send_json({"token": token})
            ws.send_json({"type": "webrtc_offer"})  # sem sdp
            erro = ws.receive_json()
            assert erro["type"] == "error"
        assert not agent.of_type("webrtc_offer"), "não devia repassar mensagem inválida"
    finally:
        manager.unregister("dev-sig-4", agent)


def test_sem_agente_conectado_o_app_recebe_erro():
    token, user_id = _register("sinal-ws-5@example.com")
    _pair(user_id, "dev-sig-5")
    with client.websocket_connect("/ws/viewer/dev-sig-5") as ws:
        ws.send_json({"token": token})
        ws.send_json({"type": "webrtc_offer", "sdp": "v=0"})
        erro = ws.receive_json()
        assert erro["type"] == "error"
        assert "conectado" in erro["message"]
