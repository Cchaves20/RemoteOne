"""Planos: o que a versão grátis faz, o que a paga faz, e onde a regra mora.

A parte que mais importa aqui não é "o pago funciona" — é **o grátis funcionar
bem**. Um plano grátis que trava no primeiro minuto não é um plano, é um demo:
a pessoa desinstala e não conta para ninguém. Metade destes testes existe para
provar que o caminho principal continua aberto sem pagar nada.
"""

from datetime import UTC, datetime, timedelta

import pytest
from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import plano
from app.db import SessionLocal
from app.main import app
from app.models import User

client = TestClient(app)


def _cabecalho(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _rebaixar(email: str) -> None:
    """Faz a conta cair para o grátis, como o tempo faria.

    Mexe na data e **não** no rótulo: é assim que acontece de verdade quando o
    teste de 30 dias acaba, e testar pelo rótulo deixaria passar exatamente o
    defeito de o servidor olhar só para ele.
    """
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        user.plano_ate = datetime.now(UTC) - timedelta(seconds=1)
        db.commit()


def _conta_gratis(email: str) -> str:
    token = criar_conta(client, email)["access_token"]
    _rebaixar(email)
    return token


def _parear(token: str, device_id: str) -> int:
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": device_id,
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
                "secret": "",
            }
        )
        ws.receive_json()  # welcome
        intro = ws.receive_json()
        return client.post(
            "/api/v1/pairing/claim",
            json={"code": intro["code"]},
            headers=_cabecalho(token),
        ).status_code


# --- As regras, sem servidor -------------------------------------------------


def test_a_data_manda_sobre_o_rotulo():
    """Uma assinatura vencida vale tanto quanto nenhuma.

    Guardar só o rótulo obrigaria uma tarefa noturna a rebaixar contas — e uma
    tarefa que não roda deixa gente usando o plano pago sem ninguém perceber.
    """
    ontem = datetime.now(UTC) - timedelta(days=1)
    amanha = datetime.now(UTC) + timedelta(days=1)

    assert plano.plano_efetivo("pago", amanha) == plano.Plano.PAGO
    assert plano.plano_efetivo("pago", ontem) == plano.Plano.GRATIS
    # Sem prazo é sem prazo: é como se liga uma conta à mão.
    assert plano.plano_efetivo("pago", None) == plano.Plano.PAGO
    assert plano.plano_efetivo("gratis", amanha) == plano.Plano.GRATIS


def test_o_limite_conta_antes_de_criar():
    """Com `>`, um limite de um deixaria criar dois."""
    assert plano.cabe(0, 1)
    assert not plano.cabe(1, 1)
    assert plano.cabe(99, None)


def test_o_plano_pago_alcanca_tudo_e_o_gratis_nada_da_lista():
    for recurso in plano.Recurso:
        assert plano.permite(plano.Plano.PAGO, recurso)
        assert not plano.permite(plano.Plano.GRATIS, recurso)
        # E cada um sabe se explicar: um "403" seco faria o app inventar uma
        # razão, e um dia a razão inventada estaria errada.
        assert plano.NOMES[recurso] in plano.motivo(recurso)


# --- A conta nova ------------------------------------------------------------


def test_toda_conta_nasce_com_trinta_dias_do_plano_pago():
    token = criar_conta(client, "nova@example.com")["access_token"]
    eu = client.get("/api/v1/auth/me", headers=_cabecalho(token)).json()

    assert eu["plano"] == "pago"
    # O SQLite devolve datetime sem fuso; o `.replace` é o que impede o
    # `can't subtract offset-naive and offset-aware` — e é o mesmo cuidado que
    # `plano._aware` tem no código de verdade.
    prazo = datetime.fromisoformat(eu["plano_ate"])
    if prazo.tzinfo is None:
        prazo = prazo.replace(tzinfo=UTC)
    faltam = prazo - datetime.now(UTC)
    assert timedelta(days=29) < faltam <= timedelta(days=30)


def test_o_me_devolve_o_plano_efetivo_e_nao_o_rotulo_guardado():
    """Uma tela que promete o que o servidor nega é pior que uma que não promete.

    A conta continua com `plano="pago"` no banco — o que mudou foi a data. Se o
    `/me` copiasse o rótulo, o app ofereceria recursos que a chamada seguinte
    recusaria.
    """
    token = _conta_gratis("vencida@example.com")
    eu = client.get("/api/v1/auth/me", headers=_cabecalho(token)).json()
    assert eu["plano"] == "gratis"

    with SessionLocal() as db:
        guardado = db.scalar(select(User.plano).where(User.email == "vencida@example.com"))
    assert guardado == "pago", "o teste precisa exercitar o caso do rótulo desatualizado"


# --- O que o grátis **pode** -------------------------------------------------


def test_o_gratis_pareia_um_computador_e_o_usa():
    """O caminho principal do produto, sem pagar nada.

    Se este teste falhar, não há produto grátis — há um demo.
    """
    token = _conta_gratis("gratis-basico@example.com")

    assert _parear(token, "dev-gratis-1") == 201

    listados = client.get("/api/v1/devices", headers=_cabecalho(token)).json()
    assert len(listados) == 1

    # Mouse e teclado continuam abertos.
    resposta = client.post(
        "/api/v1/devices/dev-gratis-1/input",
        json={"action": {"type": "mouse_move", "dx": 1.0, "dy": 1.0}},
        headers=_cabecalho(token),
    )
    assert resposta.status_code != 402, resposta.text


def test_o_gratis_cria_uma_automacao_sem_horario():
    token = _conta_gratis("gratis-automacao@example.com")
    _parear(token, "dev-gratis-2")

    resposta = client.post(
        "/api/v1/automations",
        json={"name": "Trabalho", "icon": "work", "steps": [{"kind": "save_all"}]},
        headers=_cabecalho(token),
    )
    assert resposta.status_code == 201, resposta.text


# --- O que o grátis **não** pode ---------------------------------------------


def test_o_segundo_computador_pede_o_plano():
    token = _conta_gratis("gratis-dois@example.com")
    assert _parear(token, "dev-gratis-3") == 201

    assert _parear(token, "dev-gratis-4") == 402


def test_a_segunda_automacao_pede_o_plano():
    token = _conta_gratis("gratis-duas@example.com")
    _parear(token, "dev-gratis-5")
    corpo = {"name": "A", "icon": "work", "steps": [{"kind": "save_all"}]}

    assert client.post("/api/v1/automations", json=corpo, headers=_cabecalho(token)).status_code == 201
    segunda = client.post("/api/v1/automations", json=corpo, headers=_cabecalho(token))

    assert segunda.status_code == 402
    assert "grátis" in segunda.json()["detail"]


def test_o_horario_marcado_e_do_plano_pago():
    token = _conta_gratis("gratis-agenda@example.com")
    _parear(token, "dev-gratis-6")

    resposta = client.post(
        "/api/v1/automations",
        json={
            "name": "Fim do dia",
            "icon": "work",
            "steps": [{"kind": "save_all"}],
            "device_id": "dev-gratis-6",
            "schedule_time": "18:00",
            "schedule_days": [1, 2, 3, 4, 5],
        },
        headers=_cabecalho(token),
    )
    assert resposta.status_code == 402, resposta.text
    assert "horário marcado" in resposta.json()["detail"]


def test_editar_para_agendar_tambem_e_recusado():
    """A volta pela porta dos fundos.

    Sem a trava no `PUT`, bastaria criar sem horário e editar em seguida — e
    uma regra que só vale na criação não é uma regra.
    """
    token = _conta_gratis("gratis-volta@example.com")
    _parear(token, "dev-gratis-7")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "A", "icon": "work", "steps": [{"kind": "save_all"}]},
        headers=_cabecalho(token),
    ).json()

    resposta = client.put(
        f"/api/v1/automations/{criada['id']}",
        json={
            "name": "A",
            "icon": "work",
            "steps": [{"kind": "save_all"}],
            "device_id": "dev-gratis-7",
            "schedule_time": "18:00",
            "schedule_days": [1],
        },
        headers=_cabecalho(token),
    )
    assert resposta.status_code == 402, resposta.text


@pytest.mark.parametrize(
    "metodo,rota,corpo",
    [
        ("get", "/api/v1/devices/dev-pago/files", None),
        ("post", "/api/v1/devices/dev-pago/audio", {"enabled": True}),
        ("post", "/api/v1/devices/dev-pago/presentation", {"on": True}),
        ("post", "/api/v1/devices/dev-pago/monitors", {"monitor": 1}),
        ("post", "/api/v1/profiles", {"name": "P", "icon": "work", "apps": []}),
    ],
)
def test_os_recursos_pagos_recusam_com_402_e_dizem_qual(metodo, rota, corpo):
    """402 e não 403, e a diferença não é preciosismo de padrão.

    `403` é "você não pode"; `402` é "você poderia, pagando". É o que permite ao
    app distinguir *isto não é seu* de *isto é do plano pago* sem ler texto — e
    um 403 faria o aplicativo mostrar "acesso negado" a quem só precisava saber
    que existe um plano.
    """
    token = _conta_gratis(f"gratis-{rota.replace('/', '-')}@example.com")
    _parear(token, "dev-pago")

    # `client.request` e não `client.get(json=...)`: o httpx recusa corpo
    # no GET pelo nome do argumento, e a recusa vira erro de teste em vez de
    # resultado.
    resposta = client.request(metodo, rota, json=corpo, headers=_cabecalho(token))

    assert resposta.status_code == 402, f"{rota}: {resposta.status_code} {resposta.text}"
    assert "pago" in resposta.json()["detail"]


def test_computador_de_outra_pessoa_da_404_e_nao_uma_oferta():
    """A ordem das checagens é uma decisão de privacidade.

    Responder "isto é do plano pago" sobre o computador de outra pessoa
    confirmaria que aquele identificador existe. Quem não é dono recebe 404, e
    404 não conta nada a ninguém.
    """
    dono = _conta_gratis("dono-do-pc@example.com")
    _parear(dono, "dev-do-dono")
    estranho = _conta_gratis("estranho@example.com")

    resposta = client.get(
        "/api/v1/devices/dev-do-dono/files", headers=_cabecalho(estranho)
    )
    assert resposta.status_code == 404, resposta.text


def test_o_plano_pago_passa_por_todas_as_travas():
    """O contrapeso: cortar do grátis só é conserto se o pago continuar inteiro."""
    token = criar_conta(client, "pagante@example.com")["access_token"]
    _parear(token, "dev-pagante-1")
    assert _parear(token, "dev-pagante-2") == 201

    perfil = client.post(
        "/api/v1/profiles",
        json={"name": "P", "icon": "work", "apps": []},
        headers=_cabecalho(token),
    )
    assert perfil.status_code == 201, perfil.text

    agendada = client.post(
        "/api/v1/automations",
        json={
            "name": "Fim do dia",
            "icon": "work",
            "steps": [{"kind": "save_all"}],
            "device_id": "dev-pagante-1",
            "schedule_time": "18:00",
            "schedule_days": [1],
        },
        headers=_cabecalho(token),
    )
    assert agendada.status_code == 201, agendada.text

    # Arquivos: o computador não está de pé, então o que importa é **não** ser
    # 402. Um 503/504 aqui é a resposta certa para "o agente não respondeu".
    arquivos = client.get(
        "/api/v1/devices/dev-pagante-1/files", headers=_cabecalho(token)
    )
    assert arquivos.status_code != 402, arquivos.text


# --- A ferramenta de operação ------------------------------------------------


def test_ligar_e_desligar_o_plano_a_mao():
    """O que se usa antes de existir cobrança automática — e depois também.

    Dar acesso a um amigo, estender o prazo de quem teve um problema, devolver
    o plano a quem pagou e cujo aviso não chegou.
    """
    from app import conta

    criar_conta(client, "a-mao@example.com")
    _rebaixar("a-mao@example.com")

    with SessionLocal() as db:
        assert cobranca_plano("a-mao@example.com") == "gratis"

    conta.main.__globals__["sys"].argv = ["x", "pago", "a-mao@example.com", "--dias", "10"]
    conta.main()
    assert cobranca_plano("a-mao@example.com") == "pago"

    conta.main.__globals__["sys"].argv = ["x", "gratis", "a-mao@example.com"]
    conta.main()
    assert cobranca_plano("a-mao@example.com") == "gratis"


def test_renovar_nao_encurta_nem_nasce_vencido():
    """A conta que parece detalhe e morde nos dois sentidos.

    Somar ao prazo atual daria a quem voltou depois de meses um prazo que já
    nasce no passado. Somar sempre a hoje tiraria de quem renova antes do fim o
    tempo que ainda tinha.
    """
    from app import conta

    criar_conta(client, "renova@example.com")
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == "renova@example.com"))
        user.plano_ate = datetime.now(UTC) - timedelta(days=200)
        db.commit()

    conta.main.__globals__["sys"].argv = ["x", "pago", "renova@example.com", "--dias", "5"]
    conta.main()

    with SessionLocal() as db:
        prazo = db.scalar(select(User.plano_ate).where(User.email == "renova@example.com"))
    if prazo.tzinfo is None:
        prazo = prazo.replace(tzinfo=UTC)
    assert prazo > datetime.now(UTC), "o prazo renovado nasceu vencido"


def cobranca_plano(email: str) -> str:
    from app import cobranca

    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        return str(cobranca.plano_de(user))
