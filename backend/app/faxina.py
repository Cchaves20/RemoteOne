"""Apaga o que venceu e não serve mais para nada.

O cadastro, a recuperação de senha e a troca de contato deixam um registro
pendente enquanto esperam o código. Quem desiste no meio deixava esse registro
para sempre - com nome, e-mail e o hash da senha de alguém que nem chegou a ter
conta. Guardar dado sem finalidade é o que a LGPD pede para não fazer (art. 6º,
III e art. 16), e a política de privacidade promete o contrário.

Roda dentro do próprio servidor, a cada `INTERVALO` (ver `main.lifespan`): não
depende de ninguém lembrar de pôr uma linha no cron.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, update
from sqlalchemy.orm import Session

from app.config import settings
from app.models import (
    Device,
    PairingRequest,
    PasswordReset,
    PendingContactChange,
    PendingSignup,
    Sessao,
)

logger = logging.getLogger("deskside")

#: De quanto em quanto tempo a faxina roda.
INTERVALO = timedelta(hours=6)

#: Folga depois do vencimento. Um código vence em 10 minutos; um dia de folga
#: deixa claro que ninguém está mais no meio do caminho.
FOLGA = timedelta(days=1)

#: Sessão encerrada ou vencida fica um tempo para aparecer na lista de
#: "aparelhos conectados" com a data em que saiu; depois, não diz mais nada.
GUARDA_DE_SESSAO_ENCERRADA = timedelta(days=30)


def limpar(db: Session, agora: datetime | None = None) -> dict[str, int]:
    """Apaga o vencido e devolve quantos de cada tipo saíram."""
    agora = agora or datetime.now(UTC)
    corte = agora - FOLGA
    apagados: dict[str, int] = {}

    for nome, modelo in (
        ("cadastros", PendingSignup),
        ("recuperacoes", PasswordReset),
        ("trocas_de_contato", PendingContactChange),
        ("pareamentos", PairingRequest),
    ):
        resultado = db.execute(delete(modelo).where(modelo.expires_at < corte))
        apagados[nome] = resultado.rowcount or 0

    antiga = agora - GUARDA_DE_SESSAO_ENCERRADA
    resultado = db.execute(
        delete(Sessao).where(
            (Sessao.encerrada_em.is_not(None) & (Sessao.encerrada_em < antiga))
            | (Sessao.ultimo_uso < antiga)
        )
    )
    apagados["sessoes"] = resultado.rowcount or 0

    # Com a trava fechada, o agente antigo não entra mais, e o segredo em texto
    # puro que esperava por ele (`Device.agent_secret_pendente`) só serve para
    # quem lesse uma cópia do banco. A folga protege o pareamento que acabou de
    # acontecer: o agente novo recebe o pendente na conexão seguinte.
    if settings.exigir_segredo_do_agente:
        resultado = db.execute(
            update(Device)
            .where(Device.agent_secret_pendente.is_not(None), Device.created_at < corte)
            .values(agent_secret_pendente=None)
        )
        apagados["segredos_pendentes"] = resultado.rowcount or 0

    db.commit()
    if any(apagados.values()):
        logger.info("faxina: %s", apagados)
    return apagados
