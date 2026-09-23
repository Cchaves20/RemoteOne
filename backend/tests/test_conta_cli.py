"""O comando de operação que mexe no plano de uma conta à mão.

`python -m app.conta` é o que existe quando alguém escreve pedindo ajuda. O que
se testa aqui é o `desvincular`, que é o único que **apaga** alguma coisa — e
apagar a linha errada, ou deixar o plano errado depois de apagar a certa, são
os dois jeitos de transformar um pedido de suporte em dois.
"""

import sys
from datetime import UTC, datetime, timedelta

import pytest
from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import conta
from app.db import SessionLocal
from app.main import app
from app.models import Assinatura, User

client = TestClient(app)


def _rodar(*args: str) -> None:
    sys.argv = ["conta", *args]
    conta.main()


def _dar_assinatura(email: str, id_hash: str = "a" * 64, loja: str = "apple") -> int:
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        db.add(
            Assinatura(
                user_id=user.id,
                loja=loja,
                id_hash=id_hash,
                product_id="com.deskside.pro.mensal",
                estado="ativa",
                ambiente="producao",
            )
        )
        user.plano = "pago"
        user.plano_ate = datetime.now(UTC) + timedelta(days=30)
        db.commit()
        return user.id


def _estado(email: str) -> tuple[str, datetime | None, int]:
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        quantas = (
            db.query(Assinatura).filter(Assinatura.user_id == user.id).count()
        )
        return user.plano, user.plano_ate, quantas


class TestDesvincular:
    def test_solta_a_compra_da_conta(self):
        email = "errada@example.com"
        criar_conta(client, email)
        _dar_assinatura(email)

        _rodar("desvincular", email)

        _, _, quantas = _estado(email)
        assert quantas == 0, "a assinatura continua presa à conta"

    def test_apaga_todas_e_nao_so_a_primeira(self):
        """`user_id` não é único: Apple e Google convivem na mesma conta.

        Soltar metade deixaria a pessoa com o mesmo erro por outro motivo — e
        é o tipo de defeito que só aparece no segundo pedido de suporte.
        """
        email = "duas@example.com"
        criar_conta(client, email)
        _dar_assinatura(email, id_hash="b" * 64, loja="apple")
        _dar_assinatura(email, id_hash="c" * 64, loja="google")

        _rodar("desvincular", email)

        assert _estado(email)[2] == 0

    def test_nao_mexe_na_assinatura_de_outra_conta(self):
        """A trava que impede o comando de virar um estrago maior."""
        vitima = "vizinha@example.com"
        alvo = "alvo@example.com"
        criar_conta(client, vitima)
        criar_conta(client, alvo)
        _dar_assinatura(vitima, id_hash="d" * 64)
        _dar_assinatura(alvo, id_hash="e" * 64)

        _rodar("desvincular", alvo)

        assert _estado(alvo)[2] == 0
        assert _estado(vitima)[2] == 1, "desvinculou a conta errada junto"

    def test_conta_antiga_cai_no_gratis(self):
        # Sem a compra e sem teste para voltar, o plano não se sustenta.
        email = "antiga@example.com"
        criar_conta(client, email)
        _dar_assinatura(email)
        with SessionLocal() as db:
            user = db.scalar(select(User).where(User.email == email))
            user.created_at = datetime.now(UTC) - timedelta(days=200)
            db.commit()

        _rodar("desvincular", email)

        plano, ate, _ = _estado(email)
        assert plano == "gratis"
        assert ate is None

    def test_conta_nova_fica_com_o_que_resta_do_teste(self):
        email = "nova@example.com"
        criar_conta(client, email)
        _dar_assinatura(email)

        _rodar("desvincular", email)

        plano, ate, _ = _estado(email)
        assert plano == "pago", "os 30 dias iniciais sumiram junto com a compra"
        assert ate is not None

    def test_a_cortesia_sem_prazo_sobrevive(self):
        """Desvincular a conta do dono não pode derrubar o plano dela."""
        email = "dono@example.com"
        criar_conta(client, email)
        _dar_assinatura(email)
        with SessionLocal() as db:
            user = db.scalar(select(User).where(User.email == email))
            user.plano, user.plano_ate = "pago", None
            db.commit()

        _rodar("desvincular", email)

        plano, ate, quantas = _estado(email)
        assert (plano, ate) == ("pago", None)
        assert quantas == 0, "a compra devia ter sido solta mesmo assim"

    def test_sem_assinatura_nao_mexe_no_plano(self):
        """Rodar por engano numa conta sem compra não pode rebaixá-la.

        É o caso de digitar o e-mail errado — e o comando não sabe disso, mas
        pode não fazer estrago.
        """
        email = "semcompra@example.com"
        criar_conta(client, email)
        antes = _estado(email)

        _rodar("desvincular", email)

        assert _estado(email) == antes

    def test_email_inexistente_reclama(self):
        with pytest.raises(SystemExit):
            _rodar("desvincular", "ninguem@example.com")
