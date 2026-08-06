import os

from pydantic_settings import BaseSettings, SettingsConfigDict


def _herdar_prefixo_antigo() -> None:
    """Aceita as variáveis com o prefixo antigo, do tempo do nome RemoteOne.

    Sem isto a renomeação teria um efeito silencioso e grave: o `.env` do
    servidor guarda `REMOTEONE_JWT_SECRET`, o código passaria a procurar
    `DESKSIDE_JWT_SECRET`, não acharia, e cairia no **padrão inseguro** que
    existe aqui só para desenvolvimento. O backend subiria normalmente,
    respondendo `/health` com "ok", assinando tokens com um segredo que está
    escrito neste arquivo público - e derrubando toda sessão existente.

    Um erro de operação não pode ter esse desfecho. Aqui o valor antigo é
    aceito e o aviso aparece, em vez de o servidor fingir que está tudo bem.

    Some daqui quando o `.env` do servidor tiver sido atualizado.
    """
    for chave, valor in list(os.environ.items()):
        if not chave.startswith("REMOTEONE_") or not valor:
            continue
        nova = "DESKSIDE_" + chave[len("REMOTEONE_"):]
        if not os.environ.get(nova):
            os.environ[nova] = valor
            print(f"aviso: usando {chave}; renomeie para {nova} no .env")


_herdar_prefixo_antigo()


class Settings(BaseSettings):
    """Configuração via variáveis de ambiente (prefixo DESKSIDE_)."""

    model_config = SettingsConfigDict(env_prefix="DESKSIDE_")

    app_name: str = "Deskside Backend"
    version: str = "0.1.0"
    database_url: str = "postgresql://deskside:deskside@localhost:5432/deskside"
    redis_url: str = "redis://localhost:6379/0"

    # Autenticação. O segredo PRECISA ser trocado em produção (via
    # DESKSIDE_JWT_SECRET); o valor padrão serve apenas para desenvolvimento.
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
    # DESKSIDE_STREAM_FPS/QUALITY/MAX_WIDTH para ajuste fino).
    stream_fps: int = 60


settings = Settings()
