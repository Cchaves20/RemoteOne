"""Schemas de entrada e saída da API de autenticação."""

from datetime import datetime

from pydantic import BaseModel, EmailStr, Field


class Credentials(BaseModel):
    """Dados de cadastro/login. A senha é limitada a 72 bytes (limite do bcrypt)."""

    email: EmailStr
    password: str = Field(min_length=8, max_length=72)


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


class DeviceOut(BaseModel):
    device_id: str
    name: str
    os: str
    hostname: str
    created_at: datetime

    model_config = {"from_attributes": True}
