"""Avisar antes de o teste de 30 dias acabar.

Sem isto, os trinta dias passam e a pessoa descobre pelo limite: tenta parear o
segundo computador, ou agendar uma automação, e é recusada. Descobrir uma
mudança de plano batendo numa porta é a pior forma de descobrir — parece defeito,
não parece regra, e a primeira reação é achar que o produto quebrou.

Um e-mail alguns dias antes custa centavos e transforma a recusa em algo que já
era esperado.

## Rodar

    sudo docker compose -f deploy/docker-compose.lite.yml exec -T api \\
        python -m app.avisos

Uma vez por dia, pelo cron da VM — junto do backup. Rodar duas vezes no mesmo
dia não manda nada duas vezes: quem já foi avisado fica marcado.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app import entrega, plano
from app.db import SessionLocal
from app.models import User

#: Quantos dias antes do fim o aviso sai.
#:
#: Cinco: perto o bastante para ser concreto ("acaba na sexta") e longe o
#: bastante para caber uma decisão. Um aviso no último dia é uma cobrança; um
#: aviso com quinze dias de antecedência é esquecido antes de importar.
DIAS_DE_ANTECEDENCIA = 5


def _aware(quando: datetime) -> datetime:
    return quando if quando.tzinfo is not None else quando.replace(tzinfo=UTC)


def deve_avisar(
    user_plano: str | None,
    plano_ate: datetime | None,
    ja_avisado_em: datetime | None,
    agora: datetime,
) -> bool:
    """Esta conta merece o aviso hoje?

    Quatro recusas, e cada uma evita um e-mail que faria a pessoa desconfiar do
    produto:

    - quem já está no grátis não recebe: o aviso chegaria depois do fato
    - quem não tem prazo não recebe: não há o que acabar
    - quem ainda está longe não recebe: cinco dias, e não trinta
    - quem já foi avisado não recebe de novo, e é isto que permite rodar esta
      tarefa todo dia sem transformá-la em spam
    """
    if plano.plano_efetivo(user_plano, plano_ate, agora) != plano.Plano.PAGO:
        return False
    if plano_ate is None:
        return False
    if ja_avisado_em is not None:
        return False
    faltam = _aware(plano_ate) - _aware(agora)
    return timedelta(0) < faltam <= timedelta(days=DIAS_DE_ANTECEDENCIA)


def texto(nome: str, quando: datetime) -> tuple[str, str]:
    """O assunto e o corpo do aviso.

    Diz o que continua funcionando **antes** de dizer o que para. Uma mensagem
    que abre com o que se perde é lida como ameaça, e a reação a uma ameaça de
    software é desinstalar.
    """
    dia = _aware(quando).strftime("%d/%m")
    assunto = f"Seu mês de Deskside completo termina em {dia}"
    corpo = (
        f"Olá, {nome}.\n\n"
        f"No dia {dia} a sua conta passa para o plano grátis do Deskside. "
        "Nada é apagado e nada para de existir: seu computador continua "
        "pareado, suas automações continuam salvas, e mouse, teclado e a tela "
        "ao vivo continuam funcionando como hoje.\n\n"
        "O que fica no plano pago: mais de um computador, automações em "
        "horário marcado, transferência de arquivos, modo apresentação, som do "
        "computador, perfis de controle e vários monitores.\n\n"
        "Se quiser continuar com tudo, responda este e-mail — ainda estamos "
        "montando o pagamento automático e fazemos na mão por enquanto.\n\n"
        "— Deskside\nhttps://deskside.com.br"
    )
    return assunto, corpo


def rodar(agora: datetime | None = None) -> int:
    """Manda os avisos do dia. Devolve quantos saíram."""
    agora = agora or datetime.now(UTC)
    enviados = 0
    with SessionLocal() as db:
        contas = db.scalars(select(User).where(User.plano_ate.is_not(None))).all()
        for user in contas:
            if not deve_avisar(user.plano, user.plano_ate, user.aviso_fim_teste_em, agora):
                continue
            if not user.email:
                # Conta criada por telefone. Sem SMS contratado, não há por onde
                # avisar — e marcar como avisada esconderia isso para sempre.
                continue
            assunto, corpo = texto(user.first_name or "tudo bem", user.plano_ate)
            try:
                entrega.entregador.aviso(user.email, assunto, corpo)
            except entrega.EntregaError as exc:
                # Não marca: falhar hoje tem que deixar a tarefa de amanhã
                # tentar de novo. Marcar antes de enviar é como se perde um
                # aviso para sempre por causa de um provedor fora do ar.
                print(f"aviso não saiu para {user.email}: {exc}")
                continue
            user.aviso_fim_teste_em = agora
            enviados += 1
        db.commit()
    return enviados


def main() -> None:
    quantos = rodar()
    print(f"avisos de fim de teste enviados: {quantos}")


if __name__ == "__main__":
    main()
