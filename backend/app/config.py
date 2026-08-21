import os
import secrets

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

    # Autenticação. **Sem padrão de propósito** — ver `_segredo_de_emergencia`.
    jwt_secret: str = ""
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

    # Entrega do código de verificação do cadastro. Sem nada configurado, o
    # código vai para o diário do servidor — ver `app/entrega.py`.
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    twilio_sid: str = ""
    twilio_token: str = ""
    twilio_from: str = ""

    # Idade mínima para criar conta.
    #
    # Treze não é número escolhido a esmo: é o piso da LGPD para tratamento de
    # dados sem consentimento dos pais, e o mesmo que a maioria dos serviços
    # adota. Fica aqui, e não fixo no código, porque é decisão de produto e
    # jurídica — não de programação.
    idade_minima: int = 13


#: O valor que ficava aqui como padrão, e que agora é recusado explicitamente.
#: Está escrito no histórico do Git deste repositório, que é público — qualquer
#: pessoa que o leia consegue assinar um token válido para qualquer conta.
_SEGREDO_ANTIGO = "dev-insecure-secret-change-me"


def _segredo_de_emergencia(valor: str) -> str:
    """Devolve o segredo de assinatura, sorteando um se não houver.

    O padrão anterior era uma constante escrita neste arquivo. Isso **falha
    aberto**: esquecer `DESKSIDE_JWT_SECRET` no `.env` de produção não derrubava
    nada — o servidor subia, o `/health` respondia "ok", e os tokens passavam a
    ser assinados com uma senha publicada no GitHub. Ninguém erra nada visível,
    e qualquer pessoa que leia o repositório entra em qualquer conta.

    Recusar-se a subir seria a reação óbvia, mas troca um defeito silencioso por
    uma indisponibilidade total — e um `docker compose up` que não sobe às duas
    da manhã é a hora errada de descobrir isso.

    Então: **sorteia um segredo, e o sorteio é o alarme.** O servidor funciona,
    ninguém consegue forjar nada, e o sintoma é impossível de ignorar — todo
    mundo é deslogado a cada reinício, e o aviso está no diário. É um defeito
    que se anuncia em vez de esperar.
    """
    if valor and valor != _SEGREDO_ANTIGO:
        return valor
    motivo = (
        "DESKSIDE_JWT_SECRET não está definido"
        if not valor
        else f"DESKSIDE_JWT_SECRET ainda é {_SEGREDO_ANTIGO!r}, que é público"
    )
    print(
        f"AVISO DE SEGURANÇA: {motivo}. Sorteando um segredo temporário: "
        "as sessões vão cair a cada reinício do servidor até que um valor "
        "fixo seja posto no .env. Gere um com: openssl rand -base64 48"
    )
    return secrets.token_urlsafe(48)


settings = Settings()
settings.jwt_secret = _segredo_de_emergencia(settings.jwt_secret)
