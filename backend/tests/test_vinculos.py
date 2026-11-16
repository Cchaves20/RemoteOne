"""A memória de quem pode falar com qual computador (`app.vinculos`).

O que estes testes garantem é o lado da segurança: guardar a resposta na
memória **não** pode atrasar uma expulsão. Trocar a senha, sair do aparelho e
desparear o computador valem no pedido seguinte, mesmo com a resposta antiga
guardada — e é por isso que cada teste primeiro **aquece** a memória.
"""

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import event, select

from app import vinculos
from app.connections import manager
from app.db import SessionLocal, engine
from app.main import app
from app.models import Device, User
from app.rpc import pending

client = TestClient(app)
EMAIL = "vinculos@example.com"
PC = "pc-vinculos"


class Agente:
    """Responde o primeiro plano na hora."""

    async def send_json(self, message: dict) -> None:
        if message.get("type") == "foreground_info":
            pending.resolve(message["request_id"], {"app": None})


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _entrar() -> dict:
    resp = client.post("/api/v1/auth/login", json={"email": EMAIL, "password": SENHA})
    assert resp.status_code == 200, resp.text
    return resp.json()


def _com_computador() -> dict:
    tokens = criar_conta(client, email=EMAIL)
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == EMAIL))
        db.add(Device(device_id=PC, user_id=uid, name="pc", os="windows", hostname="pc"))
        db.commit()
    manager.register(PC, Agente())
    return tokens


def _primeiro_plano(token: str) -> int:
    return client.get(f"/api/v1/devices/{PC}/foreground", headers=_h(token)).status_code


def teardown_function() -> None:
    manager.unregister(PC)


def test_a_segunda_pergunta_nao_vai_ao_banco():
    tokens = _com_computador()
    assert _primeiro_plano(tokens["access_token"]) == 200

    emprestimos = []
    ouvir = lambda *_a: emprestimos.append(1)  # noqa: E731
    event.listen(engine, "checkout", ouvir)
    try:
        assert _primeiro_plano(tokens["access_token"]) == 200
    finally:
        event.remove(engine, "checkout", ouvir)
    assert emprestimos == []


def test_sair_do_aparelho_vale_na_hora():
    tokens = _com_computador()
    assert _primeiro_plano(tokens["access_token"]) == 200  # aquece a memória

    resp = client.post("/api/v1/auth/logout", headers=_h(tokens["access_token"]))
    assert resp.status_code == 204
    assert _primeiro_plano(tokens["access_token"]) == 401


def test_sair_dos_outros_aparelhos_vale_na_hora():
    _com_computador()
    outro = _entrar()
    meu = _entrar()
    assert _primeiro_plano(outro["access_token"]) == 200

    resp = client.post(
        "/api/v1/auth/sessions/revoke-others", headers=_h(meu["access_token"])
    )
    assert resp.status_code == 200
    assert _primeiro_plano(outro["access_token"]) == 401
    assert _primeiro_plano(resp.json()["access_token"]) == 200


def test_desparear_vale_na_hora():
    tokens = _com_computador()
    assert _primeiro_plano(tokens["access_token"]) == 200

    resp = client.delete(f"/api/v1/devices/{PC}", headers=_h(tokens["access_token"]))
    assert resp.status_code == 204
    assert _primeiro_plano(tokens["access_token"]) == 404


def test_computador_de_outra_conta_continua_404():
    _com_computador()
    alheio = criar_conta(client, email="alheio-vinculos@example.com")
    assert _primeiro_plano(alheio["access_token"]) == 404


def test_leitura_velha_nao_e_guardada_depois_de_uma_mudanca():
    """A leitura começou, o banco mudou no meio, e ela chega para guardar:
    não pode, ou guardaria a resposta de antes da mudança."""
    payload = {"sub": "1", "tk": "chave", "sid": "s"}
    antes = vinculos.geracao()
    with SessionLocal() as db:
        db.add(Device(device_id="pc-x", user_id=1, name="x", os="w", hostname="x"))
        db.commit()  # a mudança: sobe a geração
    vinculos.guardar_sessao(payload, antes)
    vinculos.guardar_dono("pc-x", None, antes)
    assert not vinculos.sessao_vale(payload)
    assert not vinculos.sabe(vinculos.dono("pc-x"))
