"""Comandos para a primeira hora de um incidente. Ver docs/plano-de-incidente.md.

Rodam dentro do contêiner, onde o banco está:

    sudo docker compose -f docker-compose.lite.yml exec -T api \\
        python -m app.incidente derrubar-sessoes
    sudo docker compose -f docker-compose.lite.yml restart api

## Por que não trocar o DESKSIDE_JWT_SECRET

É o reflexo, e derruba todas as sessões, mas leva junto o que não devia: os
códigos de recuperação do 2FA e os códigos de verificação em andamento são
resumos com esse segredo, e sem `DESKSIDE_TOTP_KEY` a própria chave do 2FA sai
dele. Trocá-lo no meio de um incidente tranca do lado de fora justamente quem se
protegeu melhor.

`derrubar-sessoes` faz o mesmo efeito pelo caminho previsto: uma chave de sessão
nova para cada conta (`User.token_key`) e todas as sessões encerradas. Todo
token emitido antes para de valer, e cada pessoa entra de novo com senha (e
2FA). O `restart` depois limpa a memória do servidor (`app.vinculos`), que
guarda por até um minuto que um token valia.
"""

from __future__ import annotations

import sys
from datetime import UTC, datetime

from sqlalchemy import select, update

from app.db import SessionLocal
from app.models import Sessao, User
from app.security import nova_chave_de_sessao


def derrubar_sessoes() -> int:
    """Invalida todo token e encerra toda sessão. Devolve quantas contas."""
    agora = datetime.now(UTC)
    with SessionLocal() as db:
        ids = list(db.scalars(select(User.id)))
        for uid in ids:
            db.execute(update(User).where(User.id == uid).values(token_key=nova_chave_de_sessao()))
        db.execute(update(Sessao).where(Sessao.encerrada_em.is_(None)).values(encerrada_em=agora))
        db.commit()
    return len(ids)


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["derrubar-sessoes"]:
        n = derrubar_sessoes()
        print(f"sessões derrubadas em {n} conta(s). Agora: docker compose restart api")
        return
    print(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
