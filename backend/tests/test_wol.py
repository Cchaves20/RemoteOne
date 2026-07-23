"""Testes do Wake-on-LAN peer-to-peer (endpoint /wake)."""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User

client = TestClient(app)


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, message):
        self.sent.append(message)


def _register(email: str) -> tuple[dict, int]:
    tokens = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "senhaSegura123"}
    ).json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _add_device(user_id, device_id, mac=None, public_ip=None) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name=device_id,
                os="windows",
                hostname=device_id,
                mac_address=mac,
                last_public_ip=public_ip,
            )
        )
        db.commit()


def test_wake_relays_to_peer_on_same_lan():
    headers, uid = _register("wol1@example.com")
    _add_device(uid, "alvo", mac="01:23:45:AB:CD:EF", public_ip="200.1.1.1")
    _add_device(uid, "peer")
    peer_ws = FakeWS()
    manager.register("peer", peer_ws, public_ip="200.1.1.1")
    try:
        resp = client.post("/api/v1/devices/alvo/wake", headers=headers)
        assert resp.status_code == 204
        assert peer_ws.sent[-1] == {"type": "wake", "mac": "01:23:45:AB:CD:EF"}
    finally:
        manager.unregister("peer", peer_ws)


def test_wake_without_peer_on_same_lan_409():
    headers, uid = _register("wol2@example.com")
    _add_device(uid, "alvo2", mac="01:23:45:AB:CD:EF", public_ip="200.1.1.1")
    # Peer online, mas em OUTRA rede (IP público diferente).
    peer_ws = FakeWS()
    _add_device(uid, "peer2")
    manager.register("peer2", peer_ws, public_ip="200.9.9.9")
    try:
        resp = client.post("/api/v1/devices/alvo2/wake", headers=headers)
        assert resp.status_code == 409
        assert peer_ws.sent == []
    finally:
        manager.unregister("peer2", peer_ws)


def test_wake_when_already_online_409():
    headers, uid = _register("wol3@example.com")
    _add_device(uid, "alvo3", mac="01:23:45:AB:CD:EF", public_ip="200.1.1.1")
    ws = FakeWS()
    manager.register("alvo3", ws, public_ip="200.1.1.1")
    try:
        assert client.post("/api/v1/devices/alvo3/wake", headers=headers).status_code == 409
    finally:
        manager.unregister("alvo3", ws)


def test_wake_without_mac_409():
    headers, uid = _register("wol4@example.com")
    _add_device(uid, "alvo4", mac=None, public_ip="200.1.1.1")
    assert client.post("/api/v1/devices/alvo4/wake", headers=headers).status_code == 409


def test_wake_unknown_device_404():
    headers, _ = _register("wol5@example.com")
    assert client.post("/api/v1/devices/naoexiste/wake", headers=headers).status_code == 404
