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
from app.assinatura import Estado
from app.models import Assinatura, User


def plano_de(user: User) -> regras.Plano:
    """O plano em que esta conta está agora."""
    return regras.plano_efetivo(user.plano, user.plano_ate)


#: Os estados em que a loja **vai cobrar de novo** quando o prazo acabar.
#:
#: `cancelada` fica de fora de propósito: a pessoa desligou a renovação, então o
#: prazo é uma data de término e não uma data de cobrança. `expirada` e
#: `revogada` também não cobram nada.
_RENOVAM = frozenset({Estado.ATIVA, Estado.EM_ATRASO})


def situacao_de(db: Session, user: User) -> tuple[bool, bool]:
    """`(em_teste, renova)` — as duas coisas que o app não consegue deduzir.

    Uma consulta só para as duas perguntas, porque as duas se respondem com a
    mesma linha da tabela de assinaturas, e `/auth/me` é chamado a cada
    abertura de tela.

    **em_teste**: o plano pago são os 30 dias iniciais, e não uma compra. Três
    condições, todas necessárias: estar pago agora (quem caiu no grátis não
    está em teste), ter prazo (sem prazo é a cortesia dada à mão, que não
    acaba), e não ter assinatura de loja — é isto que separa teste de compra,
    porque pelo calendário os dois são a mesma coisa, trinta dias.

    **renova**: existe uma cobrança marcada para quando o prazo acabar. É o que
    decide entre "22 dias para a próxima cobrança" e "acaba em 22 dias", e a
    diferença não é de estilo: a primeira frase dita a quem cancelou é o app
    dizendo que vai cobrar de alguém que pediu para não ser cobrado.

    Mora aqui, e não no `app/plano.py`, porque depende do banco. O `plano.py`
    é regra pura de propósito, e uma consulta lá dentro tornaria intestável a
    parte que hoje se testa sem banco nenhum.
    """
    if plano_de(user) is not regras.Plano.PAGO or user.plano_ate is None:
        return False, False
    assinatura = db.scalar(
        select(Assinatura).where(Assinatura.user_id == user.id).limit(1)
    )
    if assinatura is None:
        return True, False
    return False, assinatura.estado in _RENOVAM


def em_teste(db: Session, user: User) -> bool:
    """Só o primeiro de `situacao_de`, para quem não precisa do resto."""
    return situacao_de(db, user)[0]


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
