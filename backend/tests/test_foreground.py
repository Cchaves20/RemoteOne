"""Programa em primeiro plano no computador (ícone dos perfis).

Mesmo desenho do endpoint de métricas: pergunta com `request_id`, resposta do
agente pelo WebSocket. O que muda é que aqui a **ausência de resposta útil** é
legítima - nem sempre há uma janela em foco -, e isso não pode virar erro.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending
from conftest import criar_conta

client = TestClient(app)

APP = {"name": "Microsoft PowerPoint", "exe": "powerpnt.exe", "icon": "AAA"}


def _auth_headers(email: str) -> tuple[dict, int]:
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


class InstantAgent:
    """Agente que responde na hora, dentro do próprio envio."""

    def __init__(self, app_info: dict | None = None, responde: bool = True):
        self.app_info = app_info
        self.responde = responde
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "foreground_info" and self.responde:
            pending.resolve(message["request_id"], {"app": self.app_info})

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_foreground_do_agente():
    message = parse_client_message(
        {"type": "foreground_app", "request_id": "r1", "app": APP}
    )
    assert message.request_id == "r1"
    assert message.app.exe == "powerpnt.exe"
    assert message.app.icon == "AAA"


def test_parse_foreground_sem_app():
    """Nenhuma janela em foco é resposta normal, não erro."""
    message = parse_client_message({"type": "foreground_app", "request_id": "r1"})
    assert message.app is None


def test_parse_foreground_sem_icone():
    """Programa cujo ícone não deu para extrair continua servindo: o app usa o
    executável para saber de qual perfil ele é."""
    message = parse_client_message(
        {
            "type": "foreground_app",
            "request_id": "r1",
            "app": {"name": "Jogo", "exe": "jogo.exe"},
        }
    )
    assert message.app.icon is None
    assert message.app.exe == "jogo.exe"


# --- endpoint ----------------------------------------------------------------


def test_foreground_devolve_o_programa_da_frente():
    headers, uid = _auth_headers("fg1@example.com")
    _add_device(uid, "dev-fg-1")
    agent = InstantAgent(APP)
    manager.register("dev-fg-1", agent)
    try:
        resp = client.get("/api/v1/devices/dev-fg-1/foreground", headers=headers)
    finally:
        manager.unregister("dev-fg-1")
    assert resp.status_code == 200
    assert resp.json() == {"app": APP}
    assert agent.of_type("foreground_info")[0]["request_id"]


def test_foreground_sem_janela_em_foco_e_200_com_nulo():
    """Sem janela em foco o app precisa de uma resposta, não de um erro: é o
    sinal para voltar aos ícones genéricos."""
    headers, uid = _auth_headers("fg2@example.com")
    _add_device(uid, "dev-fg-2")
    manager.register("dev-fg-2", InstantAgent(None))
    try:
        resp = client.get("/api/v1/devices/dev-fg-2/foreground", headers=headers)
    finally:
        manager.unregister("dev-fg-2")
    assert resp.status_code == 200
    assert resp.json() == {"app": None}


def test_foreground_com_agente_offline_503():
    headers, uid = _auth_headers("fg3@example.com")
    _add_device(uid, "dev-fg-3")
    resp = client.get("/api/v1/devices/dev-fg-3/foreground", headers=headers)
    assert resp.status_code == 503


def test_foreground_de_outra_conta_404():
    """Saber o que está aberto no computador é informação de quem o usa."""
    _, dono = _auth_headers("fg4@example.com")
    _add_device(dono, "dev-fg-4")
    intruso, _ = _auth_headers("fg5@example.com")
    resp = client.get("/api/v1/devices/dev-fg-4/foreground", headers=intruso)
    assert resp.status_code == 404


def test_foreground_sem_token_401():
    resp = client.get("/api/v1/devices/dev-fg-1/foreground")
    assert resp.status_code == 401


def test_foreground_que_nao_responde_da_504_e_nao_vaza_pedido():
    headers, uid = _auth_headers("fg6@example.com")
    _add_device(uid, "dev-fg-6")
    manager.register("dev-fg-6", InstantAgent(responde=False))
    antes = pending.pending_count()
    try:
        resp = client.get("/api/v1/devices/dev-fg-6/foreground", headers=headers)
    finally:
        manager.unregister("dev-fg-6")
    assert resp.status_code == 504
    assert pending.pending_count() == antes, "o pedido abandonado ficou pendurado"


def test_agente_pode_mandar_foreground_sem_ninguem_esperando():
    """Resposta atrasada (o pedido já expirou) não derruba a conexão."""
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-fg-ws",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()  # pair_code
        ws.send_json({"type": "foreground_app", "request_id": "inexistente", "app": APP})
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"


def test_health_anuncia_o_recurso():
    assert "foreground-app" in client.get("/health").json()["features"]


# --- som do computador -------------------------------------------------------


def test_audio_liga_e_desliga_no_agente():
    headers, uid = _auth_headers("audio1@example.com")
    _add_device(uid, "dev-audio-1")
    agent = InstantAgent()
    manager.register("dev-audio-1", agent)
    try:
        for ligado in (True, False):
            resp = client.post(
                "/api/v1/devices/dev-audio-1/audio",
                json={"enabled": ligado},
                headers=headers,
            )
            assert resp.status_code == 204, ligado
    finally:
        manager.unregister("dev-audio-1")
    assert [m["enabled"] for m in agent.of_type("audio")] == [True, False]
    # Sem ganho pedido, o som vai como o computador o entregou.
    assert agent.of_type("audio")[0]["gain"] == 1.0


def test_audio_exige_o_campo():
    headers, uid = _auth_headers("audio2@example.com")
    _add_device(uid, "dev-audio-2")
    resp = client.post(
        "/api/v1/devices/dev-audio-2/audio", json={}, headers=headers
    )
    assert resp.status_code == 422


def test_audio_leva_o_ganho_ao_agente():
    """O ganho é o que permite deixar o computador quase mudo e ouvir no
    telefone: ele precisa chegar do outro lado."""
    headers, uid = _auth_headers("audio7@example.com")
    _add_device(uid, "dev-audio-7")
    agent = InstantAgent()
    manager.register("dev-audio-7", agent)
    try:
        resp = client.post(
            "/api/v1/devices/dev-audio-7/audio",
            json={"enabled": True, "gain": 12.5},
            headers=headers,
        )
    finally:
        manager.unregister("dev-audio-7")
    assert resp.status_code == 204
    assert agent.of_type("audio")[0]["gain"] == 12.5


def test_audio_recusa_ganho_absurdo():
    """Um ganho de 500x estouraria o ouvido de quem está com o fone."""
    headers, uid = _auth_headers("audio8@example.com")
    _add_device(uid, "dev-audio-8")
    for ganho in (-1, 500):
        resp = client.post(
            "/api/v1/devices/dev-audio-8/audio",
            json={"enabled": True, "gain": ganho},
            headers=headers,
        )
        assert resp.status_code == 422, ganho


def test_audio_com_agente_offline_503():
    headers, uid = _auth_headers("audio3@example.com")
    _add_device(uid, "dev-audio-3")
    resp = client.post(
        "/api/v1/devices/dev-audio-3/audio", json={"enabled": True}, headers=headers
    )
    assert resp.status_code == 503


def test_audio_de_outra_conta_404():
    """Ouvir o som do computador de alguém é escutar a casa dela."""
    _, dono = _auth_headers("audio4@example.com")
    _add_device(dono, "dev-audio-4")
    intruso, _ = _auth_headers("audio5@example.com")
    resp = client.post(
        "/api/v1/devices/dev-audio-4/audio", json={"enabled": True}, headers=intruso
    )
    assert resp.status_code == 404


def test_audio_sem_token_401():
    resp = client.post("/api/v1/devices/dev-audio-1/audio", json={"enabled": True})
    assert resp.status_code == 401


def test_health_anuncia_o_audio():
    assert "audio-stream" in client.get("/health").json()["features"]
