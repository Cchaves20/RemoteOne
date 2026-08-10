"""Transferência de arquivos: listar, baixar e enviar.

O agente é um dublê que responde dentro do próprio envio, então os testes
passam pelo mesmo código que a produção usa — sem threads e sem rede.

O que mais importa aqui é o que **não** deve acontecer: pedaço fora de ordem
virando arquivo corrompido em silêncio, e o arquivo inteiro passando a existir
na memória do backend.
"""

import asyncio
import base64

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import app
from app.models import Device, User
from app.protocol import parse_client_message
from app.rpc import pending
from app.transfers import QUEUE_LIMIT, Download, TransferError, transfers
from conftest import criar_conta

client = TestClient(app)

LISTING = {
    "path": "/home/caio",
    "parent": None,
    "entries": [
        {"name": "Documentos", "path": "/home/caio/Documentos", "is_dir": True, "size": 0},
        {"name": "nota.txt", "path": "/home/caio/nota.txt", "is_dir": False, "size": 12},
    ],
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


class FileAgent:
    """Agente que atende os comandos de arquivo na hora.

    `content` é o arquivo que ele "tem" para entregar; `listing` é o que ele
    responde a um `list_files`. Deixar qualquer um como `None` simula a falha
    correspondente.
    """

    def __init__(
        self,
        listing: dict | None = None,
        error: str | None = None,
        content: bytes | None = None,
        chunk: int = 8,
        accept_upload: bool = True,
    ):
        self.listing = listing
        self.error = error
        self.content = content
        self.chunk = chunk
        self.accept_upload = accept_upload
        self.sent: list[dict] = []
        self.received = bytearray()
        self._tasks: list[asyncio.Task] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        kind = message.get("type")
        if kind == "list_files":
            pending.resolve(
                message["request_id"], {"listing": self.listing, "error": self.error}
            )
        elif kind == "read_file":
            # Numa tarefa à parte, e não aqui dentro: o agente de verdade é
            # outro processo, que segue lendo enquanto o backend responde.
            # Empurrar aqui travaria no quinto pedaço — a fila enche antes de
            # existir alguém consumindo, que é a contrapressão fazendo o
            # trabalho dela.
            self._tasks.append(
                asyncio.create_task(self._stream(message["transfer_id"]))
            )
        elif kind == "write_file_chunk":
            self.received.extend(base64.b64decode(message["data"]))
        elif kind == "write_file_end":
            pending.resolve(
                message["transfer_id"],
                {"ok": self.accept_upload, "detail": "C:\\destino\\arquivo.bin"}
                if self.accept_upload
                else {"ok": False, "detail": "disco cheio"},
            )

    async def _stream(self, transfer_id: str) -> None:
        download = transfers.get(transfer_id)
        if download is None:
            return
        if self.content is None:
            await download.finish(False, "não é um arquivo")
            return
        seq = 0
        for i in range(0, len(self.content), self.chunk):
            pedaco = self.content[i : i + self.chunk]
            await download.push(seq, base64.b64encode(pedaco).decode())
            seq += 1
        await download.finish(True, None)

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == kind]


# --- protocolo ---------------------------------------------------------------


def test_parse_file_list_com_conteudo_e_com_erro():
    ok = parse_client_message(
        {"type": "file_list", "request_id": "r1", "listing": LISTING}
    )
    assert ok.listing is not None
    assert ok.listing.entries[0].is_dir is True
    assert ok.error is None

    falhou = parse_client_message(
        {"type": "file_list", "request_id": "r1", "error": "fora da pasta do usuário"}
    )
    assert falhou.listing is None
    assert falhou.error == "fora da pasta do usuário"


def test_parse_file_chunk_recusa_sequencia_negativa():
    try:
        parse_client_message(
            {"type": "file_chunk", "transfer_id": "t1", "seq": -1, "data": "AA=="}
        )
    except ValueError:
        return
    raise AssertionError("sequência negativa deveria ser rejeitada")


# --- fila de download --------------------------------------------------------


def test_fila_rejeita_pedaco_fora_de_ordem():
    """A falha que mais importa: montar um arquivo errado sem avisar ninguém."""

    async def cenario():
        download = Download()
        await download.push(0, base64.b64encode(b"aa").decode())
        await download.push(2, base64.b64encode(b"cc").decode())  # pulou o 1
        assert await download.chunks.get() == b"aa"
        erro = await download.chunks.get()
        assert isinstance(erro, TransferError)

    asyncio.run(cenario())


def test_fila_segura_o_agente_quando_o_celular_nao_consome():
    """A contrapressão: sem ela, um arquivo de 100 MB viraria 100 MB de RAM."""

    async def cenario():
        download = Download()
        for i in range(QUEUE_LIMIT):
            await download.push(i, base64.b64encode(b"x").decode())
        assert download.chunks.full()
        # O próximo `push` não completa enquanto ninguém tirar da fila.
        empurrando = asyncio.create_task(
            download.push(QUEUE_LIMIT, base64.b64encode(b"y").decode())
        )
        await asyncio.sleep(0)
        assert not empurrando.done(), "deveria estar esperando espaço"
        await download.chunks.get()
        await asyncio.wait_for(empurrando, timeout=1)

    asyncio.run(cenario())


# --- listar ------------------------------------------------------------------


def test_lista_a_pasta_do_computador():
    headers, uid = _auth_headers("arq1@example.com")
    _add_device(uid, "dev-arq-1")
    agent = FileAgent(listing=LISTING)
    manager.register("dev-arq-1", agent)
    try:
        resp = client.get("/api/v1/devices/dev-arq-1/files", headers=headers)
    finally:
        manager.unregister("dev-arq-1")
    assert resp.status_code == 200
    corpo = resp.json()
    assert [e["name"] for e in corpo["entries"]] == ["Documentos", "nota.txt"]
    assert corpo["parent"] is None
    # Caminho vazio = a pasta do usuário; é assim que a tela abre.
    assert agent.of_type("list_files")[0]["path"] == ""


def test_lista_com_erro_do_agente_vira_400():
    """Sem permissão não pode chegar ao app como pasta vazia."""
    headers, uid = _auth_headers("arq2@example.com")
    _add_device(uid, "dev-arq-2")
    manager.register("dev-arq-2", FileAgent(error="fora da pasta do usuário"))
    try:
        resp = client.get(
            "/api/v1/devices/dev-arq-2/files?path=/etc", headers=headers
        )
    finally:
        manager.unregister("dev-arq-2")
    assert resp.status_code == 400
    assert "fora da pasta" in resp.json()["detail"]


def test_lista_com_agente_offline_503():
    headers, uid = _auth_headers("arq3@example.com")
    _add_device(uid, "dev-arq-3")
    resp = client.get("/api/v1/devices/dev-arq-3/files", headers=headers)
    assert resp.status_code == 503


def test_lista_de_outra_conta_404():
    _, dono = _auth_headers("arq4@example.com")
    _add_device(dono, "dev-arq-4")
    intruso, _ = _auth_headers("arq5@example.com")
    resp = client.get("/api/v1/devices/dev-arq-4/files", headers=intruso)
    assert resp.status_code == 404


# --- baixar ------------------------------------------------------------------


def test_baixa_o_arquivo_em_pedacos_e_remonta_igual():
    headers, uid = _auth_headers("arq6@example.com")
    _add_device(uid, "dev-arq-6")
    conteudo = bytes(range(256)) * 4  # 1 KB, vários pedaços
    manager.register("dev-arq-6", FileAgent(content=conteudo, chunk=8))
    try:
        resp = client.get(
            "/api/v1/devices/dev-arq-6/files/download?path=/home/caio/dados.bin",
            headers=headers,
        )
    finally:
        manager.unregister("dev-arq-6")
    assert resp.status_code == 200
    assert resp.content == conteudo
    assert 'filename="dados.bin"' in resp.headers["content-disposition"]


def test_baixar_arquivo_inexistente_encerra_sem_corpo():
    """O 200 já saiu quando a falha aparece: o corpo vazio é o sinal."""
    headers, uid = _auth_headers("arq7@example.com")
    _add_device(uid, "dev-arq-7")
    manager.register("dev-arq-7", FileAgent(content=None))
    try:
        resp = client.get(
            "/api/v1/devices/dev-arq-7/files/download?path=/home/caio/sumiu.bin",
            headers=headers,
        )
    finally:
        manager.unregister("dev-arq-7")
    assert resp.content == b""


def test_download_avisa_o_computador_para_parar_de_ler():
    """Sem o cancelamento, o computador seguiria bombeando um arquivo que
    ninguém mais quer."""
    headers, uid = _auth_headers("arq8@example.com")
    _add_device(uid, "dev-arq-8")
    agent = FileAgent(content=b"conteudo qualquer", chunk=4)
    manager.register("dev-arq-8", agent)
    try:
        client.get(
            "/api/v1/devices/dev-arq-8/files/download?path=/home/caio/a.bin",
            headers=headers,
        )
    finally:
        manager.unregister("dev-arq-8")
    assert agent.of_type("cancel_transfer"), "o agente precisa ser avisado"


def test_download_nao_deixa_transferencia_pendurada():
    headers, uid = _auth_headers("arq9@example.com")
    _add_device(uid, "dev-arq-9")
    manager.register("dev-arq-9", FileAgent(content=b"x" * 64, chunk=16))
    antes = transfers.count()
    try:
        client.get(
            "/api/v1/devices/dev-arq-9/files/download?path=/home/caio/a.bin",
            headers=headers,
        )
    finally:
        manager.unregister("dev-arq-9")
    assert transfers.count() == antes


# --- enviar ------------------------------------------------------------------


def test_envia_o_arquivo_ao_computador_em_pedacos():
    headers, uid = _auth_headers("arq10@example.com")
    _add_device(uid, "dev-arq-10")
    agent = FileAgent()
    manager.register("dev-arq-10", agent)
    conteudo = bytes(range(200)) * 500  # 100 KB: mais de um pedaço
    try:
        resp = client.post(
            "/api/v1/devices/dev-arq-10/files/upload?name=foto.png",
            headers=headers,
            content=conteudo,
        )
    finally:
        manager.unregister("dev-arq-10")
    assert resp.status_code == 200
    assert resp.json()["bytes"] == len(conteudo)
    assert bytes(agent.received) == conteudo, "o computador recebeu outra coisa"

    # Começo, pedaços numerados em ordem, e fim.
    assert agent.of_type("write_file_begin")[0]["name"] == "foto.png"
    seqs = [m["seq"] for m in agent.of_type("write_file_chunk")]
    assert seqs == list(range(len(seqs)))
    assert len(seqs) > 1, "100 KB tem de virar mais de um pedaço"
    assert agent.of_type("write_file_end")


def test_envio_recusado_pelo_computador_vira_502():
    headers, uid = _auth_headers("arq11@example.com")
    _add_device(uid, "dev-arq-11")
    manager.register("dev-arq-11", FileAgent(accept_upload=False))
    try:
        resp = client.post(
            "/api/v1/devices/dev-arq-11/files/upload?name=x.bin",
            headers=headers,
            content=b"dados",
        )
    finally:
        manager.unregister("dev-arq-11")
    assert resp.status_code == 502
    assert resp.json()["detail"] == "disco cheio"


def test_envio_com_agente_offline_503():
    headers, uid = _auth_headers("arq12@example.com")
    _add_device(uid, "dev-arq-12")
    resp = client.post(
        "/api/v1/devices/dev-arq-12/files/upload?name=x.bin",
        headers=headers,
        content=b"dados",
    )
    assert resp.status_code == 503


def test_envio_grande_demais_e_recusado_antes_de_comecar():
    headers, uid = _auth_headers("arq13@example.com")
    _add_device(uid, "dev-arq-13")
    agent = FileAgent()
    manager.register("dev-arq-13", agent)
    try:
        # Anuncia mais que o limite sem mandar os bytes: a recusa vem do
        # Content-Length, antes de gastar rede.
        resp = client.post(
            "/api/v1/devices/dev-arq-13/files/upload?name=enorme.bin",
            headers={**headers, "Content-Length": str(200 * 1024 * 1024)},
            content=b"",
        )
    finally:
        manager.unregister("dev-arq-13")
    assert resp.status_code == 413
    assert not agent.sent, "nem chegou a incomodar o computador"


def test_envio_de_outra_conta_404():
    _, dono = _auth_headers("arq14@example.com")
    _add_device(dono, "dev-arq-14")
    intruso, _ = _auth_headers("arq15@example.com")
    resp = client.post(
        "/api/v1/devices/dev-arq-14/files/upload?name=x.bin",
        headers=intruso,
        content=b"dados",
    )
    assert resp.status_code == 404


def test_health_anuncia_transferencia_de_arquivos():
    assert "file-transfer" in client.get("/health").json()["features"]


def test_listagem_da_raiz_carrega_os_atalhos():
    """As pastas conhecidas (Área de Trabalho, Downloads...) vêm junto com a
    listagem da raiz - uma chamada só, em vez de duas ao abrir a tela."""
    from app.protocol import parse_client_message

    message = parse_client_message(
        {
            "type": "file_list",
            "request_id": "r1",
            "listing": {
                "path": "C:/Users/eu",
                "entries": [],
                "shortcuts": [
                    {
                        "name": "Área de Trabalho",
                        "path": "C:/Users/eu/OneDrive/Área de Trabalho",
                        "is_dir": True,
                        "size": 0,
                    }
                ],
            },
        }
    )
    assert message.listing.shortcuts[0].name == "Área de Trabalho"
    # O caminho real passa pelo OneDrive: montar na mão erraria.
    assert "OneDrive" in message.listing.shortcuts[0].path


def test_agente_antigo_sem_atalhos_continua_valendo():
    from app.protocol import parse_client_message

    message = parse_client_message(
        {
            "type": "file_list",
            "request_id": "r1",
            "listing": {"path": "C:/Users/eu", "entries": []},
        }
    )
    assert message.listing.shortcuts == []
