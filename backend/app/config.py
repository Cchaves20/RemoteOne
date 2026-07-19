from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuração via variáveis de ambiente (prefixo REMOTEONE_)."""

    model_config = SettingsConfigDict(env_prefix="REMOTEONE_")

    app_name: str = "RemoteOne Backend"
    version: str = "0.1.0"
    database_url: str = "postgresql://remoteone:remoteone@localhost:5432/remoteone"
    redis_url: str = "redis://localhost:6379/0"


settings = Settings()
