"""Quem já teve os 30 dias de teste — e o que impede de ganhá-los de novo.

## O buraco

Toda conta nova nasce com 30 dias do plano pago (`app/plano.py`). Sem mais
nada, bastava criar outra conta a cada mês. E nem era preciso outra caixa de
e-mail: `caio+1@gmail.com`, `caio+2@gmail.com` e `c.aio@gmail.com` são três
contas para o Deskside e **uma** caixa para o Gmail.

## As duas âncoras

1. **O e-mail canônico.** Para decidir "esta pessoa já teve teste?", o
   `+qualquercoisa` é ignorado e, no Gmail, os pontos também. O e-mail da
   conta não muda — isto só vale para a comparação.
2. **O computador.** O produto só serve com um PC do outro lado, e o PC é o
   que não muda de conta para conta. O agente manda um resumo do `MachineGuid`
   do Windows, que sobrevive a reinstalar o Deskside e só muda se o Windows
   for reinstalado. Um computador serve a **dois** testes — uma família com
   duas contas num PC compartilhado não é fraude — e o terceiro não ganha.

## Por que o registro não aponta para a conta

`TesteConcedido` não tem chave estrangeira para `users`, de propósito: ele
precisa **sobreviver à exclusão da conta**. Se sumisse junto, bastaria excluir
e recriar. Por isso guarda só resumos (SHA-256), nunca o e-mail nem o
identificador da máquina — e a política de privacidade diz isso.

## O que isto não pega, e está tudo bem

Quem cria outra conta do Gmail de verdade (o Google pede telefone) **e** usa
outro computador ganha outro teste. A essa altura o esforço é maior que o
preço de um mês, e perfis, automações e computadores pareados não vêm junto —
cada conta nova começa do zero. O objetivo é fechar o atalho de graça, não
transformar o cadastro num interrogatório.
"""

from __future__ import annotations

import hashlib
import re
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app import cobranca
from app import plano as regras
from app.models import TesteConcedido, User

#: Quantos testes um computador serve.
#:
#: Dois, e não um: pais e filho com contas separadas num PC da casa é uso
#: honesto, e cortar o teste do segundo trataria a família como fraude. O
#: terceiro já não é família provável — é a mesma pessoa pela terceira vez.
LIMITE_POR_MAQUINA = 2

#: Domínios em que os pontos do nome não importam. Só o Gmail faz isso; em
#: outros provedores `a.b@x` e `ab@x` são caixas diferentes, e juntá-las
#: negaria o teste a uma segunda pessoa de verdade.
_GMAIL = frozenset({"gmail.com", "googlemail.com"})

#: O resumo que o agente manda: SHA-256 em hexadecimal, nada além.
_RESUMO = re.compile(r"^[0-9a-f]{64}$")


def email_canonico(email: str) -> str:
    """O e-mail como o provedor o entende, para comparar pessoas.

    - minúsculas e sem espaços, como o cadastro já faz;
    - sem o `+sufixo`, que quase todo provedor entrega na mesma caixa (Gmail,
      Outlook, iCloud, Proton, Fastmail);
    - no Gmail, sem os pontos, e `googlemail.com` vira `gmail.com` — são a
      mesma caixa.

    Nunca é gravado como e-mail de ninguém: serve só à pergunta "já teve
    teste?". Um endereço estranho (sem `@`, ou só `+sufixo`) volta como veio,
    que é o lado seguro: no pior caso a pessoa ganha um teste que não deveria.
    """
    limpo = email.strip().lower()
    local, arroba, dominio = limpo.rpartition("@")
    if not arroba or not local or not dominio:
        return limpo
    sem_sufixo = local.split("+", 1)[0] or local
    if dominio in _GMAIL:
        sem_sufixo = sem_sufixo.replace(".", "") or sem_sufixo
        dominio = "gmail.com"
    return f"{sem_sufixo}@{dominio}"


def identidade(email: str | None, phone: str | None) -> str | None:
    """Quem é a pessoa, para o registro de testes. `None` se não há como saber.

    O telefone já chega normalizado (E.164) desde o cadastro.
    """
    if email:
        return f"email:{email_canonico(email)}"
    if phone:
        return f"tel:{phone.strip()}"
    return None


def resumo(ident: str) -> str:
    """O que vai ao banco no lugar da identidade.

    O prefixo separa este resumo de qualquer outro SHA-256 do sistema: o mesmo
    e-mail resumido para outro fim não pode servir de chave de busca aqui.
    """
    return hashlib.sha256(f"deskside:teste:{ident}".encode()).hexdigest()


def resumo_de_maquina_valido(valor: str | None) -> bool:
    """O agente mandou um resumo de verdade?

    Chega pela rede, de um programa que roda no computador de outra pessoa.
    Qualquer outra coisa é tratada como ausente — e ausente não corta teste de
    ninguém, que é o lado seguro para um agente antigo ou adulterado.
    """
    return bool(valor) and bool(_RESUMO.match(valor))


def ja_teve(db: Session, conta: str) -> bool:
    return (
        db.scalar(select(TesteConcedido.id).where(TesteConcedido.conta == conta).limit(1))
        is not None
    )


def registrar(db: Session, conta: str, maquina: str | None = None) -> None:
    """Anota que esta conta teve teste (e, se houver, em qual máquina).

    Idempotente: o mesmo par não é anotado duas vezes — a mesma pessoa
    reinstalando o agente no mesmo PC não pode contar como uma segunda.
    Não faz `commit`; quem chama decide quando gravar.
    """
    ja_existe = db.scalar(
        select(TesteConcedido.id)
        .where(TesteConcedido.conta == conta)
        .where(
            TesteConcedido.maquina.is_(None)
            if maquina is None
            else TesteConcedido.maquina == maquina
        )
        .limit(1)
    )
    if ja_existe is None:
        db.add(TesteConcedido(conta=conta, maquina=maquina))


def outras_contas_na_maquina(db: Session, maquina: str, exceto: str) -> int:
    """Quantas **outras** pessoas já tiveram teste neste computador."""
    return (
        db.scalar(
            select(func.count(func.distinct(TesteConcedido.conta)))
            .where(TesteConcedido.maquina == maquina)
            .where(TesteConcedido.conta != exceto)
        )
        or 0
    )


def plano_inicial(db: Session, email: str | None, phone: str | None):
    """`(plano, plano_ate)` para uma conta que está nascendo.

    Com teste se esta pessoa nunca teve um; grátis, sem prazo, se já teve.
    Anota o teste concedido na mesma sessão, para gravar junto com a conta.
    """
    ident = identidade(email, phone)
    if ident is None:
        return regras.Plano.PAGO, regras.fim_do_teste(datetime.now(UTC))
    conta = resumo(ident)
    if ja_teve(db, conta):
        return regras.Plano.GRATIS, None
    registrar(db, conta)
    return regras.Plano.PAGO, regras.fim_do_teste(datetime.now(UTC))


def ao_parear(db: Session, user: User, maquina: str | None) -> bool:
    """Confere o computador que acabou de ser pareado.

    Devolve `True` quando o teste da conta foi **encerrado** por causa dele —
    o app precisa saber, porque o plano mudou debaixo da pessoa e ela merece
    ouvir o porquê em vez de descobrir sozinha.

    Só age sobre conta **em teste**. Quem paga, quem tem cortesia e quem já
    está no grátis pareia o computador que quiser, e nada é anotado: o
    registro é de testes, não de computadores.
    """
    if not resumo_de_maquina_valido(maquina):
        return False
    if not cobranca.em_teste(db, user):
        return False
    ident = identidade(user.email, user.phone)
    if ident is None:
        return False
    conta = resumo(ident)

    if outras_contas_na_maquina(db, maquina, exceto=conta) >= LIMITE_POR_MAQUINA:
        user.plano = regras.Plano.GRATIS
        user.plano_ate = None
        db.commit()
        return True

    registrar(db, conta, maquina)
    db.commit()
    return False
