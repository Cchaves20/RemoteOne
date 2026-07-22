"""Schemas de entrada e saída da API de autenticação."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field


class Credentials(BaseModel):
    """Dados de cadastro/login. A senha é limitada a 72 bytes (limite do bcrypt)."""

    email: EmailStr
    password: str = Field(min_length=8, max_length=72)


class UpdateEmailRequest(BaseModel):
    """Troca de e-mail: exige a senha atual para confirmar a identidade."""

    current_password: str = Field(min_length=1, max_length=72)
    new_email: EmailStr


class UpdatePasswordRequest(BaseModel):
    """Troca de senha: exige a senha atual e a nova (mesmo limite do bcrypt)."""

    current_password: str = Field(min_length=1, max_length=72)
    new_password: str = Field(min_length=8, max_length=72)


class DeleteAccountRequest(BaseModel):
    """Exclusão de conta: exige a senha atual como confirmação."""

    password: str = Field(min_length=1, max_length=72)


class RefreshRequest(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class AccessToken(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(BaseModel):
    id: int
    email: EmailStr
    created_at: datetime

    model_config = {"from_attributes": True}


class ClaimRequest(BaseModel):
    code: str = Field(min_length=1, max_length=16)


class RenameDeviceRequest(BaseModel):
    """Novo apelido do computador na conta."""

    name: str = Field(min_length=1, max_length=120)


class PowerRequest(BaseModel):
    """Ação de energia a ser executada no computador pareado."""

    action: Literal["shutdown", "restart", "suspend"]


class DeviceOut(BaseModel):
    device_id: str
    name: str
    os: str
    hostname: str
    created_at: datetime
    # Preenchido pela rota a partir das conexões vivas (não vem do banco).
    online: bool = False

    model_config = {"from_attributes": True}
