"""Métricas do computador (CPU/memória/disco) e teclas de mídia.

O endpoint de métricas é pergunta e resposta: o backend manda `system_info` e
espera o `system_stats` do agente. Aqui o agente é um dublê que responde dentro
do próprio envio, o que exercita o caminho completo sem threads.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending

client = TestClient(app)

STATS = {
    "cpu_percent": 37.4,
    "memory_used": 8_000_000_000,
    "memory_total": 16_000_000_000,
    "disk_used": 300_000_000_000,
    "disk_total": 500_000_000_000,
    "disk_name": "C:",
    "uptime_seconds": 3600,
}


def _auth_headers(email: str) -> tuple[dict, int]:
    tokens = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "senhaSegura123"}
    ).json()
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
    """Agente que responde na hora, dentro do próprio envio.

    Substitui o vaivém real: o endpoint fica esperando um `Future` e este dublê
    o resolve, então o teste passa pelo mesmo código que a produção usa.
    """

    def __init__(self, stats: dict | None = None):
        self.stats = stats
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "system_info" and self.stats is not None:
            pending.resolve(message["request_id"], self.stats)

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_system_stats_do_agente():
    message = parse_client_message(
        {"type": "system_stats", "request_id": "r1", "stats": STATS}
    )
    assert message.request_id == "r1"
    assert message.stats.cpu_percent == 37.4
    assert message.stats.disk_name == "C:"


def test_cpu_fora_da_faixa_e_rejeitada():
    """101% não existe: um agente com defeito não deve virar tela com número
    impossível."""
    for bad in (-1, 101):
        try:
            parse_client_message(
                {
                    "type": "system_stats",
                    "request_id": "r1",
                    "stats": {**STATS, "cpu_percent": bad},
                }
            )
        except ValueError:
            continue
        raise AssertionError(f"cpu_percent={bad} deveria ser rejeitado")


def test_agente_pode_mandar_system_stats_sem_ninguem_esperando():
    """Resposta atrasada (o pedido já expirou) não derruba a conexão."""
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-sys-ws",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()  # pair_code
        ws.send_json(
            {"type": "system_stats", "request_id": "inexistente", "stats": STATS}
        )
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"


# --- endpoint de métricas ----------------------------------------------------


def test_system_devolve_as_metricas_do_agente():
    headers, uid = _auth_headers("sys1@example.com")
    _add_device(uid, "dev-sys-1")
    agent = InstantAgent(STATS)
    manager.register("dev-sys-1", agent)
    try:
        resp = client.get("/api/v1/devices/dev-sys-1/system", headers=headers)
    finally:
        manager.unregister("dev-sys-1")
    assert resp.status_code == 200
    assert resp.json() == STATS
    # O agente recebeu um pedido com request_id (é o que casa a resposta).
    pedido = agent.of_type("system_info")[0]
    assert pedido["request_id"]


def test_system_com_agente_offline_503():
    headers, uid = _auth_headers("sys2@example.com")
    _add_device(uid, "dev-sys-2")
    resp = client.get("/api/v1/devices/dev-sys-2/system", headers=headers)
    assert resp.status_code == 503


def test_system_de_outra_conta_404():
    """Métricas revelam uso do computador: só o dono pode ler."""
    _, dono = _auth_headers("sys3@example.com")
    _add_device(dono, "dev-sys-3")
    intruso, _ = _auth_headers("sys4@example.com")
    resp = client.get("/api/v1/devices/dev-sys-3/system", headers=intruso)
    assert resp.status_code == 404


def test_system_sem_token_401():
    resp = client.get("/api/v1/devices/dev-sys-1/system")
    assert resp.status_code == 401


def test_system_que_nao_responde_da_504_e_nao_vaza_pedido():
    headers, uid = _auth_headers("sys5@example.com")
    _add_device(uid, "dev-sys-5")
    # Agente registrado mas mudo: `stats=None`, então nada resolve o pedido.
    manager.register("dev-sys-5", InstantAgent())
    antes = pending.pending_count()
    try:
        resp = client.get("/api/v1/devices/dev-sys-5/system", headers=headers)
    finally:
        manager.unregister("dev-sys-5")
    assert resp.status_code == 504
    assert pending.pending_count() == antes, "o pedido abandonado ficou pendurado"


# --- teclas de mídia ---------------------------------------------------------


def test_media_repassa_a_acao_ao_agente():
    headers, uid = _auth_headers("media1@example.com")
    _add_device(uid, "dev-media-1")
    agent = InstantAgent()
    manager.register("dev-media-1", agent)
    try:
        resp = client.post(
            "/api/v1/devices/dev-media-1/media",
            json={"action": "play_pause"},
            headers=headers,
        )
    finally:
        manager.unregister("dev-media-1")
    assert resp.status_code == 204
    assert agent.of_type("media") == [{"type": "media", "action": "play_pause"}]


def test_media_aceita_as_seis_acoes():
    headers, uid = _auth_headers("media2@example.com")
    _add_device(uid, "dev-media-2")
    agent = InstantAgent()
    manager.register("dev-media-2", agent)
    acoes = ("play_pause", "next", "previous", "volume_up", "volume_down", "mute")
    try:
        for acao in acoes:
            resp = client.post(
                "/api/v1/devices/dev-media-2/media",
                json={"action": acao},
                headers=headers,
            )
            assert resp.status_code == 204, acao
    finally:
        manager.unregister("dev-media-2")
    assert [m["action"] for m in agent.of_type("media")] == list(acoes)


def test_media_rejeita_acao_desconhecida():
    headers, uid = _auth_headers("media3@example.com")
    _add_device(uid, "dev-media-3")
    resp = client.post(
        "/api/v1/devices/dev-media-3/media",
        json={"action": "formatar_o_disco"},
        headers=headers,
    )
    assert resp.status_code == 422


def test_media_com_agente_offline_503():
    headers, uid = _auth_headers("media4@example.com")
    _add_device(uid, "dev-media-4")
    resp = client.post(
        "/api/v1/devices/dev-media-4/media",
        json={"action": "mute"},
        headers=headers,
    )
    assert resp.status_code == 503


def test_media_de_outra_conta_404():
    _, dono = _auth_headers("media5@example.com")
    _add_device(dono, "dev-media-5")
    intruso, _ = _auth_headers("media6@example.com")
    resp = client.post(
        "/api/v1/devices/dev-media-5/media",
        json={"action": "mute"},
        headers=intruso,
    )
    assert resp.status_code == 404


def test_health_anuncia_os_recursos_novos():
    """O `/health` é como se descobre se o VPS está atualizado."""
    features = client.get("/health").json()["features"]
    assert "system-stats" in features
    assert "media-keys" in features
