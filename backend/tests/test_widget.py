"""O widget do celular: um computador e três botões.

O que importa proteger: a escolha de uma conta nunca aponta para coisa de
outra; o que sumiu (computador desparelhado, automação apagada) não vira botão
quebrado; e a conta que nascer depois não herda o widget de ninguém.
"""

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User, WidgetConfig

client = TestClient(app)


def _auth(email: str) -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _add_device(user_id: int, device_id: str, nome: str | None = None) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name=nome or device_id,
                os="windows",
                hostname=device_id,
            )
        )
        db.commit()


def _automacao(headers: dict, nome: str) -> str:
    resp = client.post(
        "/api/v1/automations",
        json={"name": nome, "steps": [{"kind": "media", "action": "mute"}]},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def test_sem_configurar_vem_o_padrao_da_tela():
    headers, uid = _auth("widget1@example.com")
    _add_device(uid, "dev-w1", "PC da sala")
    cinema = _automacao(headers, "Cinema")

    w = client.get("/api/v1/widget", headers=headers).json()

    assert w["device_id"] == "dev-w1"
    assert w["device_name"] == "PC da sala"
    assert [b["tipo"] for b in w["botoes"]] == ["apresentacao", "tocar_pausar", "automacao"]
    assert w["botoes"][2]["automacao_id"] == cinema
    assert w["botoes"][2]["automacao_nome"] == "Cinema"


def test_conta_sem_nada_ainda_responde():
    headers, _ = _auth("widget2@example.com")
    w = client.get("/api/v1/widget", headers=headers).json()
    assert w["device_id"] is None
    assert w["online"] is False
    # Sem automação, o terceiro botão do padrão não aparece.
    assert [b["tipo"] for b in w["botoes"]] == ["apresentacao", "tocar_pausar"]


def test_salva_e_le_a_escolha():
    headers, uid = _auth("widget3@example.com")
    _add_device(uid, "dev-w3a")
    _add_device(uid, "dev-w3b", "Notebook")
    rotina = _automacao(headers, "Fim do expediente")

    resp = client.put(
        "/api/v1/widget",
        json={
            "device_id": "dev-w3b",
            "botoes": [
                {"tipo": "suspender"},
                {"tipo": "automacao", "automacao_id": rotina},
                {"tipo": "volume_mais"},
            ],
            "atalhos": [rotina],
        },
        headers=headers,
    )
    assert resp.status_code == 200, resp.text

    w = client.get("/api/v1/widget", headers=headers).json()
    assert w["device_name"] == "Notebook"
    assert [b["tipo"] for b in w["botoes"]] == ["suspender", "automacao", "volume_mais"]
    assert w["botoes"][1]["automacao_nome"] == "Fim do expediente"
    assert w["atalhos"] == [rotina]


def test_mostra_se_o_computador_esta_online():
    headers, uid = _auth("widget4@example.com")
    _add_device(uid, "dev-w4")
    manager.register("dev-w4", object())
    try:
        assert client.get("/api/v1/widget", headers=headers).json()["online"] is True
    finally:
        manager.unregister("dev-w4")


def test_computador_de_outra_conta_e_recusado():
    _, dono = _auth("widget5@example.com")
    _add_device(dono, "dev-w5")
    intruso, _ = _auth("widget6@example.com")
    resp = client.put("/api/v1/widget", json={"device_id": "dev-w5"}, headers=intruso)
    assert resp.status_code == 404


def test_automacao_de_outra_conta_e_recusada():
    dono, _ = _auth("widget7@example.com")
    alheia = _automacao(dono, "Alheia")
    intruso, _ = _auth("widget8@example.com")
    for corpo in (
        {"botoes": [{"tipo": "automacao", "automacao_id": alheia}]},
        {"atalhos": [alheia]},
    ):
        resp = client.put("/api/v1/widget", json=corpo, headers=intruso)
        assert resp.status_code == 404, corpo


def test_botao_de_automacao_sem_automacao_e_recusado():
    headers, _ = _auth("widget9@example.com")
    resp = client.put(
        "/api/v1/widget", json={"botoes": [{"tipo": "automacao"}]}, headers=headers
    )
    assert resp.status_code == 422


def test_mais_de_tres_botoes_e_recusado():
    headers, _ = _auth("widget10@example.com")
    resp = client.put(
        "/api/v1/widget",
        json={"botoes": [{"tipo": "suspender"}] * 4},
        headers=headers,
    )
    assert resp.status_code == 422


def test_o_que_sumiu_nao_vira_botao_quebrado():
    """Automação apagada sai do widget; computador desparelhado vira o padrão."""
    headers, uid = _auth("widget11@example.com")
    _add_device(uid, "dev-w11a", "Primeiro")
    _add_device(uid, "dev-w11b", "Segundo")
    rotina = _automacao(headers, "Vai sumir")
    client.put(
        "/api/v1/widget",
        json={
            "device_id": "dev-w11b",
            "botoes": [{"tipo": "automacao", "automacao_id": rotina}],
            "atalhos": [rotina],
        },
        headers=headers,
    )

    assert client.delete(f"/api/v1/automations/{rotina}", headers=headers).status_code == 204
    assert client.delete("/api/v1/devices/dev-w11b", headers=headers).status_code == 204

    w = client.get("/api/v1/widget", headers=headers).json()
    assert w["botoes"] == []
    assert w["atalhos"] == []
    assert w["device_name"] == "Primeiro"


def test_excluir_a_conta_leva_o_widget_junto():
    headers, uid = _auth("widget12@example.com")
    client.put("/api/v1/widget", json={"botoes": [{"tipo": "silenciar"}]}, headers=headers)
    with SessionLocal() as db:
        assert db.get(WidgetConfig, uid) is not None

    resp = client.request(
        "DELETE",
        "/api/v1/auth/me",
        json={"password": "senhaSegura123!"},
        headers=headers,
    )
    assert resp.status_code in (200, 204), resp.text
    with SessionLocal() as db:
        assert db.get(WidgetConfig, uid) is None


def test_sem_login_401():
    assert client.get("/api/v1/widget").status_code == 401
