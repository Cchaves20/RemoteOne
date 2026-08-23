"""Ver e mudar o plano de uma conta, à mão.

Existe porque a cobrança automática não existe ainda — e mesmo quando existir,
vai continuar sendo preciso: dar acesso a um amigo, estender o prazo de quem
teve um problema, devolver o plano a quem pagou e o webhook não chegou.

Roda dentro do contêiner, onde o banco está:

    sudo docker compose -f deploy/docker-compose.lite.yml exec -T api \\
        python -m app.conta ver caio@example.com

    ... python -m app.conta pago caio@example.com --dias 365
    ... python -m app.conta pago caio@example.com --sem-prazo
    ... python -m app.conta gratis caio@example.com

Não há como listar todas as contas de propósito. Uma ferramenta de operação que
despeja a base inteira convida a olhar dados de cliente sem motivo, e o motivo
aqui é sempre uma conta específica que alguém pediu.
"""

from __future__ import annotations

import sys
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app import cobranca, plano
from app.db import SessionLocal
from app.models import User


def _achar(db, quem: str) -> User:
    """Acha por e-mail **ou** telefone: a conta pode não ter e-mail."""
    alvo = quem.strip().lower()
    user = db.scalar(select(User).where(User.email == alvo))
    if user is None:
        user = db.scalar(select(User).where(User.phone == alvo))
    if user is None:
        raise SystemExit(f"não achei conta para {quem!r}")
    return user


def _descrever(user: User) -> str:
    efetivo = cobranca.plano_de(user)
    prazo = "sem prazo" if user.plano_ate is None else str(user.plano_ate)
    # O rótulo guardado **e** o efetivo, porque eles podem discordar — e é
    # justamente essa discordância que explica "por que o cliente diz que pagou
    # e o app diz que é grátis".
    return (
        f"conta {user.id} ({user.email or user.phone})\n"
        f"  guardado: plano={user.plano} até {prazo}\n"
        f"  valendo agora: {efetivo}"
    )


def main() -> None:
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)

    acao, quem = args[0], args[1]
    with SessionLocal() as db:
        user = _achar(db, quem)

        if acao == "ver":
            print(_descrever(user))
            return

        if acao == "pago":
            if "--sem-prazo" in args:
                user.plano_ate = None
            else:
                dias = plano.TESTE_DIAS
                if "--dias" in args:
                    dias = int(args[args.index("--dias") + 1])
                # Estende a partir de **hoje**, e não do prazo atual: quem
                # renova antes do fim não perde o que sobrou, mas quem voltou
                # depois de meses não recebe um prazo que já nasce vencido.
                base = max(
                    datetime.now(UTC),
                    user.plano_ate.replace(tzinfo=UTC)
                    if user.plano_ate and user.plano_ate.tzinfo is None
                    else (user.plano_ate or datetime.now(UTC)),
                )
                user.plano_ate = base + timedelta(days=dias)
            user.plano = plano.Plano.PAGO
        elif acao == "gratis":
            user.plano = plano.Plano.GRATIS
            user.plano_ate = None
        else:
            raise SystemExit(f"ação desconhecida: {acao!r}")

        db.commit()
        db.refresh(user)
        print(_descrever(user))


if __name__ == "__main__":
    main()
