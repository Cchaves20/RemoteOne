"""Testes da verificação em duas etapas (TOTP)."""

import pyotp
from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

CREDS = {"email": "2fa@example.com", "password": SENHA}


def _register_headers(creds=CREDS) -> dict:
    tokens = criar_conta(client, email=creds["email"], password=creds["password"])
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _enable_2fa(headers) -> str:
    """Ativa o 2FA e devolve o segredo TOTP."""
    setup = client.post("/api/v1/auth/2fa/setup", headers=headers).json()
    secret = setup["secret"]
    assert setup["otpauth_uri"].startswith("otpauth://totp/")
    code = pyotp.TOTP(secret).now()
    resp = client.post("/api/v1/auth/2fa/enable", json={"code": code}, headers=headers)
    assert resp.status_code == 204
    return secret


def test_me_reports_2fa_disabled_by_default():
    headers = _register_headers()
    assert client.get("/api/v1/auth/me", headers=headers).json()["totp_enabled"] is False


def test_enable_flow_and_me_flag():
    headers = _register_headers()
    _enable_2fa(headers)
    assert client.get("/api/v1/auth/me", headers=headers).json()["totp_enabled"] is True


def test_enable_rejects_wrong_code():
    headers = _register_headers()
    client.post("/api/v1/auth/2fa/setup", headers=headers)
    resp = client.post("/api/v1/auth/2fa/enable", json={"code": "000000"}, headers=headers)
    assert resp.status_code == 401


def test_login_requires_code_when_2fa_on():
    headers = _register_headers()
    secret = _enable_2fa(headers)

    # Sem código: 401 com detalhe reconhecível pelo app.
    r1 = client.post("/api/v1/auth/login", json=CREDS)
    assert r1.status_code == 401
    assert r1.json()["detail"] == "two_factor_required"

    # Código errado: 401 two_factor_invalid.
    r2 = client.post("/api/v1/auth/login", json={**CREDS, "totp_code": "000000"})
    assert r2.status_code == 401
    assert r2.json()["detail"] == "two_factor_invalid"

    # Código certo: sucesso.
    code = pyotp.TOTP(secret).now()
    r3 = client.post("/api/v1/auth/login", json={**CREDS, "totp_code": code})
    assert r3.status_code == 200
    assert r3.json()["access_token"]


def test_disable_2fa_restores_normal_login():
    headers = _register_headers()
    _enable_2fa(headers)
    # Desativa com a senha.
    resp = client.post(
        "/api/v1/auth/2fa/disable", json={"password": CREDS["password"]}, headers=headers
    )
    assert resp.status_code == 204
    # Login volta a funcionar sem código.
    assert client.post("/api/v1/auth/login", json=CREDS).status_code == 200


def test_disable_wrong_password():
    headers = _register_headers()
    _enable_2fa(headers)
    resp = client.post(
        "/api/v1/auth/2fa/disable", json={"password": "errada12345"}, headers=headers
    )
    assert resp.status_code == 401
