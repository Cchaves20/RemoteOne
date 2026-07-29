from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuração via variáveis de ambiente (prefixo REMOTEONE_)."""

    model_config = SettingsConfigDict(env_prefix="REMOTEONE_")

    app_name: str = "RemoteOne Backend"
    version: str = "0.1.0"
    database_url: str = "postgresql://remoteone:remoteone@localhost:5432/remoteone"
    redis_url: str = "redis://localhost:6379/0"

    # Autenticação. O segredo PRECISA ser trocado em produção (via
    # REMOTEONE_JWT_SECRET); o valor padrão serve apenas para desenvolvimento.
    jwt_secret: str = "dev-insecure-secret-change-me"
    jwt_algorithm: str = "HS256"
    access_token_ttl_minutes: int = 15
    refresh_token_ttl_days: int = 30

    # Validade do código de pareamento exibido pelo agente.
    pairing_ttl_seconds: int = 600

    # ICE: STUN sempre, TURN quando configurado (Fase 5 do plano de WebRTC).
    # Sem turn_host/turn_secret o backend entrega só o STUN, como antes.
    stun_urls: list[str] = ["stun:stun.l.google.com:19302"]
    turn_host: str = ""
    turn_port: int = 3478
    turn_secret: str = ""
    # 12 h: cobre uma sessão longa com folga, e uma credencial vazada morre no
    # mesmo dia. A renegociação pega uma nova.
    turn_ttl_seconds: int = 12 * 3600

    # fps alvo informado ao agente ao transmitir a tela (o agente também aceita
    # REMOTEONE_STREAM_FPS/QUALITY/MAX_WIDTH para ajuste fino).
    stream_fps: int = 60


settings = Settings()
