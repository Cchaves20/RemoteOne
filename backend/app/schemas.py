"""Schemas de entrada e saída da API de autenticação."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field


class Credentials(BaseModel):
    """Dados de cadastro/login. A senha é limitada a 72 bytes (limite do bcrypt).

    `totp_code` só é usado no login quando a conta tem 2FA ativo; no cadastro é
    ignorado.
    """

    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    totp_code: str | None = Field(default=None, max_length=10)


class TwoFactorSetupOut(BaseModel):
    """Segredo e URI (para QR Code) ao iniciar a configuração do 2FA."""

    secret: str
    otpauth_uri: str


class TwoFactorEnableRequest(BaseModel):
    """Confirma a ativação do 2FA com um código do autenticador."""

    code: str = Field(min_length=6, max_length=10)


class TwoFactorDisableRequest(BaseModel):
    """Desativa o 2FA (exige a senha atual)."""

    password: str = Field(min_length=1, max_length=72)


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
    totp_enabled: bool = False

    model_config = {"from_attributes": True}


class ClaimRequest(BaseModel):
    code: str = Field(min_length=1, max_length=16)


class RenameDeviceRequest(BaseModel):
    """Novo apelido do computador na conta."""

    name: str = Field(min_length=1, max_length=120)


class PowerRequest(BaseModel):
    """Ação de energia a ser executada no computador pareado."""

    action: Literal["shutdown", "restart", "suspend"]


class MediaRequest(BaseModel):
    """Tecla de mídia a acionar no computador pareado.

    São as teclas globais de um teclado multimídia: valem para quem estiver
    tocando som, sem precisar deixar o player em foco.
    """

    action: Literal["play_pause", "next", "previous", "volume_up", "volume_down", "mute"]


class SystemStatsOut(BaseModel):
    """Métricas do computador: CPU em %, o resto em bytes."""

    cpu_percent: float
    memory_used: int
    memory_total: int
    disk_used: int
    disk_total: int
    disk_name: str
    uptime_seconds: int


class FileEntryOut(BaseModel):
    """Um item de uma pasta do computador."""

    name: str
    path: str
    is_dir: bool
    size: int = 0


class ListingOut(BaseModel):
    """O conteúdo de uma pasta. `parent` ausente = já é a raiz permitida."""

    path: str
    parent: str | None = None
    entries: list[FileEntryOut] = []


class AppOut(BaseModel):
    """Um aplicativo do computador. `id` = caminho do atalho ou PID.

    `icon`: ícone real do programa em PNG base64 (quando disponível).
    """

    id: str
    name: str
    icon: str | None = None


class AppActionRequest(BaseModel):
    """Abrir (id = caminho do atalho) ou encerrar (id = PID) um aplicativo."""

    id: str = Field(min_length=1, max_length=1024)


class DeviceOut(BaseModel):
    device_id: str
    name: str
    os: str
    hostname: str
    created_at: datetime
    # Preenchido pela rota a partir das conexões vivas (não vem do banco).
    online: bool = False

    model_config = {"from_attributes": True}
