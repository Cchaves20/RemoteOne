from fastapi.testclient import TestClient

from app import signaling
from app.main import app

client = TestClient(app)


def test_health_returns_ok():
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"]


def test_health_lista_os_recursos_do_codigo():
    """Serve para conferir qual código está no ar, sem depender de dedução."""
    body = client.get("/health").json()
    assert "webrtc-signaling" in body["features"]
    # A sinalização de WebRTC precisa realmente existir, senão a lista mente.
    assert callable(getattr(signaling, "to_agent", None))


def test_api_root_returns_app_name():
    response = client.get("/api/v1")
    assert response.status_code == 200
    assert response.json()["name"] == "Deskside Backend"
