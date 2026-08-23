"""O que a versão grátis faz, o que a paga faz, e quando cada conta está em qual.

## O desenho, e o porquê de cada linha

**Grátis é permanente, não um teste que expira.** Um teste que acaba produz uma
tela de "acabou" que a pessoa fecha e desinstala; um plano grátis produz alguém
que continua usando, conta para os outros, e um dia esbarra num limite.

**Mas toda conta nasce com 30 dias do plano pago**, e depois cai para o grátis —
nunca para bloqueada. Quem provou um recurso e o perdeu converte muito melhor do
que quem nunca o teve, e o custo de errar aqui é zero: ninguém fica na mão.

**A tela ao vivo é grátis**, apesar de ser o que mais custa em banda. É o que faz
a pessoa mostrar o produto para alguém — e essa demonstração é o marketing.
Cortá-la economizaria pouco (as contas estão em `docs/custos-para-distribuir.md`)
e mataria o boca a boca.

**Nada de segurança entra na lista.** 2FA, revogação de sessão, o botão de
desinstalar: cobrar por proteção é o tipo de decisão que aparece no Reddit.

**E nada de limite de tempo por sessão.** É a tentação óbvia e o erro clássico —
transforma a demonstração numa interrupção, exatamente no instante em que a
pessoa ia se impressionar.

## Onde isto é aplicado

**No servidor, e só no servidor.** O app é código que roda no aparelho de outra
pessoa: esconder um botão lá é apresentação, não regra. Aqui é onde a regra
existe de verdade, e é por isso que este módulo não sabe desenhar nada.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from enum import StrEnum

#: Quanto tempo de plano pago toda conta nova ganha.
#:
#: Contado do **cadastro**, e não do primeiro pareamento, porque é o cadastro
#: que o servidor observa sem ambiguidade. Trinta dias é folgado o bastante para
#: a diferença entre os dois não decidir nada.
TESTE_DIAS = 30

#: Quantos computadores a versão grátis alcança.
#:
#: Um, e é o limite mais eficaz que existe: é esbarrado uma vez, com força, por
#: quem **já gostou** — e é honesto, porque quem tem dois computadores tira o
#: dobro de valor. Zero seria um demo; dois nunca seria esbarrado.
MAX_DISPOSITIVOS_GRATIS = 1

#: Quantas automações a versão grátis guarda.
#:
#: Uma, para o recurso ser conhecido e não apenas anunciado. Quem só ouviu falar
#: não sente falta; quem usou uma vez e quer a segunda, sim.
MAX_AUTOMACOES_GRATIS = 1


class Plano(StrEnum):
    GRATIS = "gratis"
    PAGO = "pago"


class Recurso(StrEnum):
    """O que existe só no plano pago.

    O que **não** está aqui é tão importante quanto o que está: mouse, teclado,
    tela ao vivo, abrir e fechar programas e área de transferência são grátis, e
    é essa lista que faz o produto valer a instalação antes de valer o dinheiro.
    """

    #: A automação que roda sozinha na hora marcada. O melhor recurso pago do
    #: produto: é desejado repetidamente, e um desejo semanal converte melhor
    #: que um desejo único.
    AGENDAR = "agendar"
    ARQUIVOS = "arquivos"
    APRESENTACAO = "apresentacao"
    AUDIO = "audio"
    PERFIS = "perfis"
    MONITORES = "monitores"


def _aware(quando: datetime) -> datetime:
    """O SQLite devolve datetimes ingênuos; comparamos tudo em UTC."""
    return quando if quando.tzinfo is not None else quando.replace(tzinfo=UTC)


def fim_do_teste(criada_em: datetime) -> datetime:
    return _aware(criada_em) + timedelta(days=TESTE_DIAS)


def plano_efetivo(
    plano: str | None, plano_ate: datetime | None, agora: datetime | None = None
) -> Plano:
    """Em que plano a conta está **agora**.

    Duas fontes, e a data manda: uma assinatura com validade vencida vale tanto
    quanto nenhuma. Guardar só o rótulo `pago` obrigaria uma tarefa noturna a
    rebaixar contas — e uma tarefa que não roda deixa gente pagando de graça
    sem ninguém perceber.

    `plano_ate` nulo com plano pago significa **sem prazo**: é como se liga uma
    conta à mão antes de existir cobrança automática.
    """
    agora = agora or datetime.now(UTC)
    if plano != Plano.PAGO:
        return Plano.GRATIS
    if plano_ate is None:
        return Plano.PAGO
    return Plano.PAGO if _aware(plano_ate) > _aware(agora) else Plano.GRATIS


def permite(plano: Plano, recurso: Recurso) -> bool:
    """O plano alcança este recurso?

    Uma linha só, e de propósito: a lista de recursos pagos é a própria
    `Recurso`. Uma tabela separada aqui seria uma segunda verdade sobre o mesmo
    assunto, e um dia as duas discordariam.
    """
    return plano == Plano.PAGO


def limite_de_dispositivos(plano: Plano) -> int | None:
    """Quantos computadores o plano alcança. `None` é sem limite."""
    return None if plano == Plano.PAGO else MAX_DISPOSITIVOS_GRATIS


def limite_de_automacoes(plano: Plano) -> int | None:
    return None if plano == Plano.PAGO else MAX_AUTOMACOES_GRATIS


def cabe(quantidade_atual: int, limite: int | None) -> bool:
    """Ainda cabe mais um?

    Compara com `>=` porque `quantidade_atual` é o que já existe **antes** de
    criar. Com `>`, o limite de um deixaria criar dois — o erro clássico de
    contar depois em vez de antes.
    """
    return limite is None or quantidade_atual < limite


#: Como cada recurso pago se apresenta a quem não o tem.
#:
#: O texto fica no servidor porque é ele quem recusa, e a recusa precisa dizer
#: **o que** foi recusado. Um "403" seco faria o app inventar uma explicação, e
#: um dia a explicação inventada estaria errada.
NOMES = {
    Recurso.AGENDAR: "automação em horário marcado",
    Recurso.ARQUIVOS: "transferência de arquivos",
    Recurso.APRESENTACAO: "modo apresentação",
    Recurso.AUDIO: "som do computador",
    Recurso.PERFIS: "perfis de controle",
    Recurso.MONITORES: "escolher o monitor",
}


def motivo(recurso: Recurso) -> str:
    """A frase que a pessoa lê quando esbarra no limite.

    Diz o nome do recurso e o que fazer. "Recurso indisponível" seria verdade e
    inútil: quem lê não sabe se é defeito, se é o computador dele, ou se é
    dinheiro.
    """
    return f"{NOMES[recurso]} faz parte do Deskside pago"


def motivo_do_limite(quantos: int, o_que: str) -> str:
    plural = "" if quantos == 1 else "s"
    return (
        f"a versão grátis do Deskside vai até {quantos} {o_que}{plural}; "
        "o plano pago não tem limite"
    )
