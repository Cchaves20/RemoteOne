"""Login, tokens e gerenciamento de conta.

O **cadastro** tem suíte própria (`test_cadastro.py`), porque virou um fluxo de
duas etapas com validação, código e expiração. Aqui a conta é criada pelo
helper e o que se exercita é o que vem depois dela.
"""

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import SessionLocal
from app.main import app
from app.models import Device, User

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


# --- trocar o contato da conta ----------------------------------------------


def test_troca_de_telefone_normaliza_e_muda_o_login():
    """Sem normalizar, a pessoa trocaria o número e ficaria fora da conta.

    Gravar "(11) 98765-4321" como veio produziria uma forma que o login — que
    normaliza — nunca encontraria. A conta continuaria lá, inacessível, e nada
    na tela explicaria por quê.
    """
    tokens = criar_conta(client, phone="11911112222", country="BR")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    resp = client.patch(
        "/api/v1/auth/me/phone",
        json={
            "current_password": SENHA,
            "new_phone": "(11) 98765-4321",
            "country": "BR",
        },
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["phone"] == "+5511987654321"

    # Entra com o novo, escrito de qualquer jeito; não entra com o antigo.
    assert client.post(
        "/api/v1/auth/login",
        json={"phone": "11 98765 4321", "country": "BR", "password": SENHA},
    ).status_code == 200
    assert client.post(
        "/api/v1/auth/login",
        json={"phone": "11911112222", "country": "BR", "password": SENHA},
    ).status_code == 401


def test_troca_de_telefone_exige_senha_e_numero_possivel():
    tokens = criar_conta(client, phone="11933334444", country="BR")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    errada = client.patch(
        "/api/v1/auth/me/phone",
        json={"current_password": "outra1!Senha", "new_phone": "11955556666",
              "country": "BR"},
        headers=headers,
    )
    assert errada.status_code == 401

    curto = client.patch(
        "/api/v1/auth/me/phone",
        json={"current_password": SENHA, "new_phone": "1199", "country": "BR"},
        headers=headers,
    )
    assert curto.status_code == 400
    assert "Brasil" in curto.json()["detail"]


def test_troca_de_telefone_para_um_numero_ja_usado():
    criar_conta(client, phone="11977778888", country="BR")
    tokens = criar_conta(client, phone="11966665555", country="BR")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    resp = client.patch(
        "/api/v1/auth/me/phone",
        json={"current_password": SENHA, "new_phone": "11977778888",
              "country": "BR"},
        headers=headers,
    )
    assert resp.status_code == 409


def test_me_diz_por_qual_das_duas_a_conta_se_identifica():
    """É o que a tela de conta usa para escolher entre "Alterar e-mail" e
    "Alterar telefone". Sem os dois campos na resposta, ela teria de adivinhar."""
    por_email = criar_conta(client, email="quem@example.com")
    corpo = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {por_email['access_token']}"},
    ).json()
    assert corpo["email"] == "quem@example.com"
    assert corpo["phone"] is None
    assert corpo["first_name"] == "Caio"

    por_telefone = criar_conta(client, phone="11922221111", country="BR")
    corpo = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {por_telefone['access_token']}"},
    ).json()
    assert corpo["phone"] == "+5511922221111"
    assert corpo["email"] is None


def test_conta_nova_nao_herda_nada_da_conta_excluida():
    """O defeito que apareceu em uso, e o mecanismo dele.

    O SQLite **reaproveita o identificador**: com `INTEGER PRIMARY KEY`, apagar
    a conta 1 faz a próxima nascer como 1 de novo. Tudo o que ficou para trás
    com `user_id = 1` — computadores pareados, perfis, automações, a ordem da
    barra — passa a pertencer a outra pessoa, sem nada avisar.

    O teste é escrito no nível do produto (cria, povoa, exclui, recria) e não no
    do banco, porque é assim que ele foi descoberto: excluindo a conta pelo app
    e criando outra em seguida.
    """
    tokens = criar_conta(client, email="dono@example.com")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    with SessionLocal() as db:
        antigo = db.scalar(select(User.id).where(User.email == "dono@example.com"))
        db.add(
            Device(
                device_id="dev-do-antigo",
                user_id=antigo,
                name="PC do antigo",
                os="windows",
                hostname="pc",
            )
        )
        db.commit()

    perfil = client.post(
        "/api/v1/profiles",
        json={"name": "Perfil do antigo", "apps": []},
        headers=headers,
    )
    assert perfil.status_code == 201
    assert client.put(
        "/api/v1/profiles/order",
        json={"ids": [perfil.json()["id"]]},
        headers=headers,
    ).status_code == 204
    assert client.post(
        "/api/v1/automations",
        json={"name": "Do antigo", "steps": [{"kind": "media", "action": "mute"}]},
        headers=headers,
    ).status_code == 201

    assert client.request(
        "DELETE", "/api/v1/auth/me", json={"password": SENHA}, headers=headers
    ).status_code == 204

    # A conta nova. Em SQLite ela costuma receber o mesmo id da que saiu — que é
    # justamente a condição que revela o problema.
    novos = criar_conta(client, email="outro@example.com")
    cabecalhos = {"Authorization": f"Bearer {novos['access_token']}"}
    with SessionLocal() as db:
        novo = db.scalar(select(User.id).where(User.email == "outro@example.com"))
    assert novo == antigo, "o teste só prova o que quer provar se o id for reusado"

    assert client.get("/api/v1/devices", headers=cabecalhos).json() == []
    perfis = client.get("/api/v1/profiles", headers=cabecalhos).json()
    assert perfis["profiles"] == []
    assert perfis["order"] == []
    assert client.get("/api/v1/automations", headers=cabecalhos).json()[
        "automations"
    ] == []
