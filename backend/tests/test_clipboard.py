"""Área de transferência compartilhada.

Duas direções que **não** são simétricas: computador → telefone pode ser
automático (o Windows avisa quando alguém copia); telefone → computador é
sempre a pedido, porque o iOS mostra um aviso na tela toda vez que um app lê a
área de transferência.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager, viewers
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending

client = TestClient(app)


def _auth_headers(email: str) -> tuple[dict, int]:
    tokens = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "senhaSegura123"}
    ).json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _add_device(user_id: int, device_id: str) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name=device_id,
                os="windows",
                hostname=device_id,
            )
        )
        db.commit()


class InstantAgent:
    def __init__(self, text: str | None = None):
        self.text = text
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "clipboard_get" and self.text is not None:
            pending.resolve(message["request_id"], {"text": self.text})

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_resposta_do_agente():
    message = parse_client_message(
        {"type": "clipboard", "request_id": "r1", "text": "olá"}
    )
    assert message.text == "olá"


def test_parse_aviso_de_copia_nova():
    message = parse_client_message({"type": "clipboard_changed", "text": "copiado"})
    assert message.text == "copiado"


def test_texto_gigante_e_recusado():
    """Copiar um log inteiro é comum; virar uma mensagem de megabytes no
    WebSocket, não. O agente já corta, e aqui é a segunda barreira."""
    try:
        parse_client_message(
            {"type": "clipboard_changed", "text": "a" * (64 * 1024 + 1)}
        )
    except ValueError:
        return
    raise AssertionError("texto acima do teto deveria ser recusado")


# --- endpoints ---------------------------------------------------------------


def test_traz_o_texto_do_computador():
    headers, uid = _auth_headers("clip1@example.com")
    _add_device(uid, "dev-clip-1")
    agent = InstantAgent("do computador")
    manager.register("dev-clip-1", agent)
    try:
        resp = client.get("/api/v1/devices/dev-clip-1/clipboard", headers=headers)
    finally:
        manager.unregister("dev-clip-1")
    assert resp.status_code == 200
    assert resp.json() == {"text": "do computador"}


def test_manda_o_texto_ao_computador():
    headers, uid = _auth_headers("clip2@example.com")
    _add_device(uid, "dev-clip-2")
    agent = InstantAgent()
    manager.register("dev-clip-2", agent)
    try:
        resp = client.post(
            "/api/v1/devices/dev-clip-2/clipboard",
            json={"text": "do telefone"},
            headers=headers,
        )
    finally:
        manager.unregister("dev-clip-2")
    assert resp.status_code == 204
    assert agent.of_type("clipboard_set")[0]["text"] == "do telefone"


def test_liga_e_desliga_a_sincronia():
    headers, uid = _auth_headers("clip3@example.com")
    _add_device(uid, "dev-clip-3")
    agent = InstantAgent()
    manager.register("dev-clip-3", agent)
    try:
        for ligado in (True, False):
            resp = client.post(
                "/api/v1/devices/dev-clip-3/clipboard/sync",
                json={"enabled": ligado},
                headers=headers,
            )
            assert resp.status_code == 204, ligado
    finally:
        manager.unregister("dev-clip-3")
    assert [m["enabled"] for m in agent.of_type("clipboard_sync")] == [True, False]


def test_de_outra_conta_404():
    """O que passa pela área de transferência de alguém costuma incluir senha:
    só o dono lê."""
    _, dono = _auth_headers("clip4@example.com")
    _add_device(dono, "dev-clip-4")
    intruso, _ = _auth_headers("clip5@example.com")
    assert (
        client.get("/api/v1/devices/dev-clip-4/clipboard", headers=intruso).status_code
        == 404
    )
    assert (
        client.post(
            "/api/v1/devices/dev-clip-4/clipboard",
            json={"text": "x"},
            headers=intruso,
        ).status_code
        == 404
    )


def test_sem_token_401():
    assert client.get("/api/v1/devices/dev-clip-1/clipboard").status_code == 401


def test_com_agente_offline_503():
    headers, uid = _auth_headers("clip6@example.com")
    _add_device(uid, "dev-clip-6")
    assert (
        client.get("/api/v1/devices/dev-clip-6/clipboard", headers=headers).status_code
        == 503
    )


def test_aviso_sem_ninguem_olhando_nao_e_guardado():
    """Guardar o que alguém copiou para entregar depois seria guardar
    justamente o tipo de coisa que não se deve guardar."""
    assert viewers.notify("dev-sem-viewer", {"type": "clipboard", "text": "x"}) == 0


def test_agente_pode_avisar_sem_ninguem_esperando():
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-clip-ws",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()  # pair_code
        ws.send_json({"type": "clipboard_changed", "text": "ninguém ouvindo"})
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"


def test_health_anuncia_o_recurso():
    assert "clipboard" in client.get("/health").json()["features"]
