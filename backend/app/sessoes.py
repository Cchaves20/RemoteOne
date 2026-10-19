"""Sessões por aparelho: quem está com a conta aberta, e tirar um de cada vez.

Antes, a sessão de um celular durava 30 dias sem mudar e não aparecia em lugar
nenhum. Quem copiasse o refresh token ficava 30 dias dentro sem ninguém ver, e
a única saída era trocar a senha — que derruba **todos** os aparelhos.

Agora cada login abre uma `Sessao` (ver `models.py`), e três coisas mudam:

- **Dá para ver** os aparelhos conectados e encerrar um só.
- **O refresh token muda a cada renovação**, e o antigo deixa de valer. Um
  antigo que reaparece é cópia, e a sessão cai (ver `renovar`).
- **Sair do app encerra a sessão no servidor**, em vez de só esquecer o token
  no aparelho.

## O app que já está nos celulares

Continua funcionando sem novo login. O token dele não traz `sid`; na primeira
renovação ele ganha uma sessão, achada depois pelo resumo do próprio token
(`legado`), e aparece na lista sem nome de aparelho. Ele não sabe trocar de
refresh token, então só troca quem pede (`rotacao`).
"""

from __future__ import annotations

import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from urllib.parse import unquote

from fastapi import Request
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.config import settings
from app.models import Sessao, User

#: Como o app se apresenta (ex.: "iPhone · iOS 18.1"), codificado como em URL:
#: cabeçalho HTTP só leva ASCII, e o nome tem "·" e pode ter acento.
CABECALHO = "X-Deskside-Aparelho"

#: Quanto tempo depois de uma troca o refresh **anterior** ainda é aceito.
#:
#: Sem folga, perder a resposta de uma renovação (o túnel, o elevador) faria o
#: app tentar de novo com o token que acabou de ser trocado — e ele seria
#: tratado como cópia, derrubando a sessão de quem só teve rede ruim. Trinta
#: segundos cobrem a nova tentativa e são curtos demais para um ladrão contar
#: com eles.
FOLGA_DA_RENOVACAO = timedelta(seconds=30)


def utc(quando: datetime) -> datetime:
    """O SQLite devolve datas sem fuso; ver `verificacao.expirou`."""
    return quando if quando.tzinfo else quando.replace(tzinfo=UTC)


def _validade() -> timedelta:
    return timedelta(days=settings.refresh_token_ttl_days)


def nome_do_aparelho(request: Request | None) -> str:
    """O nome que o app mandou, limpo: só texto imprimível, até 80 caracteres."""
    if request is None:
        return ""
    bruto = unquote(request.headers.get(CABECALHO, ""))
    return "".join(c for c in bruto if c.isprintable()).strip()[:80]


def resumo(refresh_token: str) -> str:
    return hashlib.sha256(refresh_token.encode()).hexdigest()


def abrir(db: Session, user: User, request: Request | None) -> Sessao:
    """Uma sessão nova para este login. Quem chama grava (`commit`)."""
    limpar(db, user)
    sessao = Sessao(
        id=secrets.token_hex(16),
        user_id=user.id,
        aparelho=nome_do_aparelho(request),
    )
    db.add(sessao)
    db.flush()
    return sessao


def limpar(db: Session, user: User, agora: datetime | None = None) -> None:
    """Apaga as sessões sem uso há mais tempo que o refresh dura.

    Só essas: o refresh de uma sessão sai no máximo no último uso, então depois
    disso ele já venceu e a linha não protege mais nada. Uma encerrada há menos
    tempo **fica**, marcada, para o token dela continuar recusado.
    """
    corte = (agora or datetime.now(UTC)) - _validade()
    db.execute(
        delete(Sessao).where(Sessao.user_id == user.id, Sessao.ultimo_uso < corte)
    )


def ativa(sessao: Sessao | None, user: User, agora: datetime | None = None) -> bool:
    if sessao is None or sessao.user_id != user.id or sessao.encerrada_em is not None:
        return False
    return utc(sessao.ultimo_uso) >= (agora or datetime.now(UTC)) - _validade()


def valida(db: Session, payload: dict, user: User) -> bool:
    """O `sid` do token aponta para uma sessão aberta desta conta?

    Token sem `sid` é de antes das sessões e passa: o access dura 15 minutos, e
    o refresh dele ganha uma sessão na primeira renovação (`renovar`).
    """
    sid = payload.get("sid")
    if sid is None:
        return True
    return ativa(db.get(Sessao, sid), user)


def encerrar(sessao: Sessao, agora: datetime | None = None) -> None:
    if sessao.encerrada_em is None:
        sessao.encerrada_em = agora or datetime.now(UTC)


def encerrar_todas(
    db: Session, user: User, menos: str | None = None, agora: datetime | None = None
) -> None:
    """Encerra as sessões da conta, menos a `menos` (a de quem pediu)."""
    for sessao in db.scalars(select(Sessao).where(Sessao.user_id == user.id)).all():
        if sessao.id != menos:
            encerrar(sessao, agora)


def abertas(db: Session, user: User) -> list[Sessao]:
    agora = datetime.now(UTC)
    todas = db.scalars(select(Sessao).where(Sessao.user_id == user.id)).all()
    return sorted(
        (s for s in todas if ativa(s, user, agora)),
        key=lambda s: utc(s.ultimo_uso),
        reverse=True,
    )


class Copiada(Exception):
    """O refresh apresentado é de uma geração já trocada: alguém o copiou."""

    def __init__(self, sessao: Sessao) -> None:
        self.sessao = sessao


def renovar(
    db: Session,
    user: User,
    payload: dict,
    refresh_token: str,
    rotacao: bool,
    request: Request | None = None,
    agora: datetime | None = None,
) -> tuple[Sessao, int | None] | None:
    """Confere o refresh contra a sessão e diz com que geração emitir o novo.

    Devolve `(sessão, geração)` — geração `None` quando o app não troca de
    refresh (o antigo) — ou `None` quando a sessão não vale. Lança `Copiada`
    quando o token é de uma geração passada fora da folga; quem chama encerra
    a sessão, grava e avisa o dono.
    """
    agora = agora or datetime.now(UTC)
    sid = payload.get("sid")
    if sid is None:
        # Token de antes das sessões: a sessão é achada pelo resumo dele, e
        # nasce aqui na primeira vez.
        marca = resumo(refresh_token)
        sessao = db.scalar(
            select(Sessao).where(Sessao.user_id == user.id, Sessao.legado == marca)
        )
        if sessao is None:
            sessao = abrir(db, user, request)
            sessao.legado = marca
        geracao = 0
    else:
        sessao = db.get(Sessao, sid)
        geracao = payload.get("g", 0)
    if not ativa(sessao, user, agora):
        return None

    if geracao == sessao.geracao:
        if rotacao:
            sessao.geracao += 1
            sessao.geracao_em = agora
    elif (
        geracao == sessao.geracao - 1
        and agora - utc(sessao.geracao_em) <= FOLGA_DA_RENOVACAO
    ):
        # A mesma renovação repetida logo em seguida (resposta perdida, ou o
        # widget do celular renovando junto com o app): devolve a geração
        # atual, sem trocar de novo.
        pass
    else:
        raise Copiada(sessao)

    sessao.ultimo_uso = agora
    return sessao, (sessao.geracao if rotacao else None)
