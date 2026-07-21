from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User

client = TestClient(app)

MOVE = {"kind": "mouse_move", "dx": 10, "dy": -5}


def _register(email: str = "dono@example.com") -> tuple[dict, int]:
    tokens = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "senhaSegura123"}
    ).json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _pair_device(user_id: int, device_id: str = "dev-in") -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name="dell",
                os="windows",
                hostname="dell",
            )
        )
        db.commit()


def test_input_requires_authentication():
    resp = client.post("/api/v1/devices/dev-in/input", json=MOVE)
    assert resp.status_code == 401


def test_input_unknown_device_is_404():
    headers, _ = _register()
    resp = client.post("/api/v1/devices/inexistente/input", json=MOVE, headers=headers)
    assert resp.status_code == 404


def test_input_device_of_another_user_is_404():
    headers_a, user_a = _register("a@example.com")
    headers_b, _ = _register("b@example.com")
    _pair_device(user_a, "dev-a")
    # B não enxerga o dispositivo de A.
    resp = client.post("/api/v1/devices/dev-a/input", json=MOVE, headers=headers_b)
    assert resp.status_code == 404


def test_input_agent_offline_is_503():
    headers, user_id = _register()
    _pair_device(user_id)
    # Dispositivo pareado, mas sem agente conectado.
    resp = client.post("/api/v1/devices/dev-in/input", json=MOVE, headers=headers)
    assert resp.status_code == 503


def test_input_invalid_action_is_422():
    headers, user_id = _register()
    _pair_device(user_id)
    resp = client.post(
        "/api/v1/devices/dev-in/input",
        json={"kind": "mouse_move", "dx": "muito"},
        headers=headers,
    )
    assert resp.status_code == 422


def test_input_relayed_to_connected_agent():
    headers, user_id = _register()
    _pair_device(user_id)

    # Simula o agente conectado registrando um socket falso no manager.
    class FakeWS:
        def __init__(self):
            self.sent = []

        async def send_json(self, message):
            self.sent.append(message)

    fake = FakeWS()
    manager.register("dev-in", fake)
    try:
        resp = client.post("/api/v1/devices/dev-in/input", json=MOVE, headers=headers)
        assert resp.status_code == 204
        assert fake.sent == [{"type": "input", "action": MOVE}]
    finally:
        manager.unregister("dev-in", fake)
