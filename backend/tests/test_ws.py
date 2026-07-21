from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _hello(device_id: str = "dev-ws") -> dict:
    return {
        "type": "hello",
        "device_id": device_id,
        "hostname": "dell-g5",
        "os": "windows",
        "agent_version": "0.1.0",
    }


def test_agent_handshake_and_online_presence():
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello())
        welcome = ws.receive_json()
        assert welcome["type"] == "welcome"
        assert welcome["server_version"]

        # Enquanto conectado, o agente aparece na listagem HTTP.
        listed = client.get("/api/v1/agents").json()["agents"]
        assert any(a["device_id"] == "dev-ws" for a in listed)

        # Heartbeat é respondido com ack.
        ws.send_json({"type": "heartbeat"})
        ack = ws.receive_json()
        assert ack["type"] == "ack"


def test_first_message_must_be_hello():
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json({"type": "heartbeat"})
        reply = ws.receive_json()
        assert reply["type"] == "error"


def test_invalid_message_rejected():
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json({"type": "banana"})
        reply = ws.receive_json()
        assert reply["type"] == "error"
