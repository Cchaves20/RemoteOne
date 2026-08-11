"""Hashing de senhas (bcrypt) e emissão/validação de tokens JWT.

Dois tipos de token: `access` (curta duração, usado nas requisições) e
`refresh` (longa duração, usado para obter novos access tokens). O campo
`type` no payload evita que um seja usado no lugar do outro.

Além do tipo, todo token carrega `tk`: a chave de sessão da conta
(`User.token_key`) no momento em que foi emitido. Quem valida compara com a que
está no banco, e é o que permite **cancelar** um JWT — sem isso, um refresh
token vale os 30 dias inteiros mesmo depois de a senha ser trocada.
"""

import hmac
import secrets
from datetime import UTC, datetime, timedelta

import bcrypt
import jwt
import pyotp

from app.config import settings

# bcrypt trunca senhas acima de 72 bytes; validamos o tamanho na entrada
# (schemas) para não haver truncamento silencioso.
_MAX_PASSWORD_BYTES = 72


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    return bcrypt.checkpw(password.encode(), hashed.encode())


def nova_chave_de_sessao() -> str:
    """Uma chave nova para `User.token_key` — no cadastro e a cada troca de senha.

    Aleatória, e não um contador que começa em zero, por causa de uma armadilha
    concreta: o SQLite reaproveita `INTEGER PRIMARY KEY`, então apagar a conta 1
    faz a próxima nascer como 1. Com contador, o token da conta apagada teria o
    mesmo `sub` e a mesma geração zero — e abriria a conta de outra pessoa.
    Sorteada, a chave da conta nova nunca coincide com a da que morreu.

    Não é segredo: ela viaja dentro do token, que já vai assinado. O que se pede
    dela é ser irrepetível.
    """
    return secrets.token_urlsafe(9)


def _create_token(
    subject: str, token_type: str, expires_delta: timedelta, key: str
) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": subject,
        "type": token_type,
        "tk": key,
        "iat": now,
        "exp": now + expires_delta,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_access_token(subject: str, key: str) -> str:
    return _create_token(
        subject, "access", timedelta(minutes=settings.access_token_ttl_minutes), key
    )


def create_refresh_token(subject: str, key: str) -> str:
    return _create_token(
        subject, "refresh", timedelta(days=settings.refresh_token_ttl_days), key
    )


def decode_token(token: str) -> dict:
    """Decodifica e valida a assinatura/expiração. Lança jwt.PyJWTError se inválido."""
    return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])


def chave_confere(payload: dict, esperada: str) -> bool:
    """O token traz a chave de sessão atual da conta?

    Token sem `tk` — emitido antes desta mudança — é recusado, de propósito.
    Aceitá-lo "por compatibilidade" abriria exatamente a porta que o campo
    existe para fechar: bastaria apresentar um token antigo para escapar do
    cancelamento. O preço é um login a mais, uma vez só, na primeira subida.

    Chave vazia também é recusada. Ela não deveria existir — a migração sorteia
    uma para cada conta antiga —, e se existisse, dois lados vazios se
    considerariam iguais.
    """
    apresentada = payload.get("tk")
    if not isinstance(apresentada, str) or not apresentada or not esperada:
        return False
    return hmac.compare_digest(apresentada, esperada)


# --- Verificação em duas etapas (TOTP) ---------------------------------------


def generate_totp_secret() -> str:
    """Gera um segredo base32 para o autenticador (TOTP)."""
    return pyotp.random_base32()


def totp_uri(secret: str, email: str) -> str:
    """URI otpauth:// para o QR Code do app autenticador."""
    return pyotp.TOTP(secret).provisioning_uri(name=email, issuer_name=settings.app_name)


def verify_totp(secret: str, code: str) -> bool:
    """Confere um código TOTP (aceita ±1 janela para tolerar relógio defasado)."""
    return pyotp.TOTP(secret).verify(code.strip(), valid_window=1)
