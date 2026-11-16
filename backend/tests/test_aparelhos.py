"""Aparelhos conectados: uma sessão por login, e tirar um de cada vez.

O que esta suíte guarda (ver `app/sessoes.py`):

- cada login aparece na lista, com o nome que o app mandou;
- encerrar um aparelho derruba só ele, na hora, inclusive o refresh;
- o refresh muda a cada renovação, e o usado de novo fora da folga derruba a
  sessão e avisa o dono;
- o app antigo (sem `rotacao`, sem `sid`) continua entrando, e aparece na lista;
- trocar ou redefinir a senha fecha as outras sessões.
"""

from datetime import UTC, datetime, timedelta
from urllib.parse import quote

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import SessionLocal
from app.main import app
from app.models import Sessao, User
from app.security import create_access_token, create_refresh_token

client = TestClient(app)

EMAIL = "aparelhos@example.com"
NOVA = "OutraSenha456!"


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _entrar(aparelho: str | None = None) -> dict:
    headers = {"X-Deskside-Aparelho": quote(aparelho)} if aparelho is not None else {}
    resp = client.post(
        "/api/v1/auth/login", json={"email": EMAIL, "password": SENHA}, headers=headers
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _lista(access: str) -> list[dict]:
    resp = client.get("/api/v1/auth/sessions", headers=_h(access))
    assert resp.status_code == 200, resp.text
    return resp.json()


def _renovar(refresh: str, rotacao: bool = True):
    return client.post(
        "/api/v1/auth/refresh", json={"refresh_token": refresh, "rotacao": rotacao}
    )


def _me(access: str) -> int:
    return client.get("/api/v1/auth/me", headers=_h(access)).status_code


def _envelhecer_a_troca(segundos: int = 120) -> None:
    """Põe a última troca de refresh no passado, além da folga."""
    with SessionLocal() as db:
        for sessao in db.scalars(select(Sessao)).all():
            sessao.geracao_em = datetime.now(UTC) - timedelta(seconds=segundos)
        db.commit()


# --- a lista ----------------------------------------------------------------------


def test_cada_login_aparece_na_lista_com_o_nome_do_aparelho():
    criar_conta(client, email=EMAIL)
    celular = _entrar("iPhone · iOS 18.1")
    _entrar("Tablet Android")

    lista = _lista(celular["access_token"])
    nomes = {s["aparelho"] for s in lista}
    assert {"iPhone · iOS 18.1", "Tablet Android"} <= nomes
    atual = [s for s in lista if s["atual"]]
    assert len(atual) == 1 and atual[0]["aparelho"] == "iPhone · iOS 18.1"
    # Com fuso: sem ele o app leria como hora local.
    assert atual[0]["ultimo_uso"].endswith(("Z", "+00:00"))


def test_nome_do_aparelho_e_limpo_e_cortado():
    criar_conta(client, email=EMAIL)
    tokens = _entrar("x" * 200 + "\x07")
    nome = next(s["aparelho"] for s in _lista(tokens["access_token"]) if s["atual"])
    assert nome == "x" * 80


# --- encerrar ---------------------------------------------------------------------


def test_encerrar_um_aparelho_derruba_so_ele():
    criar_conta(client, email=EMAIL)
    meu = _entrar("meu")
    outro = _entrar("outro")
    sid = next(s["id"] for s in _lista(meu["access_token"]) if s["aparelho"] == "outro")

    resp = client.delete(f"/api/v1/auth/sessions/{sid}", headers=_h(meu["access_token"]))
    assert resp.status_code == 204

    assert _me(outro["access_token"]) == 401
    assert _renovar(outro["refresh_token"]).status_code == 401
    assert _me(meu["access_token"]) == 200
    assert "outro" not in {s["aparelho"] for s in _lista(meu["access_token"])}


def test_nao_encerra_sessao_de_outra_conta():
    criar_conta(client, email=EMAIL)
    alheio = criar_conta(client, email="alheio@example.com")
    meu = _entrar()
    sid = _lista(alheio["access_token"])[0]["id"]

    resp = client.delete(f"/api/v1/auth/sessions/{sid}", headers=_h(meu["access_token"]))
    assert resp.status_code == 404
    assert _me(alheio["access_token"]) == 200


def test_sair_de_todos_os_outros():
    criar_conta(client, email=EMAIL)
    meu = _entrar("meu")
    outros = [_entrar("outro 1"), _entrar("outro 2")]

    resp = client.post(
        "/api/v1/auth/sessions/revoke-others", headers=_h(meu["access_token"])
    )
    assert resp.status_code == 200
    novos = resp.json()

    for outro in outros:
        assert _me(outro["access_token"]) == 401
        assert _renovar(outro["refresh_token"]).status_code == 401
    assert _me(novos["access_token"]) == 200
    assert [s["aparelho"] for s in _lista(novos["access_token"])] == ["meu"]


def test_sair_encerra_a_sessao_no_servidor():
    """Antes, sair só apagava o token do celular: uma cópia dele seguia valendo."""
    criar_conta(client, email=EMAIL)
    tokens = _entrar()
    resp = client.post("/api/v1/auth/logout", headers=_h(tokens["access_token"]))
    assert resp.status_code == 204
    assert _me(tokens["access_token"]) == 401
    assert _renovar(tokens["refresh_token"]).status_code == 401


# --- o refresh muda a cada renovação ----------------------------------------------


def test_renovar_troca_o_refresh():
    criar_conta(client, email=EMAIL)
    tokens = _entrar()

    resp = _renovar(tokens["refresh_token"])
    assert resp.status_code == 200
    novo = resp.json()["refresh_token"]
    assert novo != tokens["refresh_token"]
    assert _me(resp.json()["access_token"]) == 200
    assert _renovar(novo).status_code == 200


def test_refresh_usado_de_novo_derruba_a_sessao_e_avisa(espiao):
    criar_conta(client, email=EMAIL)
    tokens = _entrar("iPhone")
    novo = _renovar(tokens["refresh_token"]).json()["refresh_token"]
    _envelhecer_a_troca()
    espiao.avisos.clear()

    # Quem copiou o token antigo tenta usá-lo.
    assert _renovar(tokens["refresh_token"]).status_code == 401
    # A sessão caiu para os dois: nem o dono renova mais.
    assert _renovar(novo).status_code == 401
    assert espiao.avisos[0][1] == "Encerramos um acesso à sua conta Deskside"
    assert '"iPhone"' in espiao.avisos[0][2]


def test_renovacao_repetida_logo_em_seguida_passa():
    """A resposta perdida no túnel: o app tenta de novo com o mesmo token."""
    criar_conta(client, email=EMAIL)
    tokens = _entrar()
    primeira = _renovar(tokens["refresh_token"])
    segunda = _renovar(tokens["refresh_token"])
    assert primeira.status_code == 200
    assert segunda.status_code == 200
    # As duas respostas renovam a partir daqui.
    assert _renovar(segunda.json()["refresh_token"]).status_code == 200


# --- o app que já está nos celulares --------------------------------------------


def test_app_antigo_renova_sem_trocar_o_refresh():
    criar_conta(client, email=EMAIL)
    tokens = _entrar()
    for _ in range(3):
        resp = _renovar(tokens["refresh_token"], rotacao=False)
        assert resp.status_code == 200
        assert "refresh_token" not in resp.json()


def test_token_de_antes_das_sessoes_continua_valendo_e_aparece():
    """Quem estava logado antes da atualização não é deslogado por ela."""
    criar_conta(client, email=EMAIL)
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == EMAIL))
        uid, chave = str(user.id), user.token_key
    antigo = create_refresh_token(uid, chave)
    assert _me(create_access_token(uid, chave)) == 200

    for _ in range(2):
        resp = _renovar(antigo, rotacao=False)
        assert resp.status_code == 200
    # Uma sessão só para as duas renovações, e é a de quem pediu a lista.
    with SessionLocal() as db:
        assert len(db.scalars(select(Sessao).where(Sessao.legado.is_not(None))).all()) == 1
    atual = next(s for s in _lista(resp.json()["access_token"]) if s["atual"])
    assert atual["aparelho"] == ""

    # Encerrada a sessão, o token antigo não cria outra.
    meu = _entrar()
    client.delete(f"/api/v1/auth/sessions/{atual['id']}", headers=_h(meu["access_token"]))
    assert _renovar(antigo, rotacao=False).status_code == 401


def test_app_novo_com_token_antigo_passa_a_trocar():
    criar_conta(client, email=EMAIL)
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == EMAIL))
        antigo = create_refresh_token(str(user.id), user.token_key)

    novo = _renovar(antigo).json()["refresh_token"]
    assert _renovar(novo).status_code == 200
    _envelhecer_a_troca()
    # O antigo virou geração passada: usá-lo agora é cópia.
    assert _renovar(antigo).status_code == 401


# --- senha ------------------------------------------------------------------------


def test_trocar_a_senha_mantem_so_este_aparelho():
    criar_conta(client, email=EMAIL)
    meu = _entrar("meu")
    outro = _entrar("outro")
    resp = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": SENHA, "new_password": NOVA},
        headers=_h(meu["access_token"]),
    )
    assert resp.status_code == 200
    novos = resp.json()

    assert _renovar(outro["refresh_token"]).status_code == 401
    assert [s["aparelho"] for s in _lista(novos["access_token"])] == ["meu"]


def test_redefinir_a_senha_fecha_todas(espiao):
    criar_conta(client, email=EMAIL)
    antes = _entrar("antes")
    client.post("/api/v1/auth/password/forgot", json={"email": EMAIL})
    resp = client.post(
        "/api/v1/auth/password/reset",
        json={
            "destination": EMAIL,
            "code": espiao.ultimo_codigo(EMAIL),
            "password": NOVA,
            "password_confirm": NOVA,
        },
        headers={"X-Deskside-Aparelho": "depois"},
    )
    assert resp.status_code == 200

    assert _renovar(antes["refresh_token"]).status_code == 401
    assert [s["aparelho"] for s in _lista(resp.json()["access_token"])] == ["depois"]


# --- arrumação ----------------------------------------------------------------------


def test_sessao_sem_uso_ha_mais_de_30_dias_some():
    criar_conta(client, email=EMAIL)
    _entrar("velho")
    with SessionLocal() as db:
        for sessao in db.scalars(select(Sessao)).all():
            sessao.ultimo_uso = datetime.now(UTC) - timedelta(days=31)
        db.commit()

    novo = _entrar("novo")
    assert [s["aparelho"] for s in _lista(novo["access_token"])] == ["novo"]
    with SessionLocal() as db:
        assert db.scalar(select(Sessao).where(Sessao.aparelho == "velho")) is None


def test_excluir_a_conta_leva_as_sessoes():
    criar_conta(client, email=EMAIL)
    tokens = _entrar()
    resp = client.request(
        "DELETE",
        "/api/v1/auth/me",
        json={"password": SENHA},
        headers=_h(tokens["access_token"]),
    )
    assert resp.status_code == 204
    with SessionLocal() as db:
        assert db.scalars(select(Sessao)).all() == []


def test_a_tela_do_computador_fecha_para_o_aparelho_encerrado():
    """O canal da tela tem autenticação própria, e precisava da mesma
    conferência: é por ele que passam imagem, teclado e mouse."""
    from app.main import _authenticate_viewer
    from app.models import Device

    criar_conta(client, email=EMAIL)
    meu = _entrar("meu")
    outro = _entrar("outro")
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == EMAIL))
        db.add(Device(device_id="dev-ap-1", user_id=uid, name="pc", os="windows", hostname="pc"))
        db.commit()
    assert _authenticate_viewer(outro["access_token"], "dev-ap-1")

    sid = next(s["id"] for s in _lista(meu["access_token"]) if s["aparelho"] == "outro")
    client.delete(f"/api/v1/auth/sessions/{sid}", headers=_h(meu["access_token"]))

    assert not _authenticate_viewer(outro["access_token"], "dev-ap-1")
    assert _authenticate_viewer(meu["access_token"], "dev-ap-1")
