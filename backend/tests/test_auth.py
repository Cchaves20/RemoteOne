"""Login, tokens e gerenciamento de conta.

O **cadastro** tem suíte própria (`test_cadastro.py`), porque virou um fluxo de
duas etapas com validação, código e expiração. Aqui a conta é criada pelo
helper e o que se exercita é o que vem depois dela.
"""

from fastapi.testclient import TestClient

from app.main import app
from conftest import SENHA, criar_conta

client = TestClient(app)

CREDS = {"email": "caio@example.com", "password": SENHA}


def _register(creds=CREDS) -> dict:
    return criar_conta(client, email=creds["email"], password=creds["password"])


def test_nao_existe_atalho_para_criar_conta_sem_verificar():
    """O `/auth/register` antigo saiu, e isso é o recurso — não um resto.

    Enquanto ele existisse, o código de seis dígitos seria decoração: bastaria
    chamar a rota velha para ter conta sem provar posse de e-mail nem de
    telefone. Um teste guarda a porta fechada, porque reabri-la por engano
    (copiando de um commit antigo, por exemplo) não quebraria mais nada.
    """
    resp = client.post(
        "/api/v1/auth/register", json={"email": "atalho@example.com", "password": SENHA}
    )
    assert resp.status_code == 404


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
        json={"email": "ninguem@example.com", "password": SENHA},
    )
    assert resp.status_code == 401


def test_login_exige_um_identificador_e_apenas_um():
    """Nem nenhum, nem os dois: `987654321` não identifica ninguém sem o país,
    e mandar e-mail e telefone juntos não diz por qual deles entrar."""
    assert client.post("/api/v1/auth/login", json={"password": SENHA}).status_code == 422
    assert client.post(
        "/api/v1/auth/login",
        json={"email": "a@b.com", "phone": "11987654321", "country": "BR", "password": SENHA},
    ).status_code == 422
    # Telefone sem país também não serve.
    assert client.post(
        "/api/v1/auth/login", json={"phone": "11987654321", "password": SENHA}
    ).status_code == 422


def test_login_por_telefone():
    """Entrar pelo número, na conta criada pelo número."""
    criar_conta(client, phone="(11) 98765-4321", country="BR")
    ok = client.post(
        "/api/v1/auth/login",
        json={"phone": "11987654321", "country": "BR", "password": SENHA},
    )
    assert ok.status_code == 200
    assert ok.json()["access_token"]

    # A mesma conta, digitada de outro jeito: a normalização é que faz as duas
    # formas caírem no mesmo lugar em vez de virarem contas diferentes.
    outro_jeito = client.post(
        "/api/v1/auth/login",
        json={"phone": "+55 11 98765 4321", "country": "BR", "password": SENHA},
    )
    assert outro_jeito.status_code == 200


def test_login_por_telefone_com_senha_errada():
    criar_conta(client, phone="11912345678", country="BR")
    resp = client.post(
        "/api/v1/auth/login",
        json={"phone": "11912345678", "country": "BR", "password": "Outra1!senha"},
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


# --- gerenciamento de conta (Lote 3) ----------------------------------------


def _register_headers(creds=CREDS) -> dict:
    tokens = _register(creds)
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def test_update_email_changes_login():
    headers = _register_headers()
    resp = client.patch(
        "/api/v1/auth/me/email",
        json={"current_password": CREDS["password"], "new_email": "novo@example.com"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["email"] == "novo@example.com"
    # Login com o e-mail novo funciona; com o antigo, não.
    assert client.post(
        "/api/v1/auth/login",
        json={"email": "novo@example.com", "password": CREDS["password"]},
    ).status_code == 200
    assert client.post("/api/v1/auth/login", json=CREDS).status_code == 401


def test_update_email_wrong_password():
    headers = _register_headers()
    resp = client.patch(
        "/api/v1/auth/me/email",
        json={"current_password": "errada12345", "new_email": "novo@example.com"},
        headers=headers,
    )
    assert resp.status_code == 401


def test_update_email_conflict():
    _register({"email": "ocupado@example.com", "password": SENHA})
    headers = _register_headers()
    resp = client.patch(
        "/api/v1/auth/me/email",
        json={"current_password": CREDS["password"], "new_email": "ocupado@example.com"},
        headers=headers,
    )
    assert resp.status_code == 409


def test_update_password_changes_login():
    headers = _register_headers()
    resp = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": CREDS["password"], "new_password": "novaSenha456!"},
        headers=headers,
    )
    assert resp.status_code == 204
    assert client.post("/api/v1/auth/login", json=CREDS).status_code == 401
    assert client.post(
        "/api/v1/auth/login",
        json={"email": CREDS["email"], "password": "novaSenha456!"},
    ).status_code == 200


def test_update_password_wrong_current():
    headers = _register_headers()
    resp = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": "errada12345", "new_password": "novaSenha456!"},
        headers=headers,
    )
    assert resp.status_code == 401


def test_delete_account_removes_login():
    headers = _register_headers()
    resp = client.request(
        "DELETE",
        "/api/v1/auth/me",
        json={"password": CREDS["password"]},
        headers=headers,
    )
    assert resp.status_code == 204
    # A conta deixou de existir: login falha.
    assert client.post("/api/v1/auth/login", json=CREDS).status_code == 401


def test_delete_account_wrong_password():
    headers = _register_headers()
    resp = client.request(
        "DELETE",
        "/api/v1/auth/me",
        json={"password": "errada12345"},
        headers=headers,
    )
    assert resp.status_code == 401
    # A conta continua utilizável.
    assert client.post("/api/v1/auth/login", json=CREDS).status_code == 200
