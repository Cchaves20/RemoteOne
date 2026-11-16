"""Quando uma compra na App Store ou na Play Store vale como plano pago.

Regra pura: sem FastAPI, sem banco, sem rede. O que fala com a Apple e com o
Google é `app/lojas.py`; o que atende HTTP é `app/compras.py`. Aqui só mora a
decisão — e é justamente a decisão que precisa ser testável sem servidor, sem
credencial e sem esperar um mês para a renovação chegar.

## O que este módulo assume, e por quê

**A loja é a fonte da verdade, e o aplicativo não é fonte de nada.** O que chega
do celular é um comprovante opaco; quem diz se ele é verdadeiro, de qual produto
e até quando vale é a Apple ou o Google. Um `Compra` só nasce da resposta da
loja — nunca do corpo de uma requisição.

**Cartão de crédito não passa por aqui, e não passa em lugar nenhum.** Quem
cobra é a loja; o Deskside recebe um identificador de transação e uma data de
validade. Não há número de cartão, nome do titular, CVV ou endereço de cobrança
para vazar, porque nada disso chega ao nosso servidor. É a maior vantagem de
segurança de vender pela loja, e vale escrever onde alguém leia.

## As quatro coisas que dão errado, e onde cada uma é barrada

1. **Compra de teste valendo como paga.** Apple e Google têm ambiente de
   sandbox com cartões falsos e assinaturas que renovam a cada cinco minutos.
   Um comprovante de sandbox aceito em produção é acesso pago de graça, para
   sempre, para qualquer pessoa. Ver `vale_como_pago`.

2. **Produto inventado.** O aplicativo diz qual produto foi comprado, e o
   aplicativo roda no aparelho de outra pessoa. Se a lista de produtos válidos
   não for conferida **contra a resposta da loja**, alguém compra o item mais
   barato que existir um dia e recebe o plano completo.

3. **Reembolso que não revoga.** A pessoa assina, usa, pede o dinheiro de volta
   pela loja — e continua paga porque a data de expiração ainda não chegou.
   Ver `Estado.REVOGADA`, que vence a data.

4. **Notificação repetida ou fora de ordem.** As lojas reenviam notificações
   quando não recebem confirmação, e não garantem ordem. Uma renovação chegando
   depois de um cancelamento reativaria a assinatura. Ver `deve_aplicar`.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum


class Loja(StrEnum):
    APPLE = "apple"
    GOOGLE = "google"


class Estado(StrEnum):
    """Em que pé a assinatura está, na visão da loja.

    Cinco e não dois, porque três destes valem como pago e dois não — e juntar
    tudo em "ativa/inativa" jogaria fora exatamente a informação que decide.
    """

    #: Renovando normalmente.
    ATIVA = "ativa"
    #: A cobrança falhou e a loja está tentando de novo. **Continua valendo**
    #: durante o período de graça: é o que a loja pretende, e cortar o acesso de
    #: quem teve um problema de cartão é a melhor forma de perder o cliente no
    #: dia em que ele mais precisaria que desse certo.
    EM_ATRASO = "em_atraso"
    #: A pessoa desligou a renovação. **Continua valendo até expirar** — ela
    #: pagou o mês. Cortar na hora do cancelamento é roubo, e gera reembolso.
    CANCELADA = "cancelada"
    #: Passou da validade sem renovar.
    EXPIRADA = "expirada"
    #: Reembolso, estorno ou compra removida da família. Acaba **na hora**,
    #: mesmo com data de validade no futuro.
    REVOGADA = "revogada"


class Ambiente(StrEnum):
    PRODUCAO = "producao"
    SANDBOX = "sandbox"


#: Os produtos que valem plano pago. Conferido contra o que a **loja** responde,
#: nunca contra o que o aplicativo afirma ter comprado.
#:
#: Um conjunto e não uma constante única porque o dia em que existir um plano
#: anual esta é a linha que muda — e porque um produto antigo, descontinuado,
#: precisa continuar valendo para quem já assinou.
PRODUTOS_PAGOS = frozenset(
    {
        "com.deskside.pro.mensal",
    }
)


@dataclass(frozen=True)
class Compra:
    """O que a loja respondeu, já normalizado entre Apple e Google.

    Congelado (`frozen=True`) de propósito: é o retrato de uma resposta, e
    retrato não se edita. Mudou o estado? A loja manda outra notificação, e ela
    vira outro `Compra`.
    """

    loja: Loja
    #: O identificador estável da assinatura na loja.
    #:
    #: Nunca vai ao banco em texto puro — ver `app/models.py`, que guarda o
    #: resumo criptográfico. Aqui ele existe porque é o que se acabou de receber
    #: da loja e é o que liga esta compra a uma conta.
    id_original: str
    product_id: str
    estado: Estado
    ambiente: Ambiente
    #: Até quando vale. `None` só aparece em compra revogada ou expirada, onde
    #: a data deixou de importar.
    expira_em: datetime | None
    #: O carimbo de tempo **da loja** para este evento, e não a hora em que o
    #: nosso servidor recebeu. É o que ordena notificações que chegam fora de
    #: ordem, e a hora local não serve: duas notificações podem chegar no mesmo
    #: milissegundo, ou na ordem trocada, sem que nada aqui perceba.
    visto_em: datetime


def em_utc(quando: datetime) -> datetime:
    """O SQLite devolve datetimes ingênuos; comparamos tudo em UTC.

    Público, ao contrário do gêmeo em `plano.py`, porque quem grava no banco
    precisa comparar datas com a mesma regra — e a alternativa era importar o
    `_aware` de outro módulo, que é pedir para alguém "reorganizar" isso um dia
    e trocar a semântica sem perceber.
    """
    return quando if quando.tzinfo is not None else quando.replace(tzinfo=UTC)


def produto_pago(product_id: str) -> bool:
    return product_id in PRODUTOS_PAGOS


def vale_como_pago(
    compra: Compra,
    agora: datetime | None = None,
    aceitar_sandbox: bool = False,
) -> bool:
    """Esta compra dá plano pago **agora**?

    A ordem das recusas é deliberada, da mais grave para a mais banal — quem
    ler daqui a um ano precisa ver primeiro o que protege dinheiro.
    """
    agora = agora or datetime.now(UTC)

    # 1. Reembolso vence data. Uma assinatura estornada com validade até o mês
    #    que vem não vale nada: o dinheiro voltou.
    if compra.estado is Estado.REVOGADA:
        return False

    # 2. Sandbox não paga. Este é o `if` que impede o plano pago de virar
    #    gratuito para qualquer pessoa com um aparelho de desenvolvedor: o
    #    ambiente de teste das lojas emite comprovantes válidos, assinados de
    #    verdade, com cartões que não existem.
    if compra.ambiente is Ambiente.SANDBOX and not aceitar_sandbox:
        return False

    # 3. Produto conferido contra a resposta da loja. O aplicativo roda no
    #    aparelho de outra pessoa e pode afirmar o que quiser.
    if not produto_pago(compra.product_id):
        return False

    if compra.estado is Estado.EXPIRADA or compra.expira_em is None:
        return False

    # Ativa, em atraso (graça) e cancelada valem enquanto a data não passou.
    return em_utc(compra.expira_em) > em_utc(agora)


def deve_aplicar(visto_em_atual: datetime | None, compra: Compra) -> bool:
    """Esta notificação é mais nova que a última que foi aplicada?

    As lojas reenviam notificações até receberem confirmação, e não prometem
    ordem. Sem esta comparação, três coisas quebram de uma vez:

    - uma renovação reenviada estenderia a validade duas vezes;
    - um `cancelou` chegando depois de um `renovou` desligaria uma assinatura
      que está de pé;
    - pior, um `renovou` antigo chegando depois de um `reembolsou` **religaria**
      o acesso de quem já recebeu o dinheiro de volta.

    Comparar carimbos da loja resolve os três com uma linha, e — diferente de
    "nunca desfaça uma revogação" — continua deixando alguém assinar de novo
    depois de ter cancelado, que é um cliente voltando e não uma fraude.
    """
    if visto_em_atual is None:
        return True
    return em_utc(compra.visto_em) > em_utc(visto_em_atual)


def ate_quando(compra: Compra, aceitar_sandbox: bool = False) -> datetime | None:
    """A data que vai para `User.plano_ate`, ou `None` para rebaixar a conta.

    Existe para o chamador não repetir a mesma cadeia de decisões: quem grava no
    banco pergunta uma coisa só, e a resposta já embute todas as recusas acima.
    """
    if not vale_como_pago(compra, aceitar_sandbox=aceitar_sandbox):
        return None
    return compra.expira_em
