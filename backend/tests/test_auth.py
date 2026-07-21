from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

CREDS = {"email": "caio@example.com", "password": "senhaSegura123"}


def _register(creds=CREDS) -> dict:
    return client.post("/api/v1/auth/register", json=creds).json()


def test_register_returns_token_pair():
    resp = client.post("/api/v1/auth/register", json=CREDS)
    assert resp.status_code == 201
    body = resp.json()
    assert body["access_token"]
    assert body["refresh_token"]
    assert body["token_type"] == "bearer"


def test_register_duplicate_email_conflicts():
    _register()
    resp = client.post("/api/v1/auth/register", json=CREDS)
    assert resp.status_code == 409


def test_register_rejects_invalid_email_and_short_password():
    assert client.post(
        "/api/v1/auth/register",
        json={"email": "não-é-email", "password": "senhaSegura123"},
    ).status_code == 422
    assert client.post(
        "/api/v1/auth/register",
        json={"email": "a@b.com", "password": "curta"},
    ).status_code == 422


def test_login_success_and_wrong_password():
    _register()
    ok = client.post("/api/v1/auth/login", json=CREDS)
    assert ok.status_code == 200
    assert ok.json()["access_token"]

    bad = client.post(
        "/api/v1/auth/login",
        json={"email": CREDS["email"], "password": "errada12345"},
    )
    assert bad.status_code == 401


def test_login_unknown_email():
    resp = client.post(
        "/api/v1/auth/login",
        json={"email": "ninguem@example.com", "password": "senhaSegura123"},
    )
    assert resp.status_code == 401


def test_me_requires_valid_access_token():
    tokens = _register()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    resp = client.get("/api/v1/auth/me", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["email"] == CREDS["email"]


def test_me_without_token_is_unauthorized():
    assert client.get("/api/v1/auth/me").status_code == 401  # sem header Bearer


def test_me_rejects_garbage_token():
    headers = {"Authorization": "Bearer isso-nao-e-um-jwt"}
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 401


def test_refresh_token_issues_new_access_token():
    tokens = _register()
    resp = client.post(
        "/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert resp.status_code == 200
    new_access = resp.json()["access_token"]
    # O novo access token funciona no /me.
    me = client.get(
        "/api/v1/auth/me", headers={"Authorization": f"Bearer {new_access}"}
    )
    assert me.status_code == 200


def test_access_token_cannot_be_used_as_refresh():
    tokens = _register()
    resp = client.post(
        "/api/v1/auth/refresh", json={"refresh_token": tokens["access_token"]}
    )
    assert resp.status_code == 401


def test_refresh_token_cannot_access_protected_route():
    # Um refresh token não vale como Bearer no /me (type != access).
    tokens = _register()
    headers = {"Authorization": f"Bearer {tokens['refresh_token']}"}
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 401
