"""A cola entre as regras de plano e as rotas HTTP.

`app/plano.py` não conhece FastAPI de propósito — é a regra, e regra se testa
sem servidor. Aqui mora o que é do protocolo: qual status devolver e o que
escrever na recusa.

## Por que 402, e não 403

`403` é "você não pode". `402 Payment Required` é "você poderia, pagando" — e a
diferença não é preciosismo de padrão: é a única coisa que permite ao app
distinguir *isto não é seu* de *isto é do plano pago* sem ler texto. Um 403 faria
o aplicativo mostrar "acesso negado" para quem só precisava saber que existe um
plano.
"""

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import plano as regras
from app.models import Assinatura, User


def plano_de(user: User) -> regras.Plano:
    """O plano em que esta conta está agora."""
    return regras.plano_efetivo(user.plano, user.plano_ate)


def em_teste(db: Session, user: User) -> bool:
    """O plano pago desta conta são os 30 dias iniciais, e não uma compra?

    Três condições, e todas necessárias:

    - a conta está paga **agora** — quem já caiu no grátis não está em teste;
    - tem prazo: sem prazo é a cortesia dada à mão, que não acaba;
    - não tem assinatura de loja — é isto que separa teste de compra, porque
      pelo calendário os dois são a mesma coisa: trinta dias.

    Mora aqui, e não no `app/plano.py`, porque depende do banco. O `plano.py`
    é regra pura de propósito, e uma consulta lá dentro tornaria intestável a
    parte que hoje se testa sem banco nenhum.
    """
    if plano_de(user) is not regras.Plano.PAGO or user.plano_ate is None:
        return False
    comprou = db.scalar(
        select(Assinatura.id).where(Assinatura.user_id == user.id).limit(1)
    )
    return comprou is None


def exigir_recurso(user: User, recurso: regras.Recurso) -> None:
    """Deixa passar, ou recusa dizendo **o que** foi recusado."""
    if regras.permite(plano_de(user), recurso):
        return
    raise HTTPException(
        status_code=status.HTTP_402_PAYMENT_REQUIRED,
        detail=regras.motivo(recurso),
    )


def exigir_espaco(user: User, quantos_ja_tem: int, limite: int | None, o_que: str) -> None:
    """Recusa quando o limite do plano já está cheio.

    O limite chega pronto em vez de ser calculado aqui: quem sabe quantos
    computadores ou automações o plano alcança é `app/plano.py`, e duplicar essa
    conta neste arquivo criaria uma segunda verdade sobre o mesmo assunto.
    """
    if regras.cabe(quantos_ja_tem, limite):
        return
    raise HTTPException(
        status_code=status.HTTP_402_PAYMENT_REQUIRED,
        detail=regras.motivo_do_limite(limite or 0, o_que),
    )
