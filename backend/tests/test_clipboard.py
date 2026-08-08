"""Área de transferência compartilhada.

Duas direções que **não** são simétricas: computador → telefone pode ser
automático (o Windows avisa quando alguém copia); telefone → computador é
sempre a pedido, porque o iOS mostra um aviso na tela toda vez que um app lê a
área de transferência.
"""

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager, viewers
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending

client = TestClient(app)


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


#: O que os campos de imagem valem quando não há imagem copiada. Fica separado
#: porque quase todo teste daqui é sobre texto ou arquivo, e repetir quatro
#: `None` em cada asserção esconderia o que cada teste está de fato medindo.
SEM_IMAGEM = {
    "image": None,
    "image_mime": None,
    "image_width": None,
    "image_height": None,
}


class InstantAgent:
    def __init__(
        self,
        text: str | None = None,
        files: list[dict] | None = None,
        ignored: int = 0,
        image: dict | None = None,
    ):
        self.text = text
        self.files = files or []
        self.ignored = ignored
        #: Os quatro campos da imagem, ou nada quando o agente não copiou uma.
        self.image = image or SEM_IMAGEM
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "clipboard_get" and self.text is not None:
            pending.resolve(
                message["request_id"],
                {
                    "text": self.text,
                    "files": self.files,
                    "ignored": self.ignored,
                    **self.image,
                },
            )

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_resposta_do_agente():
    message = parse_client_message(
        {"type": "clipboard", "request_id": "r1", "text": "olá"}
    )
    assert message.text == "olá"


def test_parse_aviso_de_copia_nova():
    message = parse_client_message({"type": "clipboard_changed", "text": "copiado"})
    assert message.text == "copiado"


def test_texto_gigante_e_recusado():
    """Copiar um log inteiro é comum; virar uma mensagem de megabytes no
    WebSocket, não. O agente já corta, e aqui é a segunda barreira."""
    try:
        parse_client_message(
            {"type": "clipboard_changed", "text": "a" * (64 * 1024 + 1)}
        )
    except ValueError:
        return
    raise AssertionError("texto acima do teto deveria ser recusado")


# --- endpoints ---------------------------------------------------------------


def test_traz_o_texto_do_computador():
    headers, uid = _auth_headers("clip1@example.com")
    _add_device(uid, "dev-clip-1")
    agent = InstantAgent("do computador")
    manager.register("dev-clip-1", agent)
    try:
        resp = client.get("/api/v1/devices/dev-clip-1/clipboard", headers=headers)
    finally:
        manager.unregister("dev-clip-1")
    assert resp.status_code == 200
    assert resp.json() == {
        "text": "do computador",
        "files": [],
        "ignored": 0,
        **SEM_IMAGEM,
    }


def test_manda_o_texto_ao_computador():
    headers, uid = _auth_headers("clip2@example.com")
    _add_device(uid, "dev-clip-2")
    agent = InstantAgent()
    manager.register("dev-clip-2", agent)
    try:
        resp = client.post(
            "/api/v1/devices/dev-clip-2/clipboard",
            json={"text": "do telefone"},
            headers=headers,
        )
    finally:
        manager.unregister("dev-clip-2")
    assert resp.status_code == 204
    assert agent.of_type("clipboard_set")[0]["text"] == "do telefone"


def test_liga_e_desliga_a_sincronia():
    headers, uid = _auth_headers("clip3@example.com")
    _add_device(uid, "dev-clip-3")
    agent = InstantAgent()
    manager.register("dev-clip-3", agent)
    try:
        for ligado in (True, False):
            resp = client.post(
                "/api/v1/devices/dev-clip-3/clipboard/sync",
                json={"enabled": ligado},
                headers=headers,
            )
            assert resp.status_code == 204, ligado
    finally:
        manager.unregister("dev-clip-3")
    assert [m["enabled"] for m in agent.of_type("clipboard_sync")] == [True, False]


def test_de_outra_conta_404():
    """O que passa pela área de transferência de alguém costuma incluir senha:
    só o dono lê."""
    _, dono = _auth_headers("clip4@example.com")
    _add_device(dono, "dev-clip-4")
    intruso, _ = _auth_headers("clip5@example.com")
    assert (
        client.get("/api/v1/devices/dev-clip-4/clipboard", headers=intruso).status_code
        == 404
    )
    assert (
        client.post(
            "/api/v1/devices/dev-clip-4/clipboard",
            json={"text": "x"},
            headers=intruso,
        ).status_code
        == 404
    )


def test_sem_token_401():
    assert client.get("/api/v1/devices/dev-clip-1/clipboard").status_code == 401


def test_com_agente_offline_503():
    headers, uid = _auth_headers("clip6@example.com")
    _add_device(uid, "dev-clip-6")
    assert (
        client.get("/api/v1/devices/dev-clip-6/clipboard", headers=headers).status_code
        == 503
    )


def test_aviso_sem_ninguem_olhando_nao_e_guardado():
    """Guardar o que alguém copiou para entregar depois seria guardar
    justamente o tipo de coisa que não se deve guardar."""
    assert viewers.notify("dev-sem-viewer", {"type": "clipboard", "text": "x"}) == 0


def test_agente_pode_avisar_sem_ninguem_esperando():
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(
            {
                "type": "hello",
                "device_id": "dev-clip-ws",
                "hostname": "pc",
                "os": "windows",
                "agent_version": "0.1.0",
            }
        )
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()  # pair_code
        ws.send_json({"type": "clipboard_changed", "text": "ninguém ouvindo"})
        ws.send_json({"type": "heartbeat"})
        assert ws.receive_json()["type"] == "ack"


def test_health_anuncia_o_recurso():
    assert "clipboard" in client.get("/health").json()["features"]


# --- arquivos copiados -------------------------------------------------------

ARQUIVO = {
    "name": "video.mp4",
    "path": "C:/Users/eu/Videos/video.mp4",
    "is_dir": False,
    "size": 12_345_678,
}


def test_traz_os_arquivos_copiados():
    """Copiar um vídeo no Explorer põe o **caminho** na área de transferência,
    não os bytes - é assim que "copiar vídeo" chega ao telefone."""
    headers, uid = _auth_headers("clip7@example.com")
    _add_device(uid, "dev-clip-7")
    manager.register("dev-clip-7", InstantAgent("", [ARQUIVO]))
    try:
        resp = client.get("/api/v1/devices/dev-clip-7/clipboard", headers=headers)
    finally:
        manager.unregister("dev-clip-7")
    assert resp.status_code == 200
    assert resp.json()["files"] == [ARQUIVO]


def test_parse_resposta_com_arquivos():
    message = parse_client_message(
        {"type": "clipboard", "request_id": "r1", "text": "", "files": [ARQUIVO]}
    )
    assert message.files[0].name == "video.mp4"
    assert message.files[0].size == 12_345_678


def test_resposta_de_agente_antigo_nao_quebra():
    """Agente sem a lista continua funcionando: o campo tem padrão."""
    message = parse_client_message(
        {"type": "clipboard", "request_id": "r1", "text": "só texto"}
    )
    assert message.files == []


def test_conta_os_arquivos_recusados():
    """Copiar de `D:\\` e copiar nada chegam iguais aqui - uma lista vazia -
    e são coisas diferentes para quem está olhando a tela. A contagem é o que
    permite ao app dizer qual dos dois aconteceu."""
    headers, uid = _auth_headers("clip8@example.com")
    _add_device(uid, "dev-clip-8")
    manager.register("dev-clip-8", InstantAgent("", [], ignored=3))
    try:
        resp = client.get("/api/v1/devices/dev-clip-8/clipboard", headers=headers)
    finally:
        manager.unregister("dev-clip-8")
    assert resp.status_code == 200
    assert resp.json() == {"text": "", "files": [], "ignored": 3, **SEM_IMAGEM}


def test_agente_antigo_nao_conta_recusados():
    """Sem o campo, zero é a leitura certa: o agente antigo não recusou nada
    que ele soubesse contar."""
    message = parse_client_message(
        {"type": "clipboard", "request_id": "r1", "text": "x"}
    )
    assert message.ignored == 0


def test_traz_a_imagem_copiada():
    """A imagem atravessa o backend com os bytes, e não com um caminho.

    É a diferença para os arquivos: copiar um vídeo no Explorer guarda o
    **caminho** dele, mas uma imagem copiada não existe em disco - ela só existe
    na área de transferência, e ou vêm os bytes ou não vem nada.

    O `response_model` do FastAPI descarta o que não estiver no schema, então
    sem este teste esquecer um campo no `ClipboardOut` some com a imagem inteira
    sem erro nenhum aparecer.
    """
    headers, uid = _auth_headers("clip9@example.com")
    _add_device(uid, "dev-clip-9")
    imagem = {
        "image": "aGVsbG8=",
        "image_mime": "image/png",
        "image_width": 800,
        "image_height": 600,
    }
    manager.register("dev-clip-9", InstantAgent("", [], image=imagem))
    try:
        resp = client.get("/api/v1/devices/dev-clip-9/clipboard", headers=headers)
    finally:
        manager.unregister("dev-clip-9")
    assert resp.status_code == 200
    assert resp.json() == {"text": "", "files": [], "ignored": 0, **imagem}


def test_agente_antigo_nao_manda_imagem():
    """Sem os campos, `None` - e o app simplesmente não mostra imagem nenhuma."""
    message = parse_client_message(
        {"type": "clipboard", "request_id": "r1", "text": "x"}
    )
    assert message.image is None
    assert message.image_mime is None
