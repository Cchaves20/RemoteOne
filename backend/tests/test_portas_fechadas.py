"""O que fica fechado para quem não se identificou.

Dois achados da auditoria de segurança de novembro de 2026: a documentação da
API publicada em produção, e o canal da tela sem prazo para a primeira
mensagem.
"""

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import app.main as principal
from app.main import app

client = TestClient(app)


@pytest.mark.parametrize("caminho", ["/docs", "/redoc", "/openapi.json"])
def test_a_documentacao_da_api_nao_e_publicada(caminho):
    """O mapa da API inteira é o roteiro de quem procura a rota esquecida sem
    conferência. Só liga com `DESKSIDE_DOCS_PUBLICAS=true`."""
    assert client.get(caminho).status_code == 404


def test_o_esquema_continua_disponivel_dentro_do_processo():
    """Os testes (e quem precisar gerar cliente) ainda leem o esquema."""
    assert "/api/v1/devices" in app.openapi()["paths"]


def test_quem_conecta_na_tela_e_nao_se_identifica_e_desligado(monkeypatch):
    """Sem prazo, conexões mudas ficavam abertas para sempre, cada uma com
    memória e uma tarefa do servidor - sem conta e sem token."""
    monkeypatch.setattr(principal, "PRAZO_DA_IDENTIFICACAO", 0.2)
    with client.websocket_connect("/ws/viewer/qualquer") as tela:
        with pytest.raises(WebSocketDisconnect) as fechou:
            tela.receive_text()
    assert fechou.value.code == 4401


def test_primeira_mensagem_que_nao_e_objeto_e_recusada():
    with client.websocket_connect("/ws/viewer/qualquer") as tela:
        tela.send_text("[1, 2, 3]")
        with pytest.raises(WebSocketDisconnect) as fechou:
            tela.receive_text()
    assert fechou.value.code == 4401
