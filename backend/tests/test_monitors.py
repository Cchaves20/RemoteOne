"""Escolha de monitor: listar as telas e trocar qual delas é capturada."""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending

client = TestClient(app)


def _auth(email: str) -> tuple[dict, int]:
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


TELAS = [
    {"id": 1, "name": "Interno", "width": 1920, "height": 1080, "primary": True},
    {"id": 2, "name": "Dell U2419H", "width": 2560, "height": 1440, "primary": False},
]


class InstantAgent:
    def __init__(self, monitors: list[dict] | None = None, selected: int | None = None):
        self.monitors = monitors
        self.selected = selected
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "list_monitors" and self.monitors is not None:
            pending.resolve(
                message["request_id"],
                {"monitors": self.monitors, "selected": self.selected},
            )

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


def test_lista_as_telas_do_computador():
    headers, uid = _auth("mon1@example.com")
    _add_device(uid, "dev-mon-1")
    manager.register("dev-mon-1", InstantAgent(TELAS, selected=2))
    try:
        resp = client.get("/api/v1/devices/dev-mon-1/monitors", headers=headers)
    finally:
        manager.unregister("dev-mon-1")
    assert resp.status_code == 200
    assert resp.json() == {"monitors": TELAS, "selected": 2}


def test_escolhe_a_tela_pelo_id():
    """Pelo id e não pela posição: a ordem muda quando alguém liga ou desliga
    um monitor, e um índice guardado passaria a apontar para outra tela."""
    headers, uid = _auth("mon2@example.com")
    _add_device(uid, "dev-mon-2")
    agent = InstantAgent()
    manager.register("dev-mon-2", agent)
    try:
        assert (
            client.post(
                "/api/v1/devices/dev-mon-2/monitors", json={"monitor": 2}, headers=headers
            ).status_code
            == 204
        )
        assert (
            client.post(
                "/api/v1/devices/dev-mon-2/monitors", json={"monitor": None}, headers=headers
            ).status_code
            == 204
        )
    finally:
        manager.unregister("dev-mon-2")
    assert [m["monitor"] for m in agent.of_type("set_monitor")] == [2, None]


def test_agente_offline_nao_finge_que_deu_certo():
    headers, uid = _auth("mon3@example.com")
    _add_device(uid, "dev-mon-3")
    assert client.get("/api/v1/devices/dev-mon-3/monitors", headers=headers).status_code == 503
    assert (
        client.post(
            "/api/v1/devices/dev-mon-3/monitors", json={"monitor": 1}, headers=headers
        ).status_code
        == 503
    )


def test_computador_de_outra_conta_nao_aparece():
    headers, uid = _auth("mon4@example.com")
    _add_device(uid, "dev-mon-4")
    intruso, _ = _auth("intruso-mon@example.com")
    assert client.get("/api/v1/devices/dev-mon-4/monitors", headers=intruso).status_code == 404
    assert (
        client.post(
            "/api/v1/devices/dev-mon-4/monitors", json={"monitor": 1}, headers=intruso
        ).status_code
        == 404
    )


def test_sem_token_nao_responde():
    assert client.get("/api/v1/devices/dev-mon-1/monitors").status_code == 401


def test_parse_da_resposta_do_agente():
    message = parse_client_message(
        {"type": "monitor_list", "request_id": "r1", "monitors": TELAS, "selected": 1}
    )
    assert [m.name for m in message.monitors] == ["Interno", "Dell U2419H"]
    assert message.selected == 1


def test_agente_sem_selecao_vale_o_principal():
    """Ausente = ninguém escolheu. É diferente de escolher o monitor 0."""
    message = parse_client_message(
        {"type": "monitor_list", "request_id": "r1", "monitors": TELAS}
    )
    assert message.selected is None


def test_health_anuncia_o_recurso():
    assert "monitors" in client.get("/health").json()["features"]
