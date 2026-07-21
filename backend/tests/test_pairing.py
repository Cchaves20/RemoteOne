from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import SessionLocal
from app.main import app
from app.models import PairingRequest
from app.pairing import _ALPHABET, _CODE_LEN, generate_pairing_code

client = TestClient(app)

CREDS = {"email": "dono@example.com", "password": "senhaSegura123"}
HELLO = {
    "type": "hello",
    "device_id": "dev-abc",
    "hostname": "dell-g5",
    "os": "windows",
    "agent_version": "0.1.0",
}


def _auth_headers(creds=CREDS) -> dict:
    tokens = client.post("/api/v1/auth/register", json=creds).json()
    return {"Authorization": f"Bearer {tokens['access_token']}"}


# --- gerador de código -------------------------------------------------------


def test_generate_code_shape():
    code = generate_pairing_code()
    assert len(code) == _CODE_LEN
    assert all(c in _ALPHABET for c in code)


def test_generated_codes_differ():
    assert generate_pairing_code() != generate_pairing_code()


# --- fluxo WebSocket + HTTP --------------------------------------------------


def test_agent_receives_pair_code_when_unpaired():
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        assert ws.receive_json()["type"] == "welcome"
        intro = ws.receive_json()
        assert intro["type"] == "pair_code"
        assert len(intro["code"]) == _CODE_LEN


def test_full_pairing_flow():
    headers = _auth_headers()
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        ws.receive_json()  # welcome
        code = ws.receive_json()["code"]

        # Usuário reivindica o código.
        resp = client.post("/api/v1/pairing/claim", json={"code": code}, headers=headers)
        assert resp.status_code == 201
        assert resp.json()["device_id"] == "dev-abc"

        # O dispositivo aparece na conta.
        devices = client.get("/api/v1/devices", headers=headers).json()
        assert [d["device_id"] for d in devices] == ["dev-abc"]

        # O agente é avisado no próximo heartbeat.
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"
        assert ws.receive_json() == {"type": "paired", "user_email": CREDS["email"]}


def test_already_paired_agent_receives_paired_on_connect():
    headers = _auth_headers({"email": "outro@example.com", "password": "senhaSegura123"})
    # Primeiro pareia.
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        ws.receive_json()
        code = ws.receive_json()["code"]
        client.post("/api/v1/pairing/claim", json={"code": code}, headers=headers)

    # Numa nova conexão, o agente já recebe `paired` em vez de `pair_code`.
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        ws.receive_json()  # welcome
        intro = ws.receive_json()
        assert intro["type"] == "paired"
        assert intro["user_email"] == "outro@example.com"


def test_claim_invalid_code():
    headers = _auth_headers()
    resp = client.post("/api/v1/pairing/claim", json={"code": "NAOEXISTE"}, headers=headers)
    assert resp.status_code == 404


def test_claim_requires_authentication():
    assert client.post("/api/v1/pairing/claim", json={"code": "QUALQUER"}).status_code == 401


def test_claim_expired_code():
    headers = _auth_headers()
    # Insere um pedido já expirado diretamente.
    with SessionLocal() as db:
        db.add(
            PairingRequest(
                code="EXPIRADO1",
                device_id="dev-exp",
                hostname="h",
                os="linux",
                expires_at=datetime.now(UTC) - timedelta(seconds=1),
            )
        )
        db.commit()
    resp = client.post("/api/v1/pairing/claim", json={"code": "EXPIRADO1"}, headers=headers)
    assert resp.status_code == 410


def test_claim_twice_conflicts():
    headers = _auth_headers()
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        ws.receive_json()
        code = ws.receive_json()["code"]
    client.post("/api/v1/pairing/claim", json={"code": code}, headers=headers)

    # Gera um segundo código para o mesmo dispositivo e tenta reivindicar.
    with SessionLocal() as db:
        db.add(
            PairingRequest(
                code="SEGUNDO12",
                device_id="dev-abc",
                hostname="dell-g5",
                os="windows",
                expires_at=datetime.now(UTC) + timedelta(seconds=600),
            )
        )
        db.commit()
    resp = client.post("/api/v1/pairing/claim", json={"code": "SEGUNDO12"}, headers=headers)
    assert resp.status_code == 409


def test_devices_are_scoped_per_user():
    headers_a = _auth_headers({"email": "a@example.com", "password": "senhaSegura123"})
    headers_b = _auth_headers({"email": "b@example.com", "password": "senhaSegura123"})
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        ws.receive_json()
        code = ws.receive_json()["code"]
    client.post("/api/v1/pairing/claim", json={"code": code}, headers=headers_a)

    assert len(client.get("/api/v1/devices", headers=headers_a).json()) == 1
    assert client.get("/api/v1/devices", headers=headers_b).json() == []


def test_remove_device():
    headers = _auth_headers()
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(HELLO)
        ws.receive_json()
        code = ws.receive_json()["code"]
    client.post("/api/v1/pairing/claim", json={"code": code}, headers=headers)

    assert client.delete("/api/v1/devices/dev-abc", headers=headers).status_code == 204
    assert client.get("/api/v1/devices", headers=headers).json() == []
    # Remover de novo → 404.
    assert client.delete("/api/v1/devices/dev-abc", headers=headers).status_code == 404


def test_pairing_request_is_replaced_on_reconnect():
    # Duas conexões seguidas devem deixar apenas um pedido pendente por device.
    for _ in range(2):
        with client.websocket_connect("/ws/agent") as ws:
            ws.send_json(HELLO)
            ws.receive_json()
            ws.receive_json()
    with SessionLocal() as db:
        pending = db.scalars(
            select(PairingRequest).where(PairingRequest.device_id == "dev-abc")
        ).all()
    assert len(pending) == 1
