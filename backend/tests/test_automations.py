"""Automações: a sequência de passos que um toque executa.

Dois exemplos guiam a suíte inteira, porque foram eles que motivaram o recurso:

- **Modo reunião** — abrir o Teams à esquerda, o OneNote à direita, silenciar,
  brilho em 80%.
- **Fim do expediente** — fechar o Slack, fechar o Outlook, brilho no mínimo,
  suspender.

O que os testes protegem não é "o endpoint responde 200": é que a sequência
chega ao computador **inteira, na ordem, numa mensagem só**, e que o relatório
volta passo a passo. Cada uma dessas três coisas, se quebrar, quebra em
silêncio.
"""

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.rpc import pending

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


ESQUERDA = {"cols": 2, "rows": 1, "col": 0, "row": 0, "colspan": 1, "rowspan": 1}
DIREITA = {"cols": 2, "rows": 1, "col": 1, "row": 0, "colspan": 1, "rowspan": 1}

REUNIAO = [
    {"kind": "launch", "id": "Teams.lnk", "zone": ESQUERDA, "wait_ms": 1500},
    {"kind": "launch", "id": "OneNote.lnk", "zone": DIREITA, "wait_ms": 1500},
    {"kind": "media", "action": "mute"},
    {"kind": "brightness", "level": 80},
]

FIM_DO_EXPEDIENTE = [
    {"kind": "close", "name": "slack"},
    {"kind": "close", "name": "outlook"},
    {"kind": "brightness", "level": 0},
    {"kind": "power", "action": "suspend"},
]


class AutomationAgent:
    """Agente que responde a um `run_automation` com o relatório combinado."""

    def __init__(self, results: list[dict] | None = None):
        self.results = results
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "run_automation" and self.results is not None:
            pending.resolve(message["request_id"], {"results": self.results})

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- guardar ------------------------------------------------------------------


def test_cria_lista_e_edita_uma_automacao():
    headers, uid = _auth("auto1@example.com")
    _add_device(uid, "dev-auto-1")

    criada = client.post(
        "/api/v1/automations",
        json={
            "name": "Modo reunião",
            "icon": "groups",
            "steps": REUNIAO,
            "device_id": "dev-auto-1",
        },
        headers=headers,
    )
    assert criada.status_code == 201
    corpo = criada.json()
    assert corpo["id"].startswith("u-")
    assert corpo["name"] == "Modo reunião"
    assert [p["kind"] for p in corpo["steps"]] == [
        "launch",
        "launch",
        "media",
        "brightness",
    ]

    listadas = client.get("/api/v1/automations", headers=headers).json()["automations"]
    assert len(listadas) == 1
    assert listadas[0]["id"] == corpo["id"]

    editada = client.put(
        f"/api/v1/automations/{corpo['id']}",
        json={
            "name": "Fim do expediente",
            "icon": "bedtime",
            "steps": FIM_DO_EXPEDIENTE,
            "device_id": "dev-auto-1",
        },
        headers=headers,
    )
    assert editada.status_code == 200
    # O identificador não muda ao editar: ele é o que o botão do app guarda.
    assert editada.json()["id"] == corpo["id"]
    assert [p["kind"] for p in editada.json()["steps"]] == [
        "close",
        "close",
        "brightness",
        "power",
    ]


def test_a_ordem_dos_passos_sobrevive_ao_banco():
    """Numa automação a ordem *é* o recurso.

    Abrir o Teams depois de silenciar ainda silencia; fechar o Outlook depois
    de suspender não fecha coisa nenhuma. Uma lista reordenada na volta seria
    um defeito que só aparece no computador da pessoa.
    """
    headers, _ = _auth("auto2@example.com")
    ordem = ("mute", "volume_up", "play_pause")
    passos = [{"kind": "media", "action": a} for a in ordem]
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Som", "steps": passos},
        headers=headers,
    ).json()

    voltou = client.get("/api/v1/automations", headers=headers).json()["automations"][0]
    assert [p["action"] for p in voltou["steps"]] == list(ordem)
    assert voltou["id"] == criada["id"]


def test_passo_guardado_nao_leva_campos_de_outro_tipo():
    """`level: null` num passo de mídia é lixo que o agente recusaria.

    O `StepIn` tem um campo por tipo, então um passo `media` nasce com `id`,
    `zone`, `level` e `delta` nulos. Gravados assim, o `serde` do Rust rejeita a
    mensagem inteira - e o passo falharia sem motivo aparente.
    """
    headers, uid = _auth("auto3@example.com")
    _add_device(uid, "dev-auto-3")
    criada = client.post(
        "/api/v1/automations",
        json={
            "name": "Silêncio",
            "steps": [{"kind": "media", "action": "mute"}],
            "device_id": "dev-auto-3",
        },
        headers=headers,
    ).json()
    assert criada["steps"] == [{"kind": "media", "action": "mute"}]

    # E o que interessa de verdade: o que sai daqui para o computador. Conferir
    # só a resposta HTTP deixaria passar uma limpeza feita na saída e esquecida
    # na gravação — que é justamente o caminho que chega ao agente.
    agent = AutomationAgent([{"index": 0, "ok": True}])
    manager.register("dev-auto-3", agent)
    try:
        client.post(f"/api/v1/automations/{criada['id']}/run", headers=headers)
    finally:
        manager.unregister("dev-auto-3")
    assert agent.of_type("run_automation")[0]["steps"] == [
        {"kind": "media", "action": "mute"}
    ]


def test_recusa_passo_sem_o_campo_obrigatorio():
    """Falha no telefone, e não no computador.

    Um `launch` sem caminho chegaria à máquina e falharia lá — longe de quem
    montou a automação, e com uma mensagem sobre um programa vazio em vez de
    "faltou escolher o programa".
    """
    headers, _ = _auth("auto4@example.com")
    for passo in (
        {"kind": "launch"},
        {"kind": "close"},
        {"kind": "media"},
        {"kind": "power"},
        {"kind": "brightness"},  # nem level nem delta
        {"kind": "brightness", "level": 50, "delta": 10},  # os dois juntos
        {"kind": "voar", "action": "alto"},  # tipo que não existe
        # `sleep` é o nome em inglês corrente; o agente chama de `suspend`. Sem
        # esta checagem o passo só falharia no computador, no fim da sequência.
        {"kind": "power", "action": "sleep"},
        {"kind": "media", "action": "pause"},
    ):
        resp = client.post(
            "/api/v1/automations",
            json={"name": "Ruim", "steps": [passo]},
            headers=headers,
        )
        assert resp.status_code == 422, passo


def test_recusa_sequencia_longa_demais():
    """Vinte e cinco passos é mensagem adulterada, não automação.

    O teto é o mesmo do agente. Existe aqui para o computador nunca receber uma
    sequência que ele vai cortar no meio sem avisar.
    """
    headers, _ = _auth("auto5@example.com")
    passos = [{"kind": "media", "action": "mute"} for _ in range(25)]
    resp = client.post(
        "/api/v1/automations", json={"name": "Mil", "steps": passos}, headers=headers
    )
    assert resp.status_code == 422


def test_recusa_computador_de_outra_conta():
    _, dono = _auth("auto6@example.com")
    _add_device(dono, "dev-auto-alheio")
    intruso, _ = _auth("auto7@example.com")
    resp = client.post(
        "/api/v1/automations",
        json={
            "name": "Xereta",
            "steps": [{"kind": "power", "action": "suspend"}],
            "device_id": "dev-auto-alheio",
        },
        headers=intruso,
    )
    assert resp.status_code == 404


def test_automacao_de_outra_conta_nem_existe():
    """Mesmo 404 para "não existe" e "é de outra conta"."""
    dono, _ = _auth("auto8@example.com")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Minha", "steps": [{"kind": "media", "action": "mute"}]},
        headers=dono,
    ).json()
    intruso, _ = _auth("auto9@example.com")

    alvo = f"/api/v1/automations/{criada['id']}"
    assert client.put(
        alvo, json={"name": "Sua", "steps": []}, headers=intruso
    ).status_code == 404
    assert client.delete(alvo, headers=intruso).status_code == 404
    assert client.post(f"{alvo}/run", headers=intruso).status_code == 404
    # E continua lá, intacta, para o dono.
    assert len(client.get("/api/v1/automations", headers=dono).json()["automations"]) == 1


def test_apaga_uma_automacao():
    headers, _ = _auth("auto10@example.com")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Sai", "steps": [{"kind": "media", "action": "mute"}]},
        headers=headers,
    ).json()
    assert client.delete(
        f"/api/v1/automations/{criada['id']}", headers=headers
    ).status_code == 204
    assert client.get("/api/v1/automations", headers=headers).json()["automations"] == []


def test_limite_de_automacoes_por_conta():
    from app.automations import MAX_AUTOMATIONS

    headers, _ = _auth("auto11@example.com")
    passo = [{"kind": "media", "action": "mute"}]
    for i in range(MAX_AUTOMATIONS):
        assert client.post(
            "/api/v1/automations",
            json={"name": f"A{i}", "steps": passo},
            headers=headers,
        ).status_code == 201
    excedente = client.post(
        "/api/v1/automations", json={"name": "demais", "steps": passo}, headers=headers
    )
    assert excedente.status_code == 409


# --- executar -----------------------------------------------------------------


def test_rodar_manda_a_sequencia_inteira_numa_mensagem_so():
    """Uma mensagem, não uma por passo.

    É o que faz a automação sobreviver ao iOS suspender o aplicativo logo depois
    do toque: bastaria a pessoa bloquear a tela para uma sequência conduzida
    pelo telefone parar no meio — com o Teams aberto, o som ainda alto e o
    brilho como estava.
    """
    headers, uid = _auth("run1@example.com")
    _add_device(uid, "dev-run-1")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Modo reunião", "steps": REUNIAO, "device_id": "dev-run-1"},
        headers=headers,
    ).json()

    agent = AutomationAgent([{"index": i, "ok": True} for i in range(4)])
    manager.register("dev-run-1", agent)
    try:
        resp = client.post(
            f"/api/v1/automations/{criada['id']}/run", headers=headers
        )
    finally:
        manager.unregister("dev-run-1")

    assert resp.status_code == 200
    pedidos = agent.of_type("run_automation")
    assert len(pedidos) == 1
    # Os passos atravessam intactos: os caminhos, as zonas e as pausas.
    assert pedidos[0]["steps"] == REUNIAO


def test_rodar_devolve_o_resultado_de_cada_passo():
    """Uma falha no meio não apaga o que veio depois.

    Quem pediu "fim do expediente" quer o expediente encerrado, não uma
    verificação de integridade: se o Slack não estava aberto, o brilho ainda
    baixa e a máquina ainda suspende. Mas o app precisa poder dizer *qual*
    passo falhou — daí o índice em vez do nome, já que dois passos podem ser
    idênticos.
    """
    headers, uid = _auth("run2@example.com")
    _add_device(uid, "dev-run-2")
    criada = client.post(
        "/api/v1/automations",
        json={
            "name": "Fim do expediente",
            "steps": FIM_DO_EXPEDIENTE,
            "device_id": "dev-run-2",
        },
        headers=headers,
    ).json()

    relatorio = [
        {"index": 0, "ok": False, "error": "o Slack não estava aberto"},
        {"index": 1, "ok": True, "error": None},
        {"index": 2, "ok": True, "error": None},
        {"index": 3, "ok": True, "error": None},
    ]
    agent = AutomationAgent(relatorio)
    manager.register("dev-run-2", agent)
    try:
        resp = client.post(f"/api/v1/automations/{criada['id']}/run", headers=headers)
    finally:
        manager.unregister("dev-run-2")

    assert resp.status_code == 200
    assert resp.json() == {"results": relatorio}


def test_aviso_sobe_junto_com_o_sucesso():
    """`ok=True` com motivo: a janela abriu, mas não foi para o lugar pedido.

    Não é falha, e esconder não ajudaria — a pessoa vê o Teams no meio da tela
    e precisa saber que isso foi o esperado dado o que aconteceu.
    """
    headers, uid = _auth("run3@example.com")
    _add_device(uid, "dev-run-3")
    criada = client.post(
        "/api/v1/automations",
        json={
            "name": "Reunião",
            "steps": [{"kind": "launch", "id": "Teams.lnk", "zone": ESQUERDA}],
            "device_id": "dev-run-3",
        },
        headers=headers,
    ).json()

    agent = AutomationAgent(
        [{"index": 0, "ok": True, "error": "não achei a janela para posicionar"}]
    )
    manager.register("dev-run-3", agent)
    try:
        resp = client.post(f"/api/v1/automations/{criada['id']}/run", headers=headers)
    finally:
        manager.unregister("dev-run-3")

    passo = resp.json()["results"][0]
    assert passo["ok"] is True
    assert passo["error"] == "não achei a janela para posicionar"


def test_rodar_escolhe_o_computador_na_hora_quando_a_automacao_nao_fixou():
    """Duas máquinas, a mesma rotina: fixar obrigaria a criar duas automações."""
    headers, uid = _auth("run4@example.com")
    _add_device(uid, "dev-run-4a")
    _add_device(uid, "dev-run-4b")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Solta", "steps": [{"kind": "media", "action": "mute"}]},
        headers=headers,
    ).json()

    # Sem dizer onde: não há como adivinhar, e adivinhar seria pior.
    sem_alvo = client.post(f"/api/v1/automations/{criada['id']}/run", headers=headers)
    assert sem_alvo.status_code == 400

    agent = AutomationAgent([{"index": 0, "ok": True}])
    manager.register("dev-run-4b", agent)
    try:
        resp = client.post(
            f"/api/v1/automations/{criada['id']}/run?device_id=dev-run-4b",
            headers=headers,
        )
    finally:
        manager.unregister("dev-run-4b")
    assert resp.status_code == 200
    assert len(agent.of_type("run_automation")) == 1


def test_o_computador_fixado_vence_o_parametro():
    """Quem fixou a máquina fixou por um motivo.

    Uma automação que termina suspendendo o computador não pode ser desviada
    para outro por um parâmetro na URL.
    """
    headers, uid = _auth("run5@example.com")
    _add_device(uid, "dev-run-5a")
    _add_device(uid, "dev-run-5b")
    criada = client.post(
        "/api/v1/automations",
        json={
            "name": "Presa",
            "steps": [{"kind": "power", "action": "suspend"}],
            "device_id": "dev-run-5a",
        },
        headers=headers,
    ).json()

    fixado = AutomationAgent([{"index": 0, "ok": True}])
    outro = AutomationAgent([{"index": 0, "ok": True}])
    manager.register("dev-run-5a", fixado)
    manager.register("dev-run-5b", outro)
    try:
        resp = client.post(
            f"/api/v1/automations/{criada['id']}/run?device_id=dev-run-5b",
            headers=headers,
        )
    finally:
        manager.unregister("dev-run-5a")
        manager.unregister("dev-run-5b")
    assert resp.status_code == 200
    assert len(fixado.of_type("run_automation")) == 1
    assert outro.sent == []


def test_rodar_com_agente_offline_503():
    headers, uid = _auth("run6@example.com")
    _add_device(uid, "dev-run-6")
    criada = client.post(
        "/api/v1/automations",
        json={
            "name": "Offline",
            "steps": [{"kind": "media", "action": "mute"}],
            "device_id": "dev-run-6",
        },
        headers=headers,
    ).json()
    resp = client.post(f"/api/v1/automations/{criada['id']}/run", headers=headers)
    assert resp.status_code == 503


def test_rodar_automacao_vazia_409():
    """Lista vazia de volta é indistinguível de "rodou tudo e deu certo"."""
    headers, uid = _auth("run7@example.com")
    _add_device(uid, "dev-run-7")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Nada", "steps": [], "device_id": "dev-run-7"},
        headers=headers,
    ).json()
    agent = AutomationAgent([])
    manager.register("dev-run-7", agent)
    try:
        resp = client.post(f"/api/v1/automations/{criada['id']}/run", headers=headers)
    finally:
        manager.unregister("dev-run-7")
    assert resp.status_code == 409
    # E o computador não foi incomodado à toa.
    assert agent.sent == []


def test_rodar_em_computador_de_outra_conta_404():
    headers, uid = _auth("run8@example.com")
    _, outro_dono = _auth("run9@example.com")
    _add_device(outro_dono, "dev-run-alheio")
    criada = client.post(
        "/api/v1/automations",
        json={"name": "Solta", "steps": [{"kind": "media", "action": "mute"}]},
        headers=headers,
    ).json()
    resp = client.post(
        f"/api/v1/automations/{criada['id']}/run?device_id=dev-run-alheio",
        headers=headers,
    )
    assert resp.status_code == 404


def test_automacoes_exigem_autenticacao():
    assert client.get("/api/v1/automations").status_code == 401
    assert client.post("/api/v1/automations", json={"name": "x"}).status_code == 401


def test_fechar_tudo_nao_precisa_de_campo_nenhum():
    """O passo que pergunta ao computador o que está aberto.

    Sem campo de propósito: uma lista de programas escrita à mão envelheceria -
    o que está aberto hoje não é o que estava ontem, e "fim do expediente"
    precisa acertar nos dois dias.

    O teste existe porque o validador recusa passo sem o campo obrigatório, e
    `close_all` é o único que **não tem** obrigatório nenhum. Um `.get(kind)` sem
    o padrão certo o recusaria, e a automação inteira voltaria 422 sem dizer
    qual passo.
    """
    headers, _ = _auth("fecha1@example.com")
    resp = client.post(
        "/api/v1/automations",
        json={
            "name": "Fim do expediente",
            "steps": [{"kind": "close_all"}, {"kind": "power", "action": "suspend"}],
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    passos = resp.json()["steps"]
    assert passos[0] == {"kind": "close_all"}


def test_salvar_tudo_atravessa_sem_campo_nenhum():
    """O par do `close_all`, e o que torna o agendamento seguro.

    Mesmo caminho pelo validador: é o segundo passo sem campo obrigatório, e um
    `.get(kind)` sem o padrão certo o recusaria — devolvendo 422 na automação
    inteira, sem dizer qual passo.

    A ordem em que ele aparece aqui é a de uso: salvar **antes** de fechar. Ao
    contrário, o Ctrl+S chegaria a programas que já não existem.
    """
    headers, _ = _auth("salva1@example.com")
    resp = client.post(
        "/api/v1/automations",
        json={
            "name": "Fim do expediente",
            "steps": [{"kind": "save_all", "wait_ms": 2000}, {"kind": "close_all"}],
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    passos = resp.json()["steps"]
    assert passos[0] == {"kind": "save_all", "wait_ms": 2000}
    assert passos[1] == {"kind": "close_all"}


def test_fechar_tudo_ignora_campos_que_nao_lhe_dizem_respeito():
    """Mandar `name` num `close_all` não é erro: o passo simplesmente não usa.

    Recusar seria rigor sem ganho - o app pode carregar um campo vazio de um
    passo que era `close` e virou `close_all` -, e o que chega ao agente é
    limpo pelo `exclude_none` antes de sair.
    """
    headers, _ = _auth("fecha2@example.com")
    resp = client.post(
        "/api/v1/automations",
        json={"name": "A", "steps": [{"kind": "close_all", "name": "slack"}]},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
