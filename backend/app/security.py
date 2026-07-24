"""Hashing de senhas (bcrypt) e emissão/validação de tokens JWT.

Dois tipos de token: `access` (curta duração, usado nas requisições) e
`refresh` (longa duração, usado para obter novos access tokens). O campo
`type` no payload evita que um seja usado no lugar do outro.
"""

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


def _create_token(subject: str, token_type: str, expires_delta: timedelta) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": subject,
        "type": token_type,
        "iat": now,
        "exp": now + expires_delta,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_access_token(subject: str) -> str:
    return _create_token(
        subject, "access", timedelta(minutes=settings.access_token_ttl_minutes)
    )


def create_refresh_token(subject: str) -> str:
    return _create_token(
        subject, "refresh", timedelta(days=settings.refresh_token_ttl_days)
    )


def decode_token(token: str) -> dict:
    """Decodifica e valida a assinatura/expiração. Lança jwt.PyJWTError se inválido."""
    return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])


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
