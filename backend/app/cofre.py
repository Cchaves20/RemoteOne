"""Cifra em repouso para o que o banco não devia guardar em texto puro.

Hoje só o segredo do TOTP passa por aqui, e ele é o caso que mais pede: o 2FA
existe justamente para o cenário em que a senha vazou. Se o segredo do
autenticador estiver no mesmo arquivo que o hash da senha, os dois caem juntos
e a segunda etapa deixa de ser segunda.

## Por que isto ajuda, se a chave mora na mesma máquina

Ajuda porque o que sai da máquina é o **banco**, não o `.env`. A cópia diária
leva `deskside.db` para o computador de quem administra, e de lá para uma nuvem,
um pendrive, um e-mail. A chave fica em `deploy/.env`, que não é versionado nem
copiado pelo backup. É o vazamento realista que esta cifra cobre.

Contra quem já está dentro da VM, não protege nada — e nada protegeria.

## As duas coisas que dariam errado, e como cada uma é evitada

**Trocar a chave trancaria todo mundo.** Um segredo cifrado com a chave antiga
vira lixo com a nova, e quem usa 2FA não consegue mais entrar. Por isso a
abertura tenta **todas** as chaves configuradas, e a gravação usa a primeira:
acrescentar uma chave nova é seguro, e a antiga só sai depois que tudo tiver
sido regravado.

**Cifrar em silêncio o que não dá para decifrar depois.** Cada valor guardado
leva a marca `enc1:`. Sem marca é texto puro — de antes desta mudança — e é
devolvido como está. É o que permite a migração acontecer sem parada.
"""

import base64
import hashlib
import logging

from cryptography.fernet import Fernet, InvalidToken

from app.config import settings

logger = logging.getLogger("deskside")

#: Prefixo que distingue "cifrado por aqui" de "texto puro de antes".
MARCA = "enc1:"


def _chave_de(base: str) -> bytes:
    """Transforma um segredo qualquer numa chave no formato que o Fernet exige.

    O `totp:` na frente não é enfeite: sem ele, a chave desta cifra seria
    *literalmente* o segredo de assinatura dos tokens, e um vazamento de um
    viraria vazamento do outro. Com o prefixo, uma coisa não devolve a outra.
    """
    return base64.urlsafe_b64encode(hashlib.sha256(f"totp:{base}".encode()).digest())


def _chaves() -> list[bytes]:
    """As chaves em uso: a primeira grava, todas abrem.

    Sem `DESKSIDE_TOTP_KEY` configurada, deriva do segredo dos tokens. Não é o
    ideal — o certo é uma chave própria —, mas é o que faz isto funcionar sem
    nenhuma mudança no `.env` de quem já está no ar. E a derivada continua na
    lista depois que uma chave própria for definida, senão definir uma trancaria
    todo mundo que já tinha 2FA.
    """
    chaves = []
    propria = getattr(settings, "totp_key", "")
    if propria:
        chaves.append(_chave_de(propria))
    chaves.append(_chave_de(settings.jwt_secret))
    return chaves


def guardar(texto: str) -> str:
    """Cifra um segredo para ir ao banco."""
    return MARCA + Fernet(_chaves()[0]).encrypt(texto.encode()).decode()


def abrir(guardado: str | None) -> str | None:
    """Decifra o que veio do banco. `None` quando não dá para abrir.

    Devolver `None` em vez de levantar é deliberado, e o efeito é **fechar**, não
    abrir: quem chama usa isto para conferir um código de 2FA, e um segredo
    ausente reprova o código. O contrário — deixar passar quando não dá para
    conferir — transformaria uma chave perdida num contorno do 2FA.
    """
    if guardado is None:
        return None
    if not guardado.startswith(MARCA):
        return guardado  # texto puro, de antes desta mudança
    token = guardado[len(MARCA):].encode()
    for chave in _chaves():
        try:
            return Fernet(chave).decrypt(token).decode()
        except InvalidToken:
            continue
    logger.error(
        "não consegui decifrar um segredo de 2FA: nenhuma chave configurada serve. "
        "A chave mudou? Acrescente a anterior em DESKSIDE_TOTP_KEY, ou desligue o "
        "2FA desta conta no banco para destravá-la."
    )
    return None


def esta_cifrado(guardado: str | None) -> bool:
    return bool(guardado) and guardado.startswith(MARCA)
