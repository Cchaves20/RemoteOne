"""O agendamento das automações, e o caminho até o computador.

O recurso só tem sentido se funcionar **sem o celular por perto**: "18:00" não
pode depender de o telefone estar ligado, destravado e com o app aberto naquele
minuto. Por isso a agenda é empurrada ao agente, que dispara sozinho.

O que se testa aqui é a validação do horário e a entrega da agenda — o disparo
em si mora no agente, em Rust, e é testado lá.
"""

import json

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User

client = TestClient(app)


class AgenteFalso:
    def __init__(self):
        self.enviados = []

    async def send_json(self, message):
        self.enviados.append(message)

    def agendas(self):
        return [m for m in self.enviados if m.get("type") == "set_schedule"]


def _conta(email: str) -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
    return {"Authorization": f"Bearer {tokens['access_token']}"}, uid


def _parear(uid: int, device_id: str) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=uid,
                name="pc",
                os="windows",
                hostname="pc",
            )
        )
        db.commit()


def _criar(headers, **corpo):
    base = {"name": "Fim de expediente", "steps": [{"kind": "close_all"}]}
    return client.post("/api/v1/automations", json={**base, **corpo}, headers=headers)


# --- validação do horário ----------------------------------------------------


def test_horario_normalizado_para_dois_digitos():
    """O agente compara texto com texto: "8:5" nunca casaria com "08:05"."""
    headers, _ = _conta("ag1@example.com")
    resp = _criar(headers, schedule_time="8:5")
    assert resp.status_code == 201, resp.text
    assert resp.json()["schedule_time"] == "08:05"


def test_horario_impossivel_e_recusado():
    """Recusar aqui é a única chance: uma automação com horário inválido não
    dispara nunca, e não há tela onde esse erro apareça — ele só existiria às
    25h, que não chegam."""
    headers, _ = _conta("ag2@example.com")
    assert _criar(headers, schedule_time="25:00").status_code == 422
    assert _criar(headers, schedule_time="18h").status_code == 422
    assert _criar(headers, schedule_time="18:60").status_code == 422


def test_dias_sem_horario_nao_agendam_nada():
    headers, _ = _conta("ag3@example.com")
    assert _criar(headers, schedule_days=[0, 1]).status_code == 422


def test_dia_fora_da_semana_e_repetido():
    headers, _ = _conta("ag4@example.com")
    assert _criar(headers, schedule_time="18:00", schedule_days=[7]).status_code == 422
    assert (
        _criar(headers, schedule_time="18:00", schedule_days=[1, 1]).status_code == 422
    )


def test_sem_agendamento_continua_valendo():
    """A automação de toque não pode ter virado obrigatoriamente agendada."""
    headers, _ = _conta("ag5@example.com")
    resp = _criar(headers)
    assert resp.status_code == 201
    assert resp.json()["schedule_time"] == ""


# --- a agenda chegando ao computador -----------------------------------------


def test_criar_agendada_empurra_a_agenda_ao_computador():
    headers, uid = _conta("ag6@example.com")
    _parear(uid, "dev-ag-1")
    agente = AgenteFalso()
    manager.register("dev-ag-1", agente)
    try:
        assert _criar(
            headers,
            device_id="dev-ag-1",
            schedule_time="18:00",
            schedule_days=[0, 1, 2, 3, 4],
        ).status_code == 201

        agendas = agente.agendas()
        assert agendas, "o computador não recebeu a agenda"
        itens = agendas[-1]["items"]
        assert len(itens) == 1
        assert itens[0]["time"] == "18:00"
        assert itens[0]["days"] == [0, 1, 2, 3, 4]
        # Os passos vão junto: o agente dispara sozinho, então precisa saber o
        # que fazer sem perguntar a ninguém.
        assert itens[0]["steps"] == [{"kind": "close_all"}]
    finally:
        manager.unregister("dev-ag-1", agente)


def test_apagar_a_automacao_esvazia_a_agenda():
    """O agente só sabe o que lhe contaram. Sem este reenvio, a automação
    apagada continuaria disparando no computador para sempre."""
    headers, uid = _conta("ag7@example.com")
    _parear(uid, "dev-ag-2")
    agente = AgenteFalso()
    manager.register("dev-ag-2", agente)
    try:
        criada = _criar(
            headers, device_id="dev-ag-2", schedule_time="18:00"
        ).json()
        client.delete(f"/api/v1/automations/{criada['id']}", headers=headers)

        assert agente.agendas()[-1]["items"] == []
    finally:
        manager.unregister("dev-ag-2", agente)


def test_mudar_de_computador_avisa_os_dois():
    """O que passaria despercebido: reenviando só ao computador novo, o antigo
    continuaria disparando uma automação que já não é dele."""
    headers, uid = _conta("ag8@example.com")
    _parear(uid, "dev-ag-3")
    _parear(uid, "dev-ag-4")
    velho, novo = AgenteFalso(), AgenteFalso()
    manager.register("dev-ag-3", velho)
    manager.register("dev-ag-4", novo)
    try:
        criada = _criar(
            headers, device_id="dev-ag-3", schedule_time="18:00"
        ).json()
        client.put(
            f"/api/v1/automations/{criada['id']}",
            json={
                "name": "Fim de expediente",
                "steps": [{"kind": "close_all"}],
                "device_id": "dev-ag-4",
                "schedule_time": "18:00",
            },
            headers=headers,
        )

        assert velho.agendas()[-1]["items"] == [], "o computador antigo não foi avisado"
        assert len(novo.agendas()[-1]["items"]) == 1
    finally:
        manager.unregister("dev-ag-3", velho)
        manager.unregister("dev-ag-4", novo)


def test_a_agenda_chega_quando_o_agente_conecta():
    """O computador que passou a noite desligado precisa saber o que roda hoje
    antes de a hora chegar — e ninguém vai abrir o app para "sincronizar"."""
    headers, uid = _conta("ag9@example.com")
    _parear(uid, "dev-ag-5")
    _criar(headers, device_id="dev-ag-5", schedule_time="07:30")

    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-ag-5",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        recebidas = [ws.receive_json() for _ in range(3)]

    agendas = [m for m in recebidas if m.get("type") == "set_schedule"]
    assert agendas, f"nenhuma agenda no handshake; veio: {recebidas}"
    assert agendas[0]["items"][0]["time"] == "07:30"


def test_a_agenda_so_leva_o_que_e_daquele_computador():
    """Cada máquina recebe a sua. Mandar a agenda inteira da conta faria o
    notebook disparar o que era do desktop."""
    headers, uid = _conta("ag10@example.com")
    _parear(uid, "dev-ag-6")
    _parear(uid, "dev-ag-7")
    agente = AgenteFalso()
    manager.register("dev-ag-6", agente)
    try:
        _criar(headers, device_id="dev-ag-7", schedule_time="09:00")
        _criar(headers, device_id="dev-ag-6", schedule_time="18:00")

        itens = agente.agendas()[-1]["items"]
        assert [i["time"] for i in itens] == ["18:00"]
    finally:
        manager.unregister("dev-ag-6", agente)


def test_o_json_dos_dias_nao_derruba_a_leitura():
    """Campo ilegível não pode quebrar a listagem inteira de automações."""
    headers, uid = _conta("ag11@example.com")
    criada = _criar(headers, schedule_time="18:00", schedule_days=[0]).json()
    with SessionLocal() as db:
        from app.models import Automation

        row = db.scalar(
            select(Automation).where(Automation.automation_id == criada["id"])
        )
        row.schedule_days = "isto não é json"
        db.commit()

    listadas = client.get("/api/v1/automations", headers=headers).json()["automations"]
    assert listadas[0]["schedule_days"] == []
    assert json.loads("[]") == []
