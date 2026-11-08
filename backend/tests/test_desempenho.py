"""Desempenho: o cronômetro de requisições lentas e o índice da lista de computadores."""

import logging

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import inspect, text

from app import cronometro
from app import db as banco
from app.db import engine
from app.main import app

client = TestClient(app)


def test_requisicao_lenta_vai_ao_diario_com_o_molde_da_rota(monkeypatch, caplog):
    tokens = criar_conta(client, email="lento@example.com")
    cab = {"Authorization": f"Bearer {tokens['access_token']}"}
    monkeypatch.setattr(cronometro, "LIMIAR_MS", 0)
    with caplog.at_level(logging.WARNING, logger="deskside.lento"):
        client.get("/api/v1/devices/computador-secreto/files", headers=cab)
    linhas = [r.getMessage() for r in caplog.records if r.name == "deskside.lento"]
    assert any("GET /api/v1/devices/{device_id}/files 404" in linha for linha in linhas), linhas
    # O identificador pedido não entra no diário.
    assert not any("computador-secreto" in linha for linha in linhas)


def test_requisicao_rapida_nao_vai_ao_diario(caplog):
    with caplog.at_level(logging.WARNING, logger="deskside.lento"):
        assert client.get("/health").status_code == 200
    assert not [r for r in caplog.records if r.name == "deskside.lento"]


def test_transferencia_de_arquivo_nao_conta_como_lenta(monkeypatch, caplog):
    tokens = criar_conta(client, email="baixa@example.com")
    cab = {"Authorization": f"Bearer {tokens['access_token']}"}
    monkeypatch.setattr(cronometro, "LIMIAR_MS", 0)
    with caplog.at_level(logging.WARNING, logger="deskside.lento"):
        client.get("/api/v1/devices/x/files/download?path=a", headers=cab)
    assert not [r for r in caplog.records if r.name == "deskside.lento"]


def test_rota_inexistente_nao_poe_o_endereco_no_diario(monkeypatch, caplog):
    monkeypatch.setattr(cronometro, "LIMIAR_MS", 0)
    with caplog.at_level(logging.WARNING, logger="deskside.lento"):
        client.get("/nao-existe/dado-qualquer")
    linhas = [r.getMessage() for r in caplog.records if r.name == "deskside.lento"]
    assert linhas and all("dado-qualquer" not in linha for linha in linhas)


def test_lista_de_computadores_tem_indice_na_conta():
    nomes = {i["name"] for i in inspect(engine).get_indexes("devices")}
    assert "ix_devices_user_id" in nomes


def test_banco_antigo_ganha_o_indice_na_subida():
    with engine.begin() as conn:
        conn.execute(text("DROP INDEX IF EXISTS ix_devices_user_id"))
    assert "ix_devices_user_id" not in {i["name"] for i in inspect(engine).get_indexes("devices")}
    banco._criar_indices()
    banco._criar_indices()  # de novo: não pode falhar
    assert "ix_devices_user_id" in {i["name"] for i in inspect(engine).get_indexes("devices")}
