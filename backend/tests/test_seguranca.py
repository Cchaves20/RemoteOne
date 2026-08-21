"""Os defeitos que a revisão de segurança encontrou, virados em teste.

Cada um destes testes **falha** no código anterior à revisão. É a única forma
de saber que o conserto conserta: um teste de segurança que passaria de
qualquer jeito não vigia nada.

Ver `docs/revisao-de-seguranca.md`.
"""

import importlib

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import SENHA, criar_conta

client = TestClient(app)


def _hello(device_id: str) -> dict:
    return {
        "type": "hello",
        "device_id": device_id,
        "hostname": "pc-da-vitima",
        "os": "windows",
        "agent_version": "0.1.0",
    }


def test_listagem_de_agentes_exige_login():
    """Sem token, a listagem não conta nada a ninguém.

    Era pública. Devolvia o `device_id` de todos os computadores conectados —
    e o `device_id` é a credencial do canal `/ws/agent`.
    """
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-da-vitima"))
        ws.receive_json()  # welcome
        ws.receive_json()  # pair_code

        resposta = client.get("/api/v1/agents")
        assert resposta.status_code in (401, 403), resposta.text
        assert "dev-da-vitima" not in resposta.text


def test_listagem_de_agentes_nao_mostra_computador_de_outra_conta():
    """Autenticar não basta: cada conta vê só o que é dela.

    Trocar "sem token" por "com qualquer token" moveria o problema em vez de
    resolvê-lo — bastaria criar uma conta grátis para ler os ids de todo mundo.
    """
    vitima = criar_conta(client, "vitima@example.com")["access_token"]
    bisbilhoteiro = criar_conta(client, "curioso@example.com")["access_token"]

    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-so-da-vitima"))
        ws.receive_json()
        intro = ws.receive_json()
        client.post(
            "/api/v1/pairing/claim",
            json={"code": intro["code"]},
            headers={"Authorization": f"Bearer {vitima}"},
        )

        do_dono = client.get(
            "/api/v1/agents", headers={"Authorization": f"Bearer {vitima}"}
        ).json()["agents"]
        assert any(a["device_id"] == "dev-so-da-vitima" for a in do_dono)

        do_outro = client.get(
            "/api/v1/agents", headers={"Authorization": f"Bearer {bisbilhoteiro}"}
        ).json()["agents"]
        assert do_outro == []


def test_segredo_publico_nunca_e_usado_para_assinar():
    """O padrão inseguro é recusado, e o servidor continua de pé.

    A versão anterior trazia `dev-insecure-secret-change-me` como padrão do
    `jwt_secret`. Esquecer a variável no `.env` de produção não quebrava nada
    visível — e passava a assinar tokens com uma senha escrita no repositório.
    """
    from app import config

    assert config._segredo_de_emergencia("") != ""
    assert config._segredo_de_emergencia("") != config._SEGREDO_ANTIGO
    assert config._segredo_de_emergencia(config._SEGREDO_ANTIGO) != config._SEGREDO_ANTIGO

    # Dois sorteios não coincidem: é sorteio, não uma segunda constante.
    assert config._segredo_de_emergencia("") != config._segredo_de_emergencia("")

    # E um segredo de verdade passa intacto.
    assert config._segredo_de_emergencia("um-segredo-de-verdade") == "um-segredo-de-verdade"


def test_segredo_ausente_nao_impede_o_servidor_de_subir():
    """Sortear em vez de recusar: o remédio não pode ser pior que a doença.

    Derrubar a subida por falta de variável trocaria um defeito silencioso por
    indisponibilidade total. O sorteio mantém o servidor no ar e transforma o
    esquecimento num sintoma que ninguém consegue ignorar — todo mundo cai a
    cada reinício.
    """
    modulo = importlib.import_module("app.config")
    assert modulo.settings.jwt_secret
    assert modulo.settings.jwt_secret != modulo._SEGREDO_ANTIGO
