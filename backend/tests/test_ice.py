"""Servidores ICE: STUN sempre, TURN quando configurado.

O TURN é o que faz o vídeo direto funcionar quando o celular está no 5G e o
computador atrás do roteador de casa - dois NATs que não deixam nada entrar.
As credenciais são temporárias e conferidas por HMAC pelo próprio coturn, sem
banco de dados nenhum.
"""

import base64
import hashlib
import hmac
import time

from fastapi.testclient import TestClient

from app.config import settings
from app.ice import ice_servers
from app.main import app
from conftest import criar_conta

client = TestClient(app)


def _com_turn(func):
    """Roda `func` com um TURN configurado e devolve tudo como estava."""
    antes = (settings.turn_host, settings.turn_secret, settings.turn_port)
    settings.turn_host = "turn.exemplo.org"
    settings.turn_secret = "segredo-compartilhado"
    settings.turn_port = 3478
    try:
        return func()
    finally:
        settings.turn_host, settings.turn_secret, settings.turn_port = antes


def test_sem_turn_configurado_entrega_so_stun():
    """Servidor sem TURN não pode virar erro: quem só quer ver a tela continua
    vendo, e o P2P tenta como sempre tentou."""
    servers = ice_servers("u1")
    assert len(servers) == 1
    assert servers[0]["urls"][0].startswith("stun:")


def test_com_turn_entrega_udp_e_tcp():
    servers = _com_turn(lambda: ice_servers("u1"))
    assert len(servers) == 2
    urls = servers[1]["urls"]
    assert any("transport=udp" in u for u in urls)
    # TCP existe para redes que bloqueiam UDP (Wi-Fi corporativo é o caso).
    assert any("transport=tcp" in u for u in urls)
    assert all(u.startswith("turn:turn.exemplo.org:3478") for u in urls)


def test_a_senha_e_o_hmac_que_o_coturn_vai_conferir():
    """Se esta conta divergir da do coturn, o TURN recusa todo mundo - e a
    falha aparece só como 'não conectou', sem dizer por quê."""
    servers = _com_turn(lambda: ice_servers("u42"))
    turn = servers[1]
    username = turn["username"]
    esperado = base64.b64encode(
        hmac.new(b"segredo-compartilhado", username.encode(), hashlib.sha1).digest()
    ).decode()
    assert turn["credential"] == esperado


def test_o_usuario_carrega_a_hora_de_expirar():
    servers = _com_turn(lambda: ice_servers("u42"))
    expira, quem = servers[1]["username"].split(":", 1)
    assert quem == "u42"
    # No futuro, e dentro do prazo configurado (com folga para o teste lento).
    restante = int(expira) - int(time.time())
    assert 0 < restante <= settings.turn_ttl_seconds + 5


def test_endpoint_exige_login():
    assert client.get("/api/v1/ice-servers").status_code == 401


def test_endpoint_devolve_a_lista():
    tokens = criar_conta(client, email="ice1@example.com")
    resp = client.get(
        "/api/v1/ice-servers",
        headers={"Authorization": f"Bearer {tokens['access_token']}"},
    )
    assert resp.status_code == 200
    servers = resp.json()["ice_servers"]
    assert servers and servers[0]["urls"][0].startswith("stun:")


def test_welcome_do_agente_leva_os_servidores():
    """O agente precisa dos mesmos servidores que o app, e as credenciais são
    temporárias: fixá-las na configuração dele obrigaria a reinstalar."""
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-ice-ws",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        welcome = ws.receive_json()
    assert welcome["type"] == "welcome"
    assert welcome["ice_servers"][0]["urls"][0].startswith("stun:")


def test_health_anuncia_o_recurso():
    """O `/health` é como se confere se o VPS já tem o que o app espera."""
    assert "ice-servers" in client.get("/health").json()["features"]
