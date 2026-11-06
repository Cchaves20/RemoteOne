"""Nenhuma rota com identificador no caminho atende a conta errada.

## Por que um teste que percorre todas as rotas

O banco não tem RLS (é SQLite, e o servidor fala com ele como um usuário só):
quem garante que uma conta não lê nem mexe no que é de outra é o código de
cada rota. Os testes de cada arquivo conferem as rotas que já existem; o
problema é a rota **nova**, que nasce sem a conferência e ninguém percebe.

Este teste pega a lista de rotas da própria aplicação. Toda rota com
`{device_id}`, `{profile_id}`, `{automation_id}` ou `{sessao_id}` no caminho
é chamada pela conta B com os identificadores da conta A, e precisa responder
404 - o mesmo de "não existe", para não dizer a um estranho quais
identificadores existem. Uma rota nova entra aqui sozinha; se ela tiver um
parâmetro de caminho que o teste não conhece, ele falha pedindo para ser
ensinado, em vez de pular a rota em silêncio.

## O corpo das requisições

Para o 404 provar alguma coisa, a requisição precisa chegar à conferência de
dono. Uma rota que confere o dono **dentro** da função recusa um corpo
inválido antes, com 422, e o 422 não diz nada sobre o dono. Por isso o corpo é
montado a partir do próprio esquema da rota, e `CORPOS` guarda os casos que o
gerador não acerta sozinho.
"""

from __future__ import annotations

import re

import pytest
from conftest import criar_conta
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import SessionLocal
from app.main import app
from app.models import Device, Sessao, User

client = TestClient(app)

PARAMETROS_CONHECIDOS = {"device_id", "profile_id", "automation_id", "sessao_id"}

#: Corpos que o gerador não monta válidos sozinho (validações além do tipo).
#: Chave: (método, caminho).
CORPOS: dict[tuple[str, str], dict] = {
    ("PUT", "/api/v1/automations/{automation_id}"): {
        "name": "x",
        "steps": [{"kind": "close_all"}],
    },
    ("PUT", "/api/v1/profiles/{profile_id}"): {"name": "x", "apps": []},
    ("PATCH", "/api/v1/devices/{device_id}"): {"name": "x"},
    ("POST", "/api/v1/devices/{device_id}/presentation"): {"on": False},
}

#: Rotas com parâmetro no caminho que não pertencem a conta nenhuma, e por quê.
SEM_DONO = {
    # Quem chama é a Apple ou o Google; a garantia é a assinatura do corpo
    # (`app/lojas.py`), e `{loja}` é "apple" ou "google".
    ("POST", "/webhooks/{loja}"),
}

#: Parâmetros de consulta obrigatórios, quando o gerador não basta.
CONSULTAS: dict[tuple[str, str], dict] = {
    ("GET", "/api/v1/devices/{device_id}/files"): {"path": "C:\\"},
    ("GET", "/api/v1/devices/{device_id}/files/download"): {"path": "C:\\a.txt"},
}


def _rotas() -> list[tuple[str, str, APIRoute]]:
    def andar(rotas):
        for r in rotas:
            if isinstance(r, APIRoute):
                yield r
            # `original_router` é onde o FastAPI novo guarda as rotas de um
            # `include_router`; os outros dois nomes, as versões anteriores.
            for nome in ("original_router", "router", "_router"):
                interno = getattr(r, nome, None)
                if interno is not None and hasattr(interno, "routes"):
                    yield from andar(interno.routes)

    vistas: set[tuple[str, str]] = set()
    saida = []
    for rota in andar(app.routes):
        if "{" not in rota.path:
            continue
        for metodo in sorted(rota.methods - {"HEAD", "OPTIONS"}):
            if (metodo, rota.path) in vistas or (metodo, rota.path) in SEM_DONO:
                continue
            vistas.add((metodo, rota.path))
            saida.append((metodo, rota.path, rota))
    return saida


ROTAS = _rotas()


def _exemplo(esquema: dict, definicoes: dict) -> object:
    """Um valor que passa pela validação de tipo do esquema JSON."""
    if "$ref" in esquema:
        return _exemplo(definicoes[esquema["$ref"].split("/")[-1]], definicoes)
    for chave in ("anyOf", "oneOf"):
        if chave in esquema:
            opcoes = [o for o in esquema[chave] if o.get("type") != "null"]
            return _exemplo(opcoes[0], definicoes) if opcoes else None
    if "enum" in esquema:
        return esquema["enum"][0]
    if "const" in esquema:
        return esquema["const"]
    tipo = esquema.get("type")
    if tipo == "object":
        return {
            nome: _exemplo(sub, definicoes)
            for nome, sub in esquema.get("properties", {}).items()
            if nome in esquema.get("required", [])
        }
    if tipo == "array":
        return []
    if tipo == "integer":
        return max(1, esquema.get("minimum", 1))
    if tipo == "number":
        return max(1, esquema.get("minimum", 1))
    if tipo == "boolean":
        return False
    return "x" * max(1, esquema.get("minLength", 1))


def _corpo(metodo: str, caminho: str, rota: APIRoute) -> dict | None:
    if (metodo, caminho) in CORPOS:
        return CORPOS[(metodo, caminho)]
    # O esquema sai do OpenAPI da própria aplicação: é a descrição pública da
    # rota, e não depende de detalhes internos do FastAPI que mudam de versão.
    openapi = app.openapi()
    operacao = openapi["paths"][caminho][metodo.lower()]
    conteudo = operacao.get("requestBody", {}).get("content", {})
    if "application/json" not in conteudo:
        return None
    definicoes = openapi.get("components", {}).get("schemas", {})
    return _exemplo(conteudo["application/json"]["schema"], definicoes)


def _consulta(metodo: str, caminho: str, rota: APIRoute) -> dict:
    if (metodo, caminho) in CONSULTAS:
        return CONSULTAS[(metodo, caminho)]
    return {p.name: "x" for p in rota.dependant.query_params if p.field_info.is_required()}


@pytest.fixture
def duas_contas():
    """A conta A com um de cada recurso; a conta B, só com o login."""
    a = criar_conta(client, email="dona@example.com")
    b = criar_conta(client, email="estranha@example.com")
    cab_a = {"Authorization": f"Bearer {a['access_token']}"}
    cab_b = {"Authorization": f"Bearer {b['access_token']}"}

    with SessionLocal() as db:
        uid_a = db.scalar(select(User.id).where(User.email == "dona@example.com"))
        db.add(
            Device(device_id="dev-da-dona", user_id=uid_a, name="pc", os="windows", hostname="pc")
        )
        db.commit()
        sessao_a = db.scalar(select(Sessao.id).where(Sessao.user_id == uid_a))

    perfil = client.post("/api/v1/profiles", json={"name": "da dona", "apps": []}, headers=cab_a)
    assert perfil.status_code == 201, perfil.text
    automacao = client.post(
        "/api/v1/automations",
        json={"name": "da dona", "steps": [{"kind": "close_all"}], "device_id": "dev-da-dona"},
        headers=cab_a,
    )
    assert automacao.status_code in (200, 201), automacao.text

    ids = {
        "device_id": "dev-da-dona",
        "profile_id": perfil.json()["id"],
        "automation_id": automacao.json()["id"],
        "sessao_id": sessao_a,
    }
    return cab_b, ids


def test_as_rotas_com_identificador_existem():
    """Se a busca de rotas quebrar (uma mudança no FastAPI, por exemplo), o
    teste abaixo passaria sem testar nada. Este garante que ele tem o que
    percorrer."""
    assert len(ROTAS) >= 30


@pytest.mark.parametrize(
    ("metodo", "caminho", "rota"), ROTAS, ids=[f"{m} {c}" for m, c, _ in ROTAS]
)
def test_outra_conta_recebe_404(metodo, caminho, rota, duas_contas):
    cab_b, ids = duas_contas
    nomes = set(re.findall(r"{(\w+)}", caminho))
    desconhecidos = nomes - PARAMETROS_CONHECIDOS
    assert not desconhecidos, (
        f"{metodo} {caminho} tem parâmetro novo {desconhecidos}: ensine a "
        "fixture `duas_contas` a criar um desses na conta A."
    )

    url = caminho.format(**{n: ids[n] for n in nomes})
    corpo = _corpo(metodo, caminho, rota)
    if any(p.name == "file" for p in rota.dependant.body_params):
        resp = client.request(
            metodo,
            url,
            headers=cab_b,
            files={"file": ("a.txt", b"x")},
            params=_consulta(metodo, caminho, rota),
        )
    else:
        resp = client.request(
            metodo, url, headers=cab_b, json=corpo, params=_consulta(metodo, caminho, rota)
        )

    assert resp.status_code == 404, (
        f"{metodo} {caminho} respondeu {resp.status_code} para outra conta: {resp.text[:300]}"
    )
