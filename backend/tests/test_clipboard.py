"""Área de transferência compartilhada.

Duas direções que **não** são simétricas: computador → telefone pode ser
automático (o Windows avisa quando alguém copia); telefone → computador é
sempre a pedido, porque o iOS mostra um aviso na tela toda vez que um app lê a
área de transferência.
"""

import base64

from conftest import criar_conta
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
        erro_da_imagem: str | None = None,
        responde_imagem: bool = True,
    ):
        self.text = text
        self.files = files or []
        self.ignored = ignored
        #: Os quatro campos da imagem, ou nada quando o agente não copiou uma.
        self.image = image or SEM_IMAGEM
        self.erro_da_imagem = erro_da_imagem
        self.responde_imagem = responde_imagem
        self.sent: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message.get("type") == "clipboard_set_image" and self.responde_imagem:
            pending.resolve(message["request_id"], {"error": self.erro_da_imagem})
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


# --- imagem do celular para o computador -------------------------------------

#: Um PNG de 1x1 de verdade: o servidor não decodifica, mas repassa os bytes
#: exatos, e é isso que se confere.
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def _enviar_imagem(dispositivo: str, headers: dict, corpo: bytes):
    return client.post(
        f"/api/v1/devices/{dispositivo}/clipboard/image",
        content=corpo,
        headers={**headers, "Content-Type": "image/png"},
    )


def test_manda_a_imagem_ao_computador_com_os_bytes_exatos():
    headers, uid = _auth_headers("clipimg1@example.com")
    _add_device(uid, "dev-clipimg-1")
    agent = InstantAgent()
    manager.register("dev-clipimg-1", agent)
    try:
        resp = _enviar_imagem("dev-clipimg-1", headers, PNG_1X1)
    finally:
        manager.unregister("dev-clipimg-1")
    assert resp.status_code == 204, resp.text
    enviada = agent.of_type("clipboard_set_image")[0]["image"]
    assert base64.b64decode(enviada) == PNG_1X1


def test_recusa_do_computador_chega_com_o_motivo():
    headers, uid = _auth_headers("clipimg2@example.com")
    _add_device(uid, "dev-clipimg-2")
    motivo = "a imagem chegou num formato que o computador não lê"
    manager.register("dev-clipimg-2", InstantAgent(erro_da_imagem=motivo))
    try:
        resp = _enviar_imagem("dev-clipimg-2", headers, b"nao e imagem")
    finally:
        manager.unregister("dev-clipimg-2")
    assert resp.status_code == 400
    assert resp.json()["detail"] == motivo


def test_imagem_grande_demais_nao_chega_ao_computador():
    from app.devices import MAX_CLIPBOARD_IMAGE_BYTES

    headers, uid = _auth_headers("clipimg3@example.com")
    _add_device(uid, "dev-clipimg-3")
    agent = InstantAgent()
    manager.register("dev-clipimg-3", agent)
    try:
        resp = _enviar_imagem(
            "dev-clipimg-3", headers, b"\0" * (MAX_CLIPBOARD_IMAGE_BYTES + 1)
        )
    finally:
        manager.unregister("dev-clipimg-3")
    assert resp.status_code == 413
    assert agent.of_type("clipboard_set_image") == []


def test_corpo_vazio_e_recusado():
    headers, uid = _auth_headers("clipimg4@example.com")
    _add_device(uid, "dev-clipimg-4")
    manager.register("dev-clipimg-4", InstantAgent())
    try:
        resp = _enviar_imagem("dev-clipimg-4", headers, b"")
    finally:
        manager.unregister("dev-clipimg-4")
    assert resp.status_code == 400


def test_imagem_para_computador_de_outra_conta_404():
    _, dono = _auth_headers("clipimg5@example.com")
    _add_device(dono, "dev-clipimg-5")
    intruso, _ = _auth_headers("clipimg6@example.com")
    agent = InstantAgent()
    manager.register("dev-clipimg-5", agent)
    try:
        resp = _enviar_imagem("dev-clipimg-5", intruso, PNG_1X1)
    finally:
        manager.unregister("dev-clipimg-5")
    assert resp.status_code == 404
    assert agent.of_type("clipboard_set_image") == []


def test_imagem_com_agente_offline_503():
    headers, uid = _auth_headers("clipimg7@example.com")
    _add_device(uid, "dev-clipimg-7")
    assert _enviar_imagem("dev-clipimg-7", headers, PNG_1X1).status_code == 503


def test_agente_antigo_que_nao_responde_vira_504_explicado(monkeypatch):
    from app import devices

    monkeypatch.setattr(devices, "_CLIPBOARD_IMAGE_TIMEOUT_SECONDS", 0.05)
    headers, uid = _auth_headers("clipimg8@example.com")
    _add_device(uid, "dev-clipimg-8")
    manager.register("dev-clipimg-8", InstantAgent(responde_imagem=False))
    try:
        resp = _enviar_imagem("dev-clipimg-8", headers, PNG_1X1)
    finally:
        manager.unregister("dev-clipimg-8")
    assert resp.status_code == 504
    assert "atualize" in resp.json()["detail"]


def test_parse_resposta_da_imagem():
    ok = parse_client_message({"type": "clipboard_image_set", "request_id": "r1"})
    assert ok.error is None
    falhou = parse_client_message(
        {"type": "clipboard_image_set", "request_id": "r1", "error": "x"}
    )
    assert falhou.error == "x"
