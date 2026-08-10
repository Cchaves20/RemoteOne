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
from conftest import criar_conta

client = TestClient(app)

#: O que um agente **antigo** manda: só as quatro medidas originais. Continua
#: aqui de propósito - é a versão que está instalada nos computadores enquanto
#: a atualização não chega a todos, e ela não pode virar erro de validação.
STATS = {
    "cpu_percent": 37.4,
    "memory_used": 8_000_000_000,
    "memory_total": 16_000_000_000,
    "disk_used": 300_000_000_000,
    "disk_total": 500_000_000_000,
    "disk_name": "C:",
    "uptime_seconds": 3600,
}

#: O que os campos opcionais valem quando o agente não os manda. `None` e não
#: zero: desktop não tem bateria e máquina virtual não tem GPU dedicada, e o
#: app esconde a medida ausente em vez de mostrar 0.
AUSENTES = {
    "gpu_percent": None,
    "gpu_name": None,
    "temperature_celsius": None,
    "network_rx_bps": 0,
    "network_tx_bps": 0,
    "battery_percent": None,
    "on_battery": None,
}

#: O que um agente atualizado manda num notebook com GPU, sensor e bateria.
STATS_COMPLETO = {
    **STATS,
    "gpu_percent": 42.5,
    "gpu_name": "NVIDIA GeForce RTX 3060",
    "temperature_celsius": 51.2,
    "network_rx_bps": 1_500_000,
    "network_tx_bps": 2048,
    "battery_percent": 87,
    "on_battery": True,
}


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
    """Agente que responde na hora, dentro do próprio envio.

    Substitui o vaivém real: o endpoint fica esperando um `Future` e este dublê
    o resolve, então o teste passa pelo mesmo código que a produção usa.
    """

    def __init__(self, stats: dict | None = None, brightness: dict | None = None):
        self.stats = stats
        #: Resposta ao pedido de brilho. `None` = agente mudo, que é o caso do
        #: teste de tempo esgotado.
        self.brightness = brightness
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "system_info" and self.stats is not None:
            pending.resolve(message["request_id"], self.stats)
        if message.get("type") == "brightness" and self.brightness is not None:
            pending.resolve(message["request_id"], self.brightness)

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
    # Um agente antigo não manda as medidas novas, e o backend preenche a
    # ausência em vez de recusar a resposta.
    assert resp.json() == {**STATS, **AUSENTES}
    # O agente recebeu um pedido com request_id (é o que casa a resposta).
    pedido = agent.of_type("system_info")[0]
    assert pedido["request_id"]


def test_system_leva_as_medidas_novas_quando_o_agente_manda():
    """GPU, temperatura, rede e bateria atravessam o backend intactas.

    O caminho é só repasse, mas o `response_model` do FastAPI **descarta** o que
    não estiver declarado no schema: sem um teste aqui, esquecer um campo no
    `SystemStatsOut` some com a medida sem erro nenhum aparecer.
    """
    headers, uid = _auth_headers("sys6@example.com")
    _add_device(uid, "dev-sys-6")
    agent = InstantAgent(STATS_COMPLETO)
    manager.register("dev-sys-6", agent)
    try:
        resp = client.get("/api/v1/devices/dev-sys-6/system", headers=headers)
    finally:
        manager.unregister("dev-sys-6")
    assert resp.status_code == 200
    assert resp.json() == STATS_COMPLETO


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


def test_brilho_devolve_o_nivel_resultante():
    """O caminho feliz: o agente ajusta e responde com o nível."""
    headers, uid = _auth_headers("bri1@example.com")
    _add_device(uid, "dev-bri-1")
    agent = InstantAgent(brightness={"level": 60, "error": None})
    manager.register("dev-bri-1", agent)
    try:
        resp = client.post(
            "/api/v1/devices/dev-bri-1/brightness",
            json={"delta": 10},
            headers=headers,
        )
    finally:
        manager.unregister("dev-bri-1")
    assert resp.status_code == 200
    assert resp.json() == {"level": 60}
    # O passo relativo vai para o computador como passo, e não resolvido aqui:
    # é lá que ele é somado ao valor atual.
    pedido = agent.of_type("brightness")[0]
    assert pedido["delta"] == 10
    assert pedido["level"] is None


def test_brilho_recusado_explica_o_motivo():
    """Computador de mesa: a recusa sobe com a explicação, não como 500.

    O motivo é a única informação útil que existe aqui - "seu monitor não
    permite" e "deu problema" levam a pessoa a fazer coisas diferentes.
    """
    headers, uid = _auth_headers("bri2@example.com")
    _add_device(uid, "dev-bri-2")
    agent = InstantAgent(
        brightness={"level": None, "error": "só painel embutido de notebook"}
    )
    manager.register("dev-bri-2", agent)
    try:
        resp = client.post(
            "/api/v1/devices/dev-bri-2/brightness",
            json={"level": 50},
            headers=headers,
        )
    finally:
        manager.unregister("dev-bri-2")
    assert resp.status_code == 409
    assert "notebook" in resp.json()["detail"]


def test_brilho_exige_level_ou_delta_e_nao_os_dois():
    """Os dois juntos seriam ambíguos, e nenhum dos dois não é pedido nenhum."""
    headers, uid = _auth_headers("bri3@example.com")
    _add_device(uid, "dev-bri-3")
    for corpo in ({}, {"level": 50, "delta": 10}):
        resp = client.post(
            "/api/v1/devices/dev-bri-3/brightness", json=corpo, headers=headers
        )
        assert resp.status_code == 422, corpo


def test_brilho_com_agente_offline_503():
    headers, uid = _auth_headers("bri4@example.com")
    _add_device(uid, "dev-bri-4")
    resp = client.post(
        "/api/v1/devices/dev-bri-4/brightness", json={"delta": -10}, headers=headers
    )
    assert resp.status_code == 503
