"""O segundo fator: o código do autenticador ou um código de recuperação.

Um lugar só para as duas perguntas que antes se espalhavam pelo `auth.py` —
"este código vale?" e "esta ação exige código?" —, porque a verificação em duas
etapas só protege se **toda** porta que leva à conta a cobrar. Ela já era
cobrada no login, e não era em quatro outras:

- **Recuperar a senha.** Quem tomasse o e-mail ou o chip da pessoa (clonagem
  de chip é golpe comum) redefinia a senha e entrava, com a verificação ligada
  ou não. Num produto que controla computadores, isso é entregar os computadores.
- **Desligar a própria verificação**, **trocar o contato** e **trocar a senha**:
  com o celular da pessoa desbloqueado e a senha em mãos, bastavam estes para
  tomar a conta de vez.
- **Excluir a conta**, pelo mesmo motivo.

## Códigos de recuperação

Dez, de uso único, mostrados uma vez ao ligar a verificação. Sem eles, perder o
celular do autenticador era perder a conta — e a saída que existia era
justamente a recuperação de senha que pulava a verificação.

Guardados como HMAC com o segredo do servidor, como os códigos de verificação
(ver `verificacao.resumo`): quem tiver só o banco não tem como testá-los. Dez
caracteres de 31 possíveis dão ~49 bits, sem chance de adivinhar pela rede.

## Reuso do código do autenticador

Um código de seis dígitos vale por um minuto e meio (a janela de 30 s mais uma
de cada lado, para relógio adiantado). Sem lembrar qual já foi usado, quem o
visse na tela de outra pessoa poderia entrar com ele logo depois. Guarda-se o
último passo aceito, e só um passo **posterior** passa.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
from datetime import UTC, datetime

import pyotp
from fastapi import HTTPException, status

from app import cofre
from app.config import settings
from app.models import User

#: Quantos códigos de recuperação se geram de uma vez.
QUANTOS_CODIGOS = 10

# Sem caracteres ambíguos (0/O, 1/I/L), como o código de pareamento: estes se
# copiam de um papel, e um "O" lido como zero trancaria a pessoa para fora.
_ALFABETO = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_METADE = 5

#: Os detalhes que o app reconhece (os mesmos do login).
FALTA_CODIGO = "two_factor_required"
CODIGO_ERRADO = "two_factor_invalid"


def _resumo(codigo: str) -> str:
    return hmac.new(
        settings.jwt_secret.encode(), b"recuperacao:" + codigo.encode(), hashlib.sha256
    ).hexdigest()


def _normalizar(codigo: str) -> str:
    """Maiúsculas, sem espaço nem traço: `abcde fghjk` e `ABCDE-FGHJK` são o mesmo."""
    return "".join(c for c in codigo.upper() if c.isalnum())


def gerar_codigos(user: User) -> list[str]:
    """Gera códigos novos, **substituindo** os anteriores, e os devolve.

    Substituir é o comportamento certo: quem pede códigos novos desconfia dos
    antigos (perdeu o papel, alguém viu), e mantê-los válidos tiraria o sentido
    de pedir.
    """
    codigos = []
    for _ in range(QUANTOS_CODIGOS):
        bruto = "".join(secrets.choice(_ALFABETO) for _ in range(_METADE * 2))
        codigos.append(f"{bruto[:_METADE]}-{bruto[_METADE:]}")
    user.recovery_codes = json.dumps([_resumo(_normalizar(c)) for c in codigos])
    return codigos


def restantes(user: User) -> int:
    return len(_resumos(user))


def _resumos(user: User) -> list[str]:
    try:
        lista = json.loads(user.recovery_codes or "[]")
    except ValueError:
        return []
    return [r for r in lista if isinstance(r, str)]


def _usar_codigo_de_recuperacao(user: User, codigo: str) -> bool:
    normal = _normalizar(codigo)
    if len(normal) != _METADE * 2:
        return False
    alvo = _resumo(normal)
    resumos = _resumos(user)
    for guardado in resumos:
        if hmac.compare_digest(guardado, alvo):
            resumos.remove(guardado)
            user.recovery_codes = json.dumps(resumos)
            return True
    return False


def _passo_do_totp(segredo: str, codigo: str, agora: datetime) -> int | None:
    """O passo de 30 s em que este código vale, ou `None`.

    Confere a janela atual e uma de cada lado, como o `verify` do `pyotp` com
    `valid_window=1` — mas devolvendo **qual** passo bateu, que é o que permite
    recusar um código já usado.
    """
    codigo = codigo.strip()
    if not (len(codigo) == 6 and codigo.isdigit()):
        return None
    totp = pyotp.TOTP(segredo)
    atual = totp.timecode(agora)
    for passo in (atual - 1, atual, atual + 1):
        if hmac.compare_digest(totp.generate_otp(passo), codigo):
            return passo
    return None


def confere(user: User, codigo: str | None, agora: datetime | None = None) -> str | None:
    """Confere o segundo fator e o **consome**.

    Devolve `"totp"` ou `"recuperacao"` quando vale, e `None` quando não. Quem
    chama precisa gravar a conta depois: um código aceito muda o estado (o passo
    usado, ou o código de recuperação que deixa de existir).
    """
    if not codigo:
        return None
    agora = agora or datetime.now(UTC)
    segredo = cofre.abrir(user.totp_secret) or ""
    if segredo:
        passo = _passo_do_totp(segredo, codigo, agora)
        if passo is not None:
            if user.totp_ultimo_passo is not None and passo <= user.totp_ultimo_passo:
                # Já usado (ou um anterior a um já usado). Recusado como um
                # código errado qualquer: dizer "já usado" confirmaria a quem o
                # copiou que ele era válido.
                return None
            user.totp_ultimo_passo = passo
            return "totp"
    if _usar_codigo_de_recuperacao(user, codigo):
        return "recuperacao"
    return None


def exigir(user: User, codigo: str | None, ao_errar=None) -> str | None:
    """Barra a ação se a conta tem verificação e o código não veio ou não vale.

    Conta sem verificação passa direto (devolve `None`). `ao_errar` é chamado
    antes de recusar um código **errado** — é onde quem chama registra a
    tentativa no limite, porque seis dígitos sem limite se adivinham.
    """
    if not user.totp_enabled:
        return None
    if not codigo:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=FALTA_CODIGO)
    tipo = confere(user, codigo)
    if tipo is None:
        if ao_errar is not None:
            ao_errar()
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=CODIGO_ERRADO)
    return tipo
