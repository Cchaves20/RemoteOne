"""Perfis de controle criados pelo usuário.

Os cinco de fábrica continuam no app (são atalhos de teclado, ou seja, código).
O que se guarda aqui é o que a pessoa montou: um nome, um ícone, uma lista de
programas para abrir e a quais computadores o perfil se aplica.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from conftest import criar_conta

client = TestClient(app)


def _auth(email: str) -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
    return headers, user_id


def _add_device(user_id: int, device_id: str) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name=device_id,
                os="windows",
                hostname=device_id,
            )
        )
        db.commit()


SPOTIFY = {"name": "Spotify", "path": r"C:\Users\eu\AppData\Roaming\Spotify.lnk"}
CHROME = {"name": "Google Chrome", "path": r"C:\Program Files\Chrome.lnk"}


def test_cria_lista_e_edita_um_perfil():
    headers, uid = _auth("perfil1@example.com")
    _add_device(uid, "dev-perf-1")

    criado = client.post(
        "/api/v1/profiles",
        json={
            "name": "Música",
            "icon": "music_note",
            "apps": [SPOTIFY, CHROME],
            "devices": ["dev-perf-1"],
        },
        headers=headers,
    )
    assert criado.status_code == 201
    pid = criado.json()["id"]
    # Sem posicionamento escolhido, `zone` volta nulo - o programa abre onde o
    # Windows quiser, que é o comportamento de sempre.
    assert criado.json()["apps"] == [
        {**SPOTIFY, "zone": None},
        {**CHROME, "zone": None},
    ]

    listados = client.get("/api/v1/profiles", headers=headers).json()
    assert [p["id"] for p in listados["profiles"]] == [pid]
    assert listados["order"] == []

    editado = client.put(
        f"/api/v1/profiles/{pid}",
        json={"name": "Só música", "icon": "movie", "apps": [SPOTIFY], "devices": []},
        headers=headers,
    )
    assert editado.status_code == 200
    # O identificador **não** muda ao editar: é ele que o telefone guardou como
    # "o perfil aberto da última vez".
    assert editado.json()["id"] == pid
    assert editado.json()["apps"] == [{**SPOTIFY, "zone": None}]


def test_o_programa_guarda_nome_e_caminho():
    """O caminho de um computador não existe no outro. O que sobrevive à troca
    de máquina é o nome, e é por ele que o agente procura quando o caminho
    falha - por isso os dois são guardados."""
    headers, _ = _auth("perfil2@example.com")
    resp = client.post(
        "/api/v1/profiles",
        json={"name": "Trabalho", "apps": [SPOTIFY]},
        headers=headers,
    )
    assert resp.status_code == 201
    assert resp.json()["apps"][0]["name"] == "Spotify"
    assert resp.json()["apps"][0]["path"].endswith("Spotify.lnk")


def test_perfil_sem_computador_vale_para_todos():
    headers, _ = _auth("perfil3@example.com")
    resp = client.post("/api/v1/profiles", json={"name": "Geral"}, headers=headers)
    assert resp.status_code == 201
    assert resp.json()["devices"] == []


def test_computador_de_outra_conta_e_recusado():
    """Aceitar em silêncio guardaria um identificador que nunca casaria com
    nada, e o perfil simplesmente não apareceria."""
    headers, _ = _auth("perfil4@example.com")
    _outro, outro_uid = _auth("perfil4-vizinho@example.com")
    _add_device(outro_uid, "dev-do-vizinho")
    resp = client.post(
        "/api/v1/profiles",
        json={"name": "Invasor", "devices": ["dev-do-vizinho"]},
        headers=headers,
    )
    assert resp.status_code == 404


def test_computador_removido_some_do_perfil_sem_apagar_o_perfil():
    """Despareou uma máquina: o perfil continua existindo, só deixa de valer
    para ela. Apagar a referência seria pior - repareando o mesmo computador, a
    pessoa teria de editar tudo de novo."""
    headers, uid = _auth("perfil5@example.com")
    _add_device(uid, "dev-perf-5")
    pid = client.post(
        "/api/v1/profiles",
        json={"name": "Casa", "devices": ["dev-perf-5"]},
        headers=headers,
    ).json()["id"]

    with SessionLocal() as db:
        db.delete(db.scalar(select(Device).where(Device.device_id == "dev-perf-5")))
        db.commit()

    listados = client.get("/api/v1/profiles", headers=headers).json()["profiles"]
    assert [p["id"] for p in listados] == [pid]
    assert listados[0]["devices"] == []


def test_ordem_guarda_a_fila_inteira():
    """A barra é uma só: dizer onde um perfil criado entra exige saber onde
    estão os de fábrica. Por isso a ordem carrega os dois tipos de id."""
    headers, _ = _auth("perfil6@example.com")
    pid = client.post("/api/v1/profiles", json={"name": "Meu"}, headers=headers).json()["id"]
    fila = ["video", pid, "sistema", "navegador"]
    assert (
        client.put("/api/v1/profiles/order", json={"ids": fila}, headers=headers).status_code
        == 204
    )
    assert client.get("/api/v1/profiles", headers=headers).json()["order"] == fila


def test_apagar_um_perfil_tira_ele_da_ordem():
    """Sem isso o identificador apagado ficaria na fila para sempre."""
    headers, _ = _auth("perfil7@example.com")
    pid = client.post("/api/v1/profiles", json={"name": "Some"}, headers=headers).json()["id"]
    client.put(
        "/api/v1/profiles/order", json={"ids": ["sistema", pid, "video"]}, headers=headers
    )
    assert client.delete(f"/api/v1/profiles/{pid}", headers=headers).status_code == 204
    depois = client.get("/api/v1/profiles", headers=headers).json()
    assert depois["profiles"] == []
    assert depois["order"] == ["sistema", "video"]


def test_reordenar_nao_cai_no_endpoint_de_edicao():
    """`/profiles/order` e `/profiles/{id}` são os dois um PUT sob o mesmo
    prefixo. Se a rota com parâmetro fosse declarada antes, uma reordenação
    viraria uma tentativa de editar o perfil chamado "order"."""
    headers, _ = _auth("perfil8@example.com")
    resp = client.put("/api/v1/profiles/order", json={"ids": ["video"]}, headers=headers)
    assert resp.status_code == 204, resp.text


def test_perfil_de_outra_conta_nao_e_visto_nem_editado():
    headers, _ = _auth("perfil9@example.com")
    pid = client.post("/api/v1/profiles", json={"name": "Meu"}, headers=headers).json()["id"]
    intruso, _ = _auth("perfil9-intruso@example.com")

    assert client.get("/api/v1/profiles", headers=intruso).json()["profiles"] == []
    assert (
        client.put(
            f"/api/v1/profiles/{pid}", json={"name": "Roubado"}, headers=intruso
        ).status_code
        == 404
    )
    assert client.delete(f"/api/v1/profiles/{pid}", headers=intruso).status_code == 404


def test_sem_token_nao_responde():
    assert client.get("/api/v1/profiles").status_code == 401
    assert client.post("/api/v1/profiles", json={"name": "x"}).status_code == 401


def test_nome_vazio_e_recusado():
    headers, _ = _auth("perfil10@example.com")
    assert (
        client.post("/api/v1/profiles", json={"name": ""}, headers=headers).status_code == 422
    )


def test_lista_de_programas_tem_teto():
    """Doze é mais do que cabe na barra sem virar rolagem."""
    headers, _ = _auth("perfil11@example.com")
    demais = [{"name": f"App {i}", "path": f"C:/{i}.lnk"} for i in range(13)]
    resp = client.post(
        "/api/v1/profiles", json={"name": "Demais", "apps": demais}, headers=headers
    )
    assert resp.status_code == 422


def test_health_anuncia_o_recurso():
    assert "control-profiles" in client.get("/health").json()["features"]


def test_o_perfil_guarda_onde_cada_janela_fica():
    """A zona sobrevive ao salvar e ao reler.

    Não há coluna nova no banco: os programas já eram guardados como JSON, e a
    zona entra junto. Num projeto sem Alembic, evitar uma migração é evitar um
    remendo à mão em `db.py`.
    """
    headers, _ = _auth("zona1@example.com")
    esquerda = {"cols": 2, "rows": 1, "col": 0, "row": 0, "colspan": 1, "rowspan": 1}
    direita = {"cols": 2, "rows": 1, "col": 1, "row": 0, "colspan": 1, "rowspan": 1}
    criado = client.post(
        "/api/v1/profiles",
        json={
            "name": "Trabalho",
            "icon": "work",
            "apps": [
                {"name": "Chrome", "path": "C:\\chrome.lnk", "zone": esquerda},
                {"name": "Terminal", "path": "C:\\wt.lnk", "zone": direita},
            ],
        },
        headers=headers,
    )
    assert criado.status_code == 201

    lidos = client.get("/api/v1/profiles", headers=headers).json()["profiles"]
    perfil = next(p for p in lidos if p["name"] == "Trabalho")
    assert perfil["apps"][0]["zone"] == esquerda
    assert perfil["apps"][1]["zone"] == direita


def test_perfil_recusa_zona_fora_da_grade():
    """Coluna 5 numa grade de 2 não é erro de digitação a corrigir em silêncio."""
    headers, _ = _auth("zona2@example.com")
    resp = client.post(
        "/api/v1/profiles",
        json={
            "name": "Ruim",
            "apps": [
                {
                    "name": "X",
                    "path": "C:\\x.lnk",
                    "zone": {"cols": 2, "rows": 1, "col": 5, "row": 0},
                }
            ],
        },
        headers=headers,
    )
    assert resp.status_code == 422
