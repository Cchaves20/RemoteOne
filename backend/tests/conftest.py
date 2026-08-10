"""Configuração de testes.

Define o banco como SQLite (num arquivo temporário) e um segredo JWT fixo
ANTES de importar o app, de modo que toda a suíte rode sem PostgreSQL. A
fixture autouse recria as tabelas a cada teste, garantindo isolamento.
"""

import os

os.environ.setdefault("DESKSIDE_DATABASE_URL", "sqlite:///./test_deskside.db")
os.environ.setdefault("DESKSIDE_JWT_SECRET", "test-secret")

import pytest  # noqa: E402

from app import entrega  # noqa: E402
from app.db import Base, engine  # noqa: E402

#: A senha que a suíte inteira usa. Cumpre as cinco regras da política — sem o
#: `!` no fim, todo teste que cria conta falharia por senha fraca, e a mensagem
#: apontaria para o teste em vez de para o que ele queria exercitar.
SENHA = "senhaSegura123!"


class EntregadorEspiao(entrega.Entregador):
    """Guarda o que teria sido enviado, em vez de enviar.

    É o que permite testar o cadastro **inteiro** — inclusive digitar o código
    certo — sem provedor nenhum. Um teste que pulasse a verificação (criando o
    usuário direto no banco) deixaria de exercitar justamente a parte nova.
    """

    def __init__(self) -> None:
        self.enviados: list[tuple[str, str, str]] = []

    def email(self, destino: str, codigo: str) -> None:
        self.enviados.append(("email", destino, codigo))

    def sms(self, destino: str, codigo: str) -> None:
        self.enviados.append(("sms", destino, codigo))

    def ultimo_codigo(self, destino: str | None = None) -> str:
        for canal, alvo, codigo in reversed(self.enviados):  # noqa: B007
            if destino is None or alvo == destino:
                return codigo
        raise AssertionError(f"nenhum código enviado para {destino!r}")


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture(autouse=True)
def espiao(monkeypatch):
    """Troca o entregador real pelo espião durante todo teste.

    `autouse` porque o risco de esquecer é assimétrico: sem a troca, um teste
    que cadastra tentaria abrir conexão SMTP de verdade — e, num servidor com
    credenciais no ambiente, mandaria e-mail de verdade a partir da suíte.
    """
    falso = EntregadorEspiao()
    monkeypatch.setattr(entrega, "entregador", falso)
    return falso


def criar_conta(
    client,
    email: str | None = None,
    phone: str | None = None,
    country: str | None = None,
    password: str = SENHA,
    espiao: EntregadorEspiao | None = None,
    **extras,
) -> dict:
    """Cria uma conta pelo fluxo real (duas etapas) e devolve os tokens.

    Existe porque o cadastro passou a ter duas etapas e **não há atalho**: não
    há endpoint que crie conta sem verificar, de propósito. Em vez de cada
    arquivo de teste repetir as duas chamadas, repete-se aqui uma vez — e de
    quebra todo teste da suíte passa a exercitar o caminho de verdade.
    """
    corpo = {
        "first_name": extras.get("first_name", "Caio"),
        "last_name": extras.get("last_name", "Chaves"),
        "birth_date": extras.get("birth_date", "1998-04-20"),
        "password": password,
        "password_confirm": extras.get("password_confirm", password),
    }
    if email is not None:
        corpo["email"] = email
    else:
        corpo["phone"] = phone
        corpo["country"] = country or "BR"

    inicio = client.post("/api/v1/auth/signup/start", json=corpo)
    assert inicio.status_code == 201, inicio.text
    destino = inicio.json()["destination"]

    # O espião é injetado pela fixture autouse; quando o chamador não o passa,
    # pega-se o que estiver instalado no módulo.
    fonte = espiao or entrega.entregador
    codigo = fonte.ultimo_codigo(destino)

    fim = client.post(
        "/api/v1/auth/signup/verify", json={"destination": destino, "code": codigo}
    )
    assert fim.status_code == 201, fim.text
    return fim.json()
