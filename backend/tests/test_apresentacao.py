"""Modo apresentação: a tela não apaga e as notificações não aparecem.

O que se testa aqui é o caminho até o computador — a decisão de **quando** o
modo vale mora no agente, em Rust, e é testada lá. O que este servidor precisa
acertar é mais estreito e tem uma armadilha própria: os dois campos (`on` e
`auto`) vêm de lugares diferentes da tela e não podem se atropelar.
"""

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending

client = TestClient(app)


def _auth(email: str) -> tuple[dict, int]:
    tokens = criar_conta(client, email=email)
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
    return {"Authorization": f"Bearer {tokens['access_token']}"}, uid


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


class AgenteInstantaneo:
    """Responde na hora, dentro do próprio envio."""

    def __init__(self, **estado):
        self.estado = {
            "on": False,
            "auto": False,
            "detected": None,
            "supported": True,
            **estado,
        }
        self.enviados: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.enviados.append(message)
        if message.get("type") == "presentation_info":
            pending.resolve(message["request_id"], dict(self.estado))

    def do_tipo(self, kind: str) -> list[dict]:
        return [m for m in self.enviados if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_do_estado_com_o_que_foi_detectado():
    """`detected` é o que explica um modo que ligou sozinho.

    Sem ele, a pessoa vê a chave ligada e não faz ideia de quem a ligou.
    """
    message = parse_client_message(
        {
            "type": "presentation_state",
            "request_id": "r1",
            "on": True,
            "auto": True,
            "detected": "Apresentação1 - PowerPoint",
            "supported": True,
        }
    )
    assert message.on is True
    assert message.detected == "Apresentação1 - PowerPoint"


def test_sem_deteccao_e_sem_suporte_sao_estados_validos():
    """Windows sem `PresentationSettings` existe, e o app precisa saber: a tela
    continua acesa, mas as notificações não são silenciadas."""
    message = parse_client_message(
        {
            "type": "presentation_state",
            "request_id": "r1",
            "on": True,
            "auto": False,
            "supported": False,
        }
    )
    assert message.detected is None
    assert message.supported is False


# --- consultar ---------------------------------------------------------------


def test_o_estado_vem_do_computador_e_nao_do_banco():
    """A detecção liga e desliga o modo sozinha a cada três segundos. Um valor
    guardado aqui estaria errado justamente quando alguém abre a tela para
    conferir."""
    headers, uid = _auth("ap1@example.com")
    _add_device(uid, "dev-ap-1")
    agente = AgenteInstantaneo(on=True, auto=True, detected="Slides")
    manager.register("dev-ap-1", agente)
    try:
        resp = client.get("/api/v1/devices/dev-ap-1/presentation", headers=headers)
    finally:
        manager.unregister("dev-ap-1", agente)

    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "on": True,
        "auto": True,
        "detected": "Slides",
        "supported": True,
    }
    assert agente.do_tipo("presentation_info")[0]["request_id"]


def test_computador_desligado_responde_503():
    headers, uid = _auth("ap2@example.com")
    _add_device(uid, "dev-ap-2")
    resp = client.get("/api/v1/devices/dev-ap-2/presentation", headers=headers)
    assert resp.status_code == 503


# --- mudar -------------------------------------------------------------------


def test_o_botao_manda_so_a_escolha_e_a_area_de_perfis_so_o_automatico():
    """A armadilha deste recurso, e a razão de os campos serem opcionais.

    O botão da barra de perfis e a tela de perfis mexem em coisas diferentes. Se
    cada um tivesse de mandar os dois campos, mandaria junto um valor que leu há
    dez minutos — e desfaria, sem querer, a escolha que o outro acabou de fazer.
    """
    headers, uid = _auth("ap3@example.com")
    _add_device(uid, "dev-ap-3")
    agente = AgenteInstantaneo()
    manager.register("dev-ap-3", agente)
    try:
        client.post(
            "/api/v1/devices/dev-ap-3/presentation", json={"on": True}, headers=headers
        )
        client.post(
            "/api/v1/devices/dev-ap-3/presentation",
            json={"auto": True},
            headers=headers,
        )
    finally:
        manager.unregister("dev-ap-3", agente)

    mensagens = agente.do_tipo("presentation")
    assert mensagens[0] == {"type": "presentation", "on": True}
    assert "auto" not in mensagens[0], "o botão não pode mexer no automático"
    assert mensagens[1] == {"type": "presentation", "auto": True}
    assert "on" not in mensagens[1], "a área de perfis não pode ligar o modo"


def test_corpo_vazio_e_recusado():
    """Uma mensagem que não muda nada chegaria ao computador, e o app receberia
    204 achando que mudou."""
    headers, uid = _auth("ap4@example.com")
    _add_device(uid, "dev-ap-4")
    resp = client.post(
        "/api/v1/devices/dev-ap-4/presentation", json={}, headers=headers
    )
    assert resp.status_code == 422


def test_computador_de_outra_conta_nao_e_alcancavel():
    dono, uid = _auth("ap5@example.com")
    _add_device(uid, "dev-ap-5")
    estranho, _ = _auth("ap6@example.com")
    assert (
        client.post(
            "/api/v1/devices/dev-ap-5/presentation",
            json={"on": True},
            headers=estranho,
        ).status_code
        == 404
    )
    assert (
        client.get("/api/v1/devices/dev-ap-5/presentation", headers=estranho).status_code
        == 404
    )
    # E o dono continua alcançando (503 porque não há agente, não 404).
    assert (
        client.get("/api/v1/devices/dev-ap-5/presentation", headers=dono).status_code
        == 503
    )


def test_sem_token_nao_passa():
    assert (
        client.post("/api/v1/devices/dev-ap-5/presentation", json={"on": True}).status_code
        == 401
    )
