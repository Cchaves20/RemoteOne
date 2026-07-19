from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_returns_ok():
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"]


def test_api_root_returns_app_name():
    response = client.get("/api/v1")
    assert response.status_code == 200
    assert response.json()["name"] == "RemoteOne Backend"
