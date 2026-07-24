"""Rotas de autenticação: cadastro, login, refresh de token e /me.

Esta é a fundação de e-mail + senha com JWT. Os métodos externos (Google,
Apple, Microsoft) e o 2FA entram por cima desta base: os provedores OAuth
apenas produzem/validam a identidade e então reaproveitam a mesma emissão de
tokens (`create_access_token`/`create_refresh_token`) usada aqui.
"""

import jwt
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import User
from app.schemas import (
    AccessToken,
    Credentials,
    DeleteAccountRequest,
    RefreshRequest,
    TokenPair,
    TwoFactorDisableRequest,
    TwoFactorEnableRequest,
    TwoFactorSetupOut,
    UpdateEmailRequest,
    UpdatePasswordRequest,
    UserOut,
)
from app.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    generate_totp_secret,
    hash_password,
    totp_uri,
    verify_password,
    verify_totp,
)

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])
_bearer = HTTPBearer(auto_error=True)


def _tokens_for(user: User) -> TokenPair:
    subject = str(user.id)
    return TokenPair(
        access_token=create_access_token(subject),
        refresh_token=create_refresh_token(subject),
    )


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
    db: Session = Depends(get_db),
) -> User:
    """Resolve o usuário autenticado a partir do access token (Bearer)."""
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="credenciais inválidas",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_token(credentials.credentials)
    except jwt.PyJWTError as exc:
        raise invalid from exc

    if payload.get("type") != "access":
        raise invalid

    user = db.get(User, int(payload["sub"]))
    if user is None:
        raise invalid
    return user


@router.post("/register", response_model=TokenPair, status_code=status.HTTP_201_CREATED)
def register(body: Credentials, db: Session = Depends(get_db)) -> TokenPair:
    existing = db.scalar(select(User).where(User.email == body.email))
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="e-mail já cadastrado"
        )
    user = User(email=body.email, hashed_password=hash_password(body.password))
    db.add(user)
    db.commit()
    db.refresh(user)
    return _tokens_for(user)


@router.post("/login", response_model=TokenPair)
def login(body: Credentials, db: Session = Depends(get_db)) -> TokenPair:
    user = db.scalar(select(User).where(User.email == body.email))
    if user is None or not verify_password(body.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="e-mail ou senha inválidos",
        )
    # 2FA: com a senha correta, ainda exige o código do autenticador. O app
    # reconhece os detalhes "two_factor_required"/"two_factor_invalid".
    if user.totp_enabled:
        if not body.totp_code:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, detail="two_factor_required"
            )
        if not verify_totp(user.totp_secret or "", body.totp_code):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, detail="two_factor_invalid"
            )
    return _tokens_for(user)


@router.post("/refresh", response_model=AccessToken)
def refresh(body: RefreshRequest, db: Session = Depends(get_db)) -> AccessToken:
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="refresh token inválido"
    )
    try:
        payload = decode_token(body.refresh_token)
    except jwt.PyJWTError as exc:
        raise invalid from exc

    if payload.get("type") != "refresh":
        raise invalid
    user = db.get(User, int(payload["sub"]))
    if user is None:
        raise invalid
    return AccessToken(access_token=create_access_token(str(user.id)))


@router.get("/me", response_model=UserOut)
def me(current_user: User = Depends(get_current_user)) -> User:
    return current_user


@router.patch("/me/email", response_model=UserOut)
def update_email(
    body: UpdateEmailRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Troca o e-mail da conta (exige a senha atual)."""
    if not verify_password(body.current_password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha atual incorreta"
        )
    if body.new_email != current_user.email:
        taken = db.scalar(select(User).where(User.email == body.new_email))
        if taken is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="e-mail já cadastrado"
            )
        current_user.email = body.new_email
        db.commit()
        db.refresh(current_user)
    return current_user


@router.patch("/me/password", status_code=status.HTTP_204_NO_CONTENT)
def update_password(
    body: UpdatePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Troca a senha da conta (exige a senha atual)."""
    if not verify_password(body.current_password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha atual incorreta"
        )
    current_user.hashed_password = hash_password(body.new_password)
    db.commit()


@router.post("/2fa/setup", response_model=TwoFactorSetupOut)
def two_factor_setup(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TwoFactorSetupOut:
    """Gera um segredo TOTP e o URI para o QR Code. Ainda não ativa o 2FA."""
    if current_user.totp_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="2FA já está ativo"
        )
    secret = generate_totp_secret()
    current_user.totp_secret = secret  # pendente até confirmar o código
    db.commit()
    return TwoFactorSetupOut(secret=secret, otpauth_uri=totp_uri(secret, current_user.email))


@router.post("/2fa/enable", status_code=status.HTTP_204_NO_CONTENT)
def two_factor_enable(
    body: TwoFactorEnableRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Ativa o 2FA confirmando um código do autenticador."""
    if current_user.totp_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="2FA já está ativo"
        )
    if not current_user.totp_secret:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="inicie a configuração do 2FA antes",
        )
    if not verify_totp(current_user.totp_secret, body.code):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="código inválido"
        )
    current_user.totp_enabled = True
    db.commit()


@router.post("/2fa/disable", status_code=status.HTTP_204_NO_CONTENT)
def two_factor_disable(
    body: TwoFactorDisableRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Desativa o 2FA (exige a senha atual) e apaga o segredo."""
    if not verify_password(body.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha incorreta"
        )
    current_user.totp_enabled = False
    current_user.totp_secret = None
    db.commit()


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(
    body: DeleteAccountRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Exclui a conta e todos os dispositivos vinculados (exige a senha)."""
    if not verify_password(body.password, current_user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="senha incorreta"
        )
    db.delete(current_user)
    db.commit()
