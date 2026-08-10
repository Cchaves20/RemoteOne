"""Manter o computador pronto para ser alcançado.

O recurso existe porque acordar uma máquina adormecida não é padronizável -
depende de firmware e driver de cada placa de rede. Não deixar adormecer, sim.

O que se testa aqui, além do caminho feliz: que o estado é **perguntado ao
agente** e não guardado, e que os três campos da resposta chegam separados. Um
notebook na bateria com a opção ligada não está segurando nada, e juntar essas
informações faria o app prometer um computador alcançável que vai dormir na
próxima pausa.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending
from conftest import criar_conta

client = TestClient(app)


def _auth_headers(email: str) -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
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
    """Agente que responde na hora, dentro do próprio envio."""

    def __init__(
        self,
        enabled: bool = True,
        holding: bool = True,
        source: str = "ac",
        responde: bool = True,
    ):
        self.estado = {"enabled": enabled, "holding": holding, "source": source}
        self.responde = responde
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "keep_awake_info" and self.responde:
            pending.resolve(message["request_id"], dict(self.estado))

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_estado_do_agente():
    message = parse_client_message(
        {
            "type": "keep_awake_state",
            "request_id": "r1",
            "enabled": True,
            "holding": False,
            "source": "battery",
        }
    )
    assert message.enabled is True
    assert message.holding is False
    assert message.source == "battery"


def test_parse_recusa_fonte_desconhecida():
    """A fonte é fechada de propósito: o app decide o texto a partir dela, e um
    valor novo chegando calado viraria tela em branco."""
    try:
        parse_client_message(
            {
                "type": "keep_awake_state",
                "request_id": "r1",
                "enabled": True,
                "holding": True,
                "source": "solar",
            }
        )
    except ValueError:
        return
    raise AssertionError("fonte inválida deveria ter sido recusada")


# --- consultar ---------------------------------------------------------------


def test_estado_vem_do_agente():
    headers, uid = _auth_headers("ka1@example.com")
    _add_device(uid, "dev-ka-1")
    agent = InstantAgent()
    manager.register("dev-ka-1", agent)
    try:
        resp = client.get("/api/v1/devices/dev-ka-1/keep-awake", headers=headers)
    finally:
        manager.unregister("dev-ka-1")
    assert resp.status_code == 200
    assert resp.json() == {"enabled": True, "holding": True, "source": "ac"}
    assert agent.of_type("keep_awake_info")[0]["request_id"]


def test_ligado_na_bateria_nao_esta_segurando():
    """O caso que justifica os três campos existirem separados."""
    headers, uid = _auth_headers("ka2@example.com")
    _add_device(uid, "dev-ka-2")
    manager.register(
        "dev-ka-2", InstantAgent(enabled=True, holding=False, source="battery")
    )
    try:
        resp = client.get("/api/v1/devices/dev-ka-2/keep-awake", headers=headers)
    finally:
        manager.unregister("dev-ka-2")
    assert resp.json() == {"enabled": True, "holding": False, "source": "battery"}


def test_estado_com_agente_offline_503():
    headers, uid = _auth_headers("ka3@example.com")
    _add_device(uid, "dev-ka-3")
    resp = client.get("/api/v1/devices/dev-ka-3/keep-awake", headers=headers)
    assert resp.status_code == 503


def test_estado_que_nao_responde_da_504_e_nao_vaza_pedido():
    headers, uid = _auth_headers("ka4@example.com")
    _add_device(uid, "dev-ka-4")
    manager.register("dev-ka-4", InstantAgent(responde=False))
    antes = pending.pending_count()
    try:
        resp = client.get("/api/v1/devices/dev-ka-4/keep-awake", headers=headers)
    finally:
        manager.unregister("dev-ka-4")
    assert resp.status_code == 504
    assert pending.pending_count() == antes, "o pedido abandonado ficou pendurado"


# --- ligar e desligar --------------------------------------------------------


def test_liga_e_desliga_no_agente():
    headers, uid = _auth_headers("ka5@example.com")
    _add_device(uid, "dev-ka-5")
    agent = InstantAgent()
    manager.register("dev-ka-5", agent)
    try:
        for ligado in (False, True):
            resp = client.post(
                "/api/v1/devices/dev-ka-5/keep-awake",
                json={"enabled": ligado},
                headers=headers,
            )
            assert resp.status_code == 204, ligado
    finally:
        manager.unregister("dev-ka-5")
    assert [m["enabled"] for m in agent.of_type("keep_awake")] == [False, True]


def test_ligar_exige_o_campo():
    headers, uid = _auth_headers("ka6@example.com")
    _add_device(uid, "dev-ka-6")
    resp = client.post(
        "/api/v1/devices/dev-ka-6/keep-awake", json={}, headers=headers
    )
    assert resp.status_code == 422


def test_ligar_com_agente_offline_503():
    headers, uid = _auth_headers("ka7@example.com")
    _add_device(uid, "dev-ka-7")
    resp = client.post(
        "/api/v1/devices/dev-ka-7/keep-awake", json={"enabled": True}, headers=headers
    )
    assert resp.status_code == 503


# --- quem pode ---------------------------------------------------------------


def test_de_outra_conta_404():
    """Mexer no consumo de energia do computador de alguém é mexer na casa
    dela - e saber se ele fica acordado diz quando a pessoa não está lá."""
    _, dono = _auth_headers("ka8@example.com")
    _add_device(dono, "dev-ka-8")
    intruso, _ = _auth_headers("ka9@example.com")
    assert (
        client.get("/api/v1/devices/dev-ka-8/keep-awake", headers=intruso).status_code
        == 404
    )
    assert (
        client.post(
            "/api/v1/devices/dev-ka-8/keep-awake",
            json={"enabled": False},
            headers=intruso,
        ).status_code
        == 404
    )


def test_sem_token_401():
    assert client.get("/api/v1/devices/dev-ka-1/keep-awake").status_code == 401
    assert (
        client.post(
            "/api/v1/devices/dev-ka-1/keep-awake", json={"enabled": True}
        ).status_code
        == 401
    )


def test_agente_pode_responder_sem_ninguem_esperando():
    """Resposta atrasada (o pedido já expirou) não derruba a conexão."""
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-ka-ws",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()  # pair_code
        ws.send_json(
            {
                "type": "keep_awake_state",
                "request_id": "inexistente",
                "enabled": True,
                "holding": True,
                "source": "ac",
            }
        )
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"


def test_health_anuncia_o_recurso():
    assert "keep-awake" in client.get("/health").json()["features"]
