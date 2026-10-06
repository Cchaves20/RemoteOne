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

from conftest import criar_conta
from fastapi.testclient import TestClient

from app.config import settings
from app.ice import ice_servers, precisa_renovar
from app.main import app

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
    # **Vazio**, e é o certo: este agente não está pareado. A credencial de TURN
    # ia em todo `welcome`, e como o canal não autenticava, qualquer pessoa
    # abria um socket com um id inventado e recebia relay válido por 12 horas —
    # um relay aberto pago com a banda deste servidor. Ver S4 em
    # docs/revisao-de-seguranca.md.
    assert welcome["ice_servers"] == []


def test_health_anuncia_o_recurso():
    """O `/health` é como se confere se o VPS já tem o que o app espera."""
    assert "ice-servers" in client.get("/health").json()["features"]


# --- a credencial do agente se renova -----------------------------------------


def test_renova_quem_nunca_recebeu_e_quem_passou_da_metade():
    doze_horas = 12 * 3600
    # Pareou depois de conectar: recebeu lista vazia no welcome.
    assert precisa_renovar(None, 1000.0, doze_horas)
    # Recém-entregue: nada a fazer a cada batida de 10 s.
    assert not precisa_renovar(1000.0, 1010.0, doze_horas)
    # Na metade da validade, renova — antes de vencer, com folga para uma
    # sessão de vídeo que comece no fim.
    assert precisa_renovar(1000.0, 1000.0 + 6 * 3600, doze_horas)


def _ler_ate(ws, tipo: str, limite: int = 8) -> dict:
    for _ in range(limite):
        msg = ws.receive_json()
        if msg.get("type") == tipo:
            return msg
    raise AssertionError(f"não veio nenhum {tipo} em {limite} mensagens")


def test_computador_pareado_depois_de_conectar_recebe_o_turn():
    """O defeito: quem pareou com o agente já conectado ficava sem TURN.

    O `welcome` de quem ainda não pareou vem sem credencial (de propósito, ver
    `test_seguranca`), e nada a entregava depois do pareamento. O vídeo direto
    só fechava na rede local até o agente reconectar por acaso.
    """

    def cenario():
        token = criar_conta(client, "pareia-depois@example.com")["access_token"]
        with client.websocket_connect("/ws/agent") as ws:
            ws.send_json(
                {
                    "type": "hello",
                    "device_id": "dev-pareia-depois",
                    "hostname": "PC",
                    "os": "windows",
                    "agent_version": "0.1.0",
                    "secret": "",
                }
            )
            assert ws.receive_json()["ice_servers"] == []
            codigo = ws.receive_json()["code"]
            resp = client.post(
                "/api/v1/pairing/claim",
                json={"code": codigo},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert resp.status_code == 201, resp.text

            ws.send_json({"type": "heartbeat"})
            novo = _ler_ate(ws, "welcome")
            urls = [u for s in novo["ice_servers"] for u in s["urls"]]
            assert any(u.startswith("turn:") for u in urls), novo
            assert any(s.get("username") for s in novo["ice_servers"])

            # E não repete a cada batida.
            ws.send_json({"type": "heartbeat"})
            assert ws.receive_json()["type"] == "ack"

    _com_turn(cenario)
