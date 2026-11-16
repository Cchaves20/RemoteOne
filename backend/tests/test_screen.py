from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import _start_stream_message, app
from app.models import Device, User
from app.screen import FrameStore, frame_store

client = TestClient(app)


def _register(email: str = "tela@example.com") -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _pair_device(user_id: int, device_id: str = "dev-scr") -> None:
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


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_json(self, message):
        self.sent.append(message)


# --- FrameStore --------------------------------------------------------------


def test_start_stream_message_default_and_tuned():
    # Sem parâmetros: só o max_fps padrão.
    base = _start_stream_message({"token": "x"})
    assert base["type"] == "start_stream"
    assert "quality" not in base and "max_width" not in base

    # Com qualidade e largura, dentro da faixa.
    tuned = _start_stream_message({"fps": 15, "quality": 75, "max_width": 1600})
    assert tuned == {
        "type": "start_stream",
        "max_fps": 15,
        "quality": 75,
        "max_width": 1600,
    }


def test_start_stream_message_clamps_out_of_range():
    msg = _start_stream_message({"fps": 999, "quality": 5, "max_width": 99999})
    assert msg["max_fps"] == 30  # teto de fps
    assert msg["quality"] == 20  # piso de qualidade
    assert msg["max_width"] == 1920  # teto de largura


def test_frame_store_put_get_clear():
    store = FrameStore()
    assert store.get("d") is None
    store.put("d", b"jpegbytes")
    assert store.get("d") == b"jpegbytes"
    store.clear("d")
    assert store.get("d") is None


# --- endpoints ---------------------------------------------------------------


def test_start_requires_auth():
    assert client.post("/api/v1/devices/dev-scr/screen/start").status_code == 401


def test_start_unknown_device_404():
    headers, _ = _register()
    assert client.post(
        "/api/v1/devices/naoexiste/screen/start", headers=headers
    ).status_code == 404


def test_start_offline_agent_503():
    headers, user_id = _register()
    _pair_device(user_id)
    assert client.post(
        "/api/v1/devices/dev-scr/screen/start", headers=headers
    ).status_code == 503


def test_start_sends_command_to_agent():
    headers, user_id = _register()
    _pair_device(user_id)
    fake = FakeWS()
    manager.register("dev-scr", fake)
    try:
        resp = client.post("/api/v1/devices/dev-scr/screen/start", headers=headers)
        assert resp.status_code == 204
        assert fake.sent[0]["type"] == "start_stream"
        assert fake.sent[0]["max_fps"] > 0
    finally:
        manager.unregister("dev-scr", fake)


def test_get_screen_without_frame_is_503():
    headers, user_id = _register()
    _pair_device(user_id)
    frame_store.clear("dev-scr")
    assert client.get("/api/v1/devices/dev-scr/screen", headers=headers).status_code == 503


def test_get_screen_returns_jpeg():
    headers, user_id = _register()
    _pair_device(user_id)
    frame_store.put("dev-scr", b"\xff\xd8\xff-fake-jpeg")
    try:
        resp = client.get("/api/v1/devices/dev-scr/screen", headers=headers)
        assert resp.status_code == 200
        assert resp.headers["content-type"] == "image/jpeg"
        assert resp.content == b"\xff\xd8\xff-fake-jpeg"
    finally:
        frame_store.clear("dev-scr")


def test_stop_clears_frame_and_notifies_agent():
    headers, user_id = _register()
    _pair_device(user_id)
    frame_store.put("dev-scr", b"x")
    fake = FakeWS()
    manager.register("dev-scr", fake)
    try:
        resp = client.post("/api/v1/devices/dev-scr/screen/stop", headers=headers)
        assert resp.status_code == 204
        assert frame_store.get("dev-scr") is None
        assert fake.sent[-1]["type"] == "stop_stream"
    finally:
        manager.unregister("dev-scr", fake)


def test_screen_of_another_user_is_404():
    headers_a, user_a = _register("a2@example.com")
    headers_b, _ = _register("b2@example.com")
    _pair_device(user_a, "dev-a2")
    assert client.get(
        "/api/v1/devices/dev-a2/screen", headers=headers_b
    ).status_code == 404
