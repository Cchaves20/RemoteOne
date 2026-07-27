"""Testes de gerenciamento de aplicativos (Etapa 8) e do RPC com o agente."""

import asyncio

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.rpc import PendingRequests

client = TestClient(app)

HELLO = {
    "type": "hello",
    "device_id": "dev-apps",
    "hostname": "dell-g5",
    "os": "windows",
    "agent_version": "0.1.0",
}


def _auth_headers(email: str) -> tuple[dict, int]:
    tokens = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "senhaSegura123"}
    ).json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _add_device(user_id: int, device_id: str = "dev-apps") -> None:
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


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, message):
        self.sent.append(message)


# --- registro de pedidos (pergunta e resposta com o agente) -------------------


def test_pending_resolve_delivers_payload():
    async def cenario():
        pendentes = PendingRequests()
        request_id, future = pendentes.create()
        assert pendentes.pending_count() == 1

        assert pendentes.resolve(request_id, [{"id": "1", "name": "Chrome"}]) is True
        assert await future == [{"id": "1", "name": "Chrome"}]
        assert pendentes.pending_count() == 0

        # Resolver de novo não encontra ninguém esperando.
        assert pendentes.resolve(request_id, []) is False

    asyncio.run(cenario())


def test_pending_cancel_discards_request():
    async def cenario():
        pendentes = PendingRequests()
        request_id, future = pendentes.create()
        pendentes.cancel(request_id)
        assert pendentes.pending_count() == 0
        assert future.cancelled()

    asyncio.run(cenario())


def test_pending_timeout_leaves_no_leak():
    """Se o agente não responde, o pedido é descartado (sem vazar memória)."""

    async def cenario():
        pendentes = PendingRequests()
        request_id, future = pendentes.create()
        try:
            await asyncio.wait_for(future, timeout=0.01)
        except TimeoutError:
            pendentes.cancel(request_id)
        assert pendentes.pending_count() == 0

    asyncio.run(cenario())


# --- canal do agente ---------------------------------------------------------


def test_agent_can_send_app_list_without_error():
    """Uma resposta `app_list` (mesmo sem ninguém esperando) é aceita e a
    conexão do agente segue viva."""
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()  # pair_code

        ws.send_json(
            {
                "type": "app_list",
                "request_id": "inexistente",
                "apps": [{"id": "C:\\Spotify.lnk", "name": "Spotify"}],
            }
        )
        # Sem resposta de erro: o heartbeat seguinte continua sendo respondido.
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"


# --- endpoints ---------------------------------------------------------------


def test_list_apps_offline_agent_503():
    headers, uid = _auth_headers("apps1@example.com")
    _add_device(uid)
    resp = client.get("/api/v1/devices/dev-apps/apps", headers=headers)
    assert resp.status_code == 503


def test_list_apps_rejects_unknown_kind():
    headers, uid = _auth_headers("apps2@example.com")
    _add_device(uid)
    resp = client.get("/api/v1/devices/dev-apps/apps?kind=xpto", headers=headers)
    assert resp.status_code == 422


def test_list_apps_accepts_the_three_kinds():
    """desktop (dock), installed (menu Iniciar) e running são aceitos — o 503
    mostra que passaram da validação e chegaram ao relay."""
    headers, uid = _auth_headers("apps6@example.com")
    _add_device(uid, "dev-kinds")
    for kind in ("desktop", "installed", "running"):
        resp = client.get(
            f"/api/v1/devices/dev-kinds/apps?kind={kind}", headers=headers
        )
        assert resp.status_code == 503, kind


def test_list_apps_sends_request_to_agent_and_times_out():
    """Com o agente conectado mas mudo, o pedido é enviado e o backend
    responde 504 em vez de ficar preso para sempre."""
    from app import devices as devices_module

    headers, uid = _auth_headers("apps5@example.com")
    _add_device(uid, "dev-mudo")
    fake = FakeWS()
    manager.register("dev-mudo", fake)
    original = devices_module._APPS_TIMEOUT_SECONDS
    devices_module._APPS_TIMEOUT_SECONDS = 0.2  # não segurar a suíte
    try:
        resp = client.get("/api/v1/devices/dev-mudo/apps", headers=headers)
        assert resp.status_code == 504
        assert fake.sent[-1]["type"] == "list_apps"
        assert fake.sent[-1]["kind"] == "installed"
        assert fake.sent[-1]["request_id"]
    finally:
        devices_module._APPS_TIMEOUT_SECONDS = original
        manager.unregister("dev-mudo", fake)


def test_launch_and_close_relay_to_agent():
    headers, uid = _auth_headers("apps4@example.com")
    _add_device(uid, "dev-relay")
    fake = FakeWS()
    manager.register("dev-relay", fake)
    try:
        r1 = client.post(
            "/api/v1/devices/dev-relay/apps/launch",
            json={"id": "C:\\Spotify.lnk"},
            headers=headers,
        )
        assert r1.status_code == 204
        assert fake.sent[-1] == {"type": "launch_app", "id": "C:\\Spotify.lnk"}

        r2 = client.post(
            "/api/v1/devices/dev-relay/apps/close",
            json={"id": "4321"},
            headers=headers,
        )
        assert r2.status_code == 204
        assert fake.sent[-1] == {"type": "close_app", "id": "4321"}
    finally:
        manager.unregister("dev-relay", fake)


def test_apps_of_another_user_is_404():
    _, user_a = _auth_headers("a3@example.com")
    headers_b, _ = _auth_headers("b3@example.com")
    _add_device(user_a, "dev-alheio")
    assert client.get(
        "/api/v1/devices/dev-alheio/apps", headers=headers_b
    ).status_code == 404
    assert client.post(
        "/api/v1/devices/dev-alheio/apps/launch",
        json={"id": "x"},
        headers=headers_b,
    ).status_code == 404
