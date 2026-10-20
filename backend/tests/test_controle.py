"""A barra "está controlando este computador" e o "Desconectar" do PC.

O que esta suíte guarda (ver `app/controle.py`):

- o agente fica sabendo de quem abre e fecha a tela, com nome e aparelho;
- o "Desconectar" fecha a tela com o código que o app reconhece **e** encerra o
  login do aparelho que estava vendo — só fechar não adiantaria;
- o dono da conta é avisado;
- um agente sem o segredo provado não consegue derrubar ninguém.
"""

import asyncio
from urllib.parse import quote

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import controle, pairing
from app.connections import Viewer, manager, viewers
from app.controle import FECHADO_NO_COMPUTADOR
from app.db import SessionLocal
from app.main import _segredo_do_aparelho, app
from app.models import User
from app.security import create_access_token, decode_token

client = TestClient(app)


def _parear(email: str, device_id: str) -> str:
    """Conta + computador pareado pelo caminho de verdade; devolve o segredo."""
    criar_conta(client, email=email)
    with SessionLocal() as db:
        dono = db.scalar(select(User).where(User.email == email))
        code = pairing.create_pairing_request(db, device_id, "Notebook da sala", "windows", 600)
        pairing.claim(db, code, dono)
        db.commit()
    return _segredo_do_aparelho(device_id)


def _entrar(email: str, aparelho: str) -> str:
    resp = client.post(
        "/api/v1/auth/login",
        json={"email": email, "password": SENHA},
        headers={"X-Deskside-Aparelho": quote(aparelho)},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["access_token"]


def _hello(device_id: str, segredo: str | None) -> dict:
    return {
        "type": "hello",
        "device_id": device_id,
        "hostname": "Notebook da sala",
        "os": "windows",
        "agent_version": "0.1.0",
        "secret": segredo,
    }


def _ate(ws, tipo: str, limite: int = 20) -> dict:
    """Lê até chegar uma mensagem do tipo pedido."""
    for _ in range(limite):
        msg = ws.receive_json()
        if msg.get("type") == tipo:
            return msg
    raise AssertionError(f"nenhuma mensagem {tipo!r}")


class AgenteFalso:
    """O agente do ponto de vista do servidor.

    Um dublê, e não um segundo WebSocket: o cliente de testes roda cada
    WebSocket num laço de eventos próprio, e o que um envia ao outro só acorda
    o destinatário por acaso. Em produção é um laço só.
    """

    def __init__(self):
        self.recebido = []

    async def send_json(self, message):
        self.recebido.append(message)

    def do_tipo(self, tipo):
        return [m for m in self.recebido if m.get("type") == tipo]


class SocketFalso:
    def __init__(self):
        self.fechado_com = None

    async def close(self, code=1000):
        self.fechado_com = code


def _tela_falsa(device_id: str, token: str) -> Viewer:
    """Uma tela aberta, registrada como o `viewer_ws` registra."""
    viewer = Viewer(SocketFalso())
    controle.identificar(viewer, decode_token(token))
    viewers.add(device_id, viewer)
    return viewer


def _me(token: str) -> int:
    return client.get(
        "/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"}
    ).status_code


def test_o_agente_sabe_quem_abriu_e_fechou_a_tela():
    _parear("ctl1@example.com", "dev-ctl-1")
    token = _entrar("ctl1@example.com", "iPhone · iOS 18.1")
    agente = AgenteFalso()
    manager.register("dev-ctl-1", agente)
    try:
        with client.websocket_connect("/ws/viewer/dev-ctl-1") as tela:
            tela.send_json({"token": token})
            tela.send_json({"type": "webrtc_ice", "candidate": ""})
            tela.close()
    finally:
        manager.unregister("dev-ctl-1", agente)
    listas = [m["viewers"] for m in agente.do_tipo("controle")]
    assert listas[0] == [{"nome": "Caio", "aparelho": "iPhone · iOS 18.1"}]
    assert listas[-1] == []


def test_desconectar_fecha_a_tela_e_encerra_o_login(espiao):
    _parear("ctl2@example.com", "dev-ctl-2")
    token = _entrar("ctl2@example.com", "Celular Android")
    espiao.avisos.clear()
    tela = _tela_falsa("dev-ctl-2", token)
    try:
        assert asyncio.run(controle.encerrar("dev-ctl-2")) == 1
    finally:
        viewers.remove("dev-ctl-2", tela)

    assert tela.websocket.fechado_com == FECHADO_NO_COMPUTADOR
    # O login daquele aparelho acabou: reconectar não basta para voltar.
    assert _me(token) == 401
    assunto, corpo = espiao.avisos[-1][1], espiao.avisos[-1][2]
    assert assunto == "Controle encerrado no computador"
    assert "Notebook da sala" in corpo


def test_desconectar_nao_derruba_outros_aparelhos_da_conta():
    _parear("ctl3@example.com", "dev-ctl-3")
    vendo = _entrar("ctl3@example.com", "iPhone")
    outro = _entrar("ctl3@example.com", "iPad")
    tela = _tela_falsa("dev-ctl-3", vendo)
    try:
        asyncio.run(controle.encerrar("dev-ctl-3"))
    finally:
        viewers.remove("dev-ctl-3", tela)
    assert _me(vendo) == 401
    assert _me(outro) == 200


def test_app_antigo_sem_sessao_derruba_todos_os_logins_da_conta():
    """Sem `sid` não há como tirar só ele: saem todos, que é o lado seguro."""
    _parear("ctl4@example.com", "dev-ctl-4")
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == "ctl4@example.com"))
        antigo = create_access_token(str(user.id), user.token_key)
    outro = _entrar("ctl4@example.com", "iPad")
    tela = _tela_falsa("dev-ctl-4", antigo)
    assert controle.mensagem("dev-ctl-4")["viewers"] == [{"nome": "Caio", "aparelho": ""}]
    try:
        asyncio.run(controle.encerrar("dev-ctl-4"))
    finally:
        viewers.remove("dev-ctl-4", tela)
    assert _me(antigo) == 401
    assert _me(outro) == 401


def test_sem_ninguem_vendo_nao_faz_nada(espiao):
    _parear("ctl6@example.com", "dev-ctl-6")
    espiao.avisos.clear()
    assert asyncio.run(controle.encerrar("dev-ctl-6")) == 0
    assert espiao.avisos == []


def test_o_pedido_do_agente_chega_ao_encerrar(monkeypatch):
    segredo = _parear("ctl7@example.com", "dev-ctl-7")
    chamados = []

    async def anotar(device_id):
        chamados.append(device_id)
        return 0

    monkeypatch.setattr(controle, "encerrar", anotar)
    with client.websocket_connect("/ws/agent") as agente:
        agente.send_json(_hello("dev-ctl-7", segredo))
        _ate(agente, "paired")
        agente.send_json({"type": "encerrar_controle"})
        # Um heartbeat depois, como barreira: quando o `ack` chega, o pedido
        # anterior já foi tratado.
        agente.send_json({"type": "heartbeat"})
        _ate(agente, "ack")
    assert chamados == ["dev-ctl-7"]


def test_agente_sem_segredo_nao_derruba_ninguem(monkeypatch):
    """Sem segredo provado, quem soubesse o `device_id` derrubaria o dono."""
    _parear("ctl5@example.com", "dev-ctl-5")
    chamados = []

    async def anotar(device_id):
        chamados.append(device_id)
        return 0

    monkeypatch.setattr(controle, "encerrar", anotar)
    with client.websocket_connect("/ws/agent") as agente:
        agente.send_json(_hello("dev-ctl-5", None))
        _ate(agente, "welcome")
        agente.send_json({"type": "encerrar_controle"})
        assert "segredo" in _ate(agente, "error")["message"]
    assert chamados == []


def test_aviso_da_tela_chega_a_quem_esta_vendo():
    """O Linux avisando que pede permissão na tela: sem isto, o app veria só a
    tela preta."""
    segredo = _parear("ctl8@example.com", "dev-ctl-8")
    token = _entrar("ctl8@example.com", "iPhone")
    tela = _tela_falsa("dev-ctl-8", token)
    try:
        with client.websocket_connect("/ws/agent") as agente:
            agente.send_json(_hello("dev-ctl-8", segredo))
            _ate(agente, "paired")
            agente.send_json({"type": "aviso_da_tela", "mensagem": "Aprove na tela."})
            agente.send_json({"type": "heartbeat"})
            _ate(agente, "ack")
    finally:
        viewers.remove("dev-ctl-8", tela)
    assert {"type": "aviso_da_tela", "mensagem": "Aprove na tela."} in list(tela._signals)
