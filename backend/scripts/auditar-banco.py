#!/usr/bin/env python3
"""Enche um banco pelo fluxo real e procura os segredos dentro do arquivo.

## Por que isto não é um teste

Um teste pergunta ao código. Este roteiro **abre o `.db` como bytes e procura**
— é a única forma de a resposta não depender da intenção de quem escreveu o
código. Um `assert user.hashed_password != senha` passa mesmo que a senha tenha
ido parar em outra coluna, em outra tabela, ou num índice.

Também não roda a cada `pytest` de propósito: cria um banco de verdade, exercita
cadastro, 2FA, recuperação de senha, pareamento e compra, e inspeciona o
arquivo. É coisa de se fazer **quando o modelo de dados muda**, e é aí que ele
paga: foi assim que se descobriu que o segredo do agente estava em texto puro
enquanto a senha estava com bcrypt.

## Uso

    cd backend
    python scripts/auditar-banco.py

Sai com código 1 se algum segredo aparecer onde não devia. Ver
`docs/revisao-do-banco.md`.
"""

import os
import pathlib
import sqlite3
import sys
import tempfile

BANCO = pathlib.Path(tempfile.mkdtemp()) / "auditoria.db"
os.environ["DESKSIDE_DATABASE_URL"] = f"sqlite:///{BANCO}"
os.environ.setdefault("DESKSIDE_JWT_SECRET", "auditoria-com-tamanho-suficiente-32b")

from fastapi.testclient import TestClient  # noqa: E402

from app import entrega, pairing  # noqa: E402
from app.db import Base, SessionLocal, engine  # noqa: E402
from app.main import _autorizar_agente, _segredo_do_aparelho, app  # noqa: E402

SENHA = "SenhaSuperSecreta123!"
EMAIL = "auditoria@example.com"
TOKEN_DA_LOJA = "purchase-token-do-google-que-e-credencial-de-fato"


class Espiao(entrega.Entregador):
    """Guarda os códigos em vez de enviar, para o fluxo inteiro poder rodar."""

    def __init__(self) -> None:
        self.codigos: list[str] = []

    def email(self, destino: str, codigo: str) -> None:
        self.codigos.append(codigo)

    def sms(self, destino: str, codigo: str) -> None:
        self.codigos.append(codigo)

    def aviso(self, destino: str, assunto: str, corpo: str) -> None:
        pass


def encher() -> dict[str, str]:
    """Exercita o produto inteiro e devolve os segredos que ele gerou."""
    Base.metadata.create_all(bind=engine)
    espiao = Espiao()
    entrega.entregador = espiao
    client = TestClient(app)

    # Cadastro, pelo caminho de verdade: duas etapas, sem atalho.
    client.post("/api/v1/auth/signup/start", json={
        "email": EMAIL, "password": SENHA, "password_confirm": SENHA,
        "first_name": "Caio", "last_name": "Chaves", "birth_date": "1998-04-20",
    })
    codigo_cadastro = espiao.codigos[-1]
    resposta = client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": EMAIL, "code": codigo_cadastro},
    )
    cab = {"Authorization": f"Bearer {resposta.json()['access_token']}"}

    # Segundo fator.
    segredo_totp = client.post("/api/v1/auth/2fa/setup", headers=cab).json()["secret"]
    import pyotp

    client.post("/api/v1/auth/2fa/enable",
                json={"code": pyotp.TOTP(segredo_totp).now()}, headers=cab)

    # Recuperação de senha (gera um código guardado).
    client.post("/api/v1/auth/password/forgot", json={"email": EMAIL})
    codigo_reset = espiao.codigos[-1]

    # Computador pareado. O agente conecta **depois** da primeira medição: a
    # conexão é o que apaga o texto puro da entrega, e medir só depois dela
    # esconderia um defeito que guardasse o segredo na coluna definitiva — a
    # conversão automática apagaria o rastro antes de alguém olhar.
    #
    # Este roteiro já deu um "ok" falso exatamente assim. Ver a função `main`.
    from sqlalchemy import select

    from app.models import User

    with SessionLocal() as db:
        dono = db.scalar(select(User).where(User.email == EMAIL))
        code = pairing.create_pairing_request(db, "dev-auditoria", "PC", "windows", 600)
        pairing.claim(db, code, dono)
        db.commit()
    segredo_agente = _segredo_do_aparelho("dev-auditoria")

    # Assinatura comprada numa loja.
    from datetime import UTC, datetime, timedelta

    from app import compras, lojas
    from app.assinatura import Ambiente, Compra, Estado, Loja

    class LojaFalsa(lojas.Verificador):
        def verificar(self, comprovante: str) -> Compra:
            return Compra(
                loja=Loja.GOOGLE, id_original=TOKEN_DA_LOJA,
                product_id="com.deskside.pro.mensal", estado=Estado.ATIVA,
                ambiente=Ambiente.PRODUCAO,
                expira_em=datetime.now(UTC) + timedelta(days=30),
                visto_em=datetime.now(UTC),
            )

    compras.lojas.verificador_de = lambda _l: LojaFalsa()
    client.post("/api/v1/assinatura/validar",
                json={"loja": "google", "comprovante": "x" * 32}, headers=cab)

    return {
        "senha da conta": SENHA,
        "código de cadastro": codigo_cadastro,
        "código de recuperação de senha": codigo_reset,
        "segredo do 2FA (TOTP)": segredo_totp,
        "segredo do agente": segredo_agente,
        "identificador da compra na loja": TOKEN_DA_LOJA,
    }


def coluna_definitiva_do_agente() -> str | None:
    """O que `Device.agent_secret` guarda agora."""
    from sqlalchemy import select

    from app.models import Device

    with SessionLocal() as db:
        linha = db.scalar(select(Device).where(Device.device_id == "dev-auditoria"))
        return linha.agent_secret if linha else None


def recolher() -> bytes:
    """O arquivo do banco, com as páginas livres recolhidas.

    O `VACUUM` importa: sem ele, o SQLite deixa em páginas livres o conteúdo de
    linhas já apagadas, e a busca acusaria um resto do que foi removido de
    propósito — um falso alarme que faria a próxima pessoa desconfiar da
    ferramenta em vez do código.
    """
    sqlite3.connect(BANCO).execute("VACUUM").close()
    return BANCO.read_bytes()


#: O que **deve** aparecer em texto: é dado pessoal, não segredo, e cifrá-lo
#: impediria login e busca sem proteger contra nada que a cifra do backup já não
#: cubra. Está aqui para a auditoria afirmar as duas coisas, e não só uma.
ESPERADOS = {"e-mail da conta": EMAIL, "nome da pessoa": "Caio"}


def main() -> int:
    """Mede em **dois** momentos, e a razão é uma lição aprendida na marra.

    A primeira versão media uma vez só, depois de o agente conectar — e deu um
    "ok" com o defeito posto de volta de propósito. A conversão automática das
    linhas antigas tinha apagado o texto puro **antes** da medida: a ferramenta
    dizia que estava tudo certo justamente porque o conserto estava funcionando
    em cima do defeito.

    Uma auditoria que só olha depois da faxina não audita nada.
    """
    segredos = encher()
    problemas = 0

    # --- Momento 1: pareado, agente ainda não conectou --------------------
    # É a janela de entrega. O segredo **pode** estar em texto puro aqui, mas
    # só na coluna de espera — a definitiva já tem de ser resumo.
    guardado = coluna_definitiva_do_agente()
    e_resumo = pairing.e_resumo(guardado)
    if not e_resumo:
        problemas += 1
    print("momento 1 — pareado, antes de o agente conectar")
    print(
        f"   Device.agent_secret guarda: {'resumo' if e_resumo else 'TEXTO PURO'}"
        f"   {'ok' if e_resumo else '<<< VAZOU'}\n"
    )

    # --- Momento 2: o agente provou que recebeu ---------------------------
    _autorizar_agente("dev-auditoria", segredos["segredo do agente"])
    bytes_do_banco = recolher()

    print(f"momento 2 — depois da primeira conexão autenticada do agente")
    print(f"banco auditado: {BANCO} ({len(bytes_do_banco)} bytes)\n")
    print(f"{'o que':36} {'esperado':10} {'medido':10} veredito")

    for rotulo, valor in segredos.items():
        achou = valor.encode() in bytes_do_banco
        if achou:
            problemas += 1
        print(
            f"{rotulo:36} {'ausente':10} {('PRESENTE' if achou else 'ausente'):10} "
            f"{'<<< VAZOU' if achou else 'ok'}"
        )

    for rotulo, valor in ESPERADOS.items():
        achou = valor.encode() in bytes_do_banco
        if not achou:
            problemas += 1
        print(
            f"{rotulo:36} {'presente':10} {('presente' if achou else 'AUSENTE'):10} "
            f"{'ok' if achou else '<<< sumiu'}"
        )

    print()
    if problemas:
        print(f"FALHOU: {problemas} problema(s). Ver docs/revisao-do-banco.md.")
        return 1
    print("ok: nenhum segredo em texto puro dentro do arquivo do banco.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
