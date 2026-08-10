"""O código de seis dígitos: gerar, guardar, conferir, expirar.

Separado das rotas porque é aqui que moram as decisões que protegem o cadastro,
e elas se testam sem HTTP nenhum.

**Por que seis dígitos e não um link.** Um link por e-mail seria mais cômodo e
não serve: o cadastro por telefone chega por SMS, onde não há link que devolva
a pessoa ao app instalado por sideload. Um mecanismo só para os dois caminhos
vale mais do que dois mecanismos, e seis dígitos é o que a pessoa consegue ler
do aviso na tela e digitar sem trocar de aplicativo.
"""

import hashlib
import hmac
import secrets
from datetime import UTC, datetime, timedelta

from app.config import settings

#: Dez minutos: sobra para achar o e-mail na caixa de spam e não sobra para um
#: código esquecido numa tela continuar valendo no dia seguinte.
VALIDADE = timedelta(minutes=10)

#: Erros antes de o cadastro pendente ser descartado.
#:
#: Cinco é generoso para quem digitou errado e curto para quem está adivinhando:
#: com um milhão de combinações e cinco tentativas por cadastro, a chance é de
#: uma em duzentas mil — e recomeçar gera outro código.
MAX_TENTATIVAS = 5

#: Espera entre reenvios. Não é só antiabuso: cada SMS custa dinheiro, e o botão
#: de reenviar é exatamente o que se aperta repetidamente quando a mensagem
#: demora.
ESPERA_REENVIO = timedelta(seconds=60)

_DIGITOS = 6


def gerar() -> str:
    """Seis dígitos, do gerador criptográfico.

    `secrets` e não `random`: o `random` do Python é o Mersenne Twister, cuja
    sequência inteira se deduz de algumas saídas. Para um código que autoriza a
    criação de uma conta, isso não serve — e o certo aqui custa a mesma linha.

    Zeros à esquerda são preservados (`004821`): cortá-los daria códigos de
    tamanho variável, e a tela que espera seis dígitos recusaria o próprio
    código que o servidor mandou.
    """
    return f"{secrets.randbelow(10**_DIGITOS):0{_DIGITOS}d}"


def resumo(codigo: str) -> str:
    """O código como se guarda: HMAC-SHA256 com o segredo do servidor.

    **Não é bcrypt, e é de propósito.** Bcrypt existe para tornar cara cada
    tentativa de adivinhar uma senha a partir do hash. Aqui o espaço é de um
    milhão de combinações: quem tiver o banco testa todas em qualquer hash
    rápido, e com bcrypt testa todas em algumas horas. Bcrypt não salva um
    segredo de seis dígitos — só torna o cadastro lento (duas passagens de
    bcrypt por conta criada).

    O que **de fato** protege é a chave: sem o segredo do servidor, o milhão de
    combinações não ajuda, porque não dá para calcular nenhum HMAC. Um segredo
    curto guardado sob chave vale mais que um segredo curto sob hash caro.

    `compare_digest` na comparação, e não `==`, para o tempo da comparação não
    contar quantos caracteres iniciais estavam certos.
    """
    return hmac.new(
        settings.jwt_secret.encode(), codigo.encode(), hashlib.sha256
    ).hexdigest()


def confere(codigo: str, resumo_guardado: str) -> bool:
    return hmac.compare_digest(resumo(codigo), resumo_guardado)


def prazo(agora: datetime | None = None) -> datetime:
    return (agora or datetime.now(UTC)) + VALIDADE


def expirou(limite: datetime, agora: datetime | None = None) -> bool:
    """Se o prazo passou.

    O `_aware` existe porque o SQLite devolve datas **sem fuso**, mesmo tendo
    sido gravadas com um. Comparar uma data ingênua com uma consciente estoura
    `TypeError` — e estouraria dentro de uma rota de cadastro, virando 500 numa
    conferência que deveria só dizer "expirou".
    """
    return _aware(limite) <= (agora or datetime.now(UTC))


def pode_reenviar(ultimo_envio: datetime, agora: datetime | None = None) -> bool:
    return (agora or datetime.now(UTC)) - _aware(ultimo_envio) >= ESPERA_REENVIO


def segundos_para_reenviar(ultimo_envio: datetime, agora: datetime | None = None) -> int:
    """Quanto falta, para a tela mostrar a contagem em vez de um "espere"."""
    falta = ESPERA_REENVIO - ((agora or datetime.now(UTC)) - _aware(ultimo_envio))
    return max(0, int(falta.total_seconds() + 0.999))


def _aware(quando: datetime) -> datetime:
    return quando if quando.tzinfo else quando.replace(tzinfo=UTC)
