"""Quem pergunta algo ao computador não segura conexão do banco esperando.

O teste de carga achou o servidor inteiro travado com 40 celulares em uso:
cada pergunta ao computador segurava uma conexão do estoque (5 + 10) enquanto
esperava a resposta, o estoque acabava, e a próxima consulta do laço principal
parava tudo — inclusive quem recebe as respostas dos computadores. Ver
`app.db.liberar` e `docs/teste-de-carga.md`.

O dublê anota quantas conexões estavam emprestadas **no instante** em que o
pedido chegou ao computador: é o meio da espera, e ali tem de ser zero.
"""

import pytest
from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import event, select

from app.connections import manager
from app.db import SessionLocal, engine
from app.main import app
from app.models import Device, User
from app.rpc import pending

client = TestClient(app)

RESPOSTAS = {
    "system_info": {
        "cpu_percent": 1.0, "memory_used": 1, "memory_total": 2,
        "disk_used": 1, "disk_total": 2, "disk_name": "C:", "uptime_seconds": 1,
    },
    "foreground_info": {"app": None},
    "list_apps": [],
}


class Emprestimos:
    """Conexões emprestadas agora, contadas pelos eventos do próprio estoque.

    Pelos eventos, e não por `engine.pool.checkedout()`: no SQLite não há
    estoque com limite (ver `app.db`), e o contador só existe no outro.
    """

    def __init__(self) -> None:
        self.agora = 0

    def __enter__(self) -> "Emprestimos":
        event.listen(engine, "checkout", self._saiu)
        event.listen(engine, "checkin", self._voltou)
        return self

    def __exit__(self, *_exc) -> None:
        event.remove(engine, "checkout", self._saiu)
        event.remove(engine, "checkin", self._voltou)

    def _saiu(self, *_args) -> None:
        self.agora += 1

    def _voltou(self, *_args) -> None:
        self.agora -= 1


class AgenteQueConta:
    """Responde na hora e anota as conexões emprestadas ao receber o pedido."""

    def __init__(self, emprestimos: Emprestimos) -> None:
        self.emprestimos = emprestimos
        self.emprestadas: list[int] = []

    async def send_json(self, message: dict) -> None:
        if message.get("type") in RESPOSTAS:
            self.emprestadas.append(self.emprestimos.agora)
            pending.resolve(message["request_id"], RESPOSTAS[message["type"]])


@pytest.mark.parametrize(
    "caminho",
    ["system", "foreground", "apps?kind=running"],
)
def test_pergunta_ao_computador_nao_segura_conexao(caminho):
    tokens = criar_conta(client, email="estoque@example.com")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == "estoque@example.com"))
        db.add(Device(device_id="pc-estoque", user_id=uid, name="pc",
                      os="windows", hostname="pc"))
        db.commit()

    with Emprestimos() as emprestimos:
        agente = AgenteQueConta(emprestimos)
        manager.register("pc-estoque", agente)
        try:
            resp = client.get(f"/api/v1/devices/pc-estoque/{caminho}", headers=headers)
        finally:
            manager.unregister("pc-estoque")

    assert resp.status_code == 200, resp.text
    assert agente.emprestadas == [0]
