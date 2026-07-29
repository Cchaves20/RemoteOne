"""Servidores ICE (STUN e TURN) entregues ao app e ao agente.

O STUN só **descobre** o endereço público de cada lado; quando os dois estão
atrás de NAT que não deixa nada entrar - celular no 5G da operadora e
computador atrás do roteador de casa é exatamente esse caso -, nenhum par de
candidatos fecha e o vídeo direto nunca sobe. O TURN resolve pelo caminho mais
caro possível: o servidor **relaya** o tráfego. É a última opção do ICE, e por
isso não custa nada quando o P2P funciona.

As credenciais são temporárias, no esquema que o coturn chama de
`use-auth-secret`: o servidor não guarda usuário nenhum, e sim confere um HMAC
do próprio nome de usuário (que carrega a hora de expiração). Ninguém precisa
gerenciar senha, e uma credencial vazada morre sozinha.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import time

from app.config import settings


def _credential(tag: str, ttl_seconds: int, secret: str) -> tuple[str, str]:
    """Usuário e senha temporários no formato que o coturn espera.

    O usuário é `<expira em unix>:<quem>`; a senha é o HMAC-SHA1 dele com o
    segredo compartilhado, em base64. O servidor recalcula e compara - não há
    consulta a banco nenhum.
    """
    expira = int(time.time()) + ttl_seconds
    username = f"{expira}:{tag}"
    digest = hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    return username, base64.b64encode(digest).decode()


def ice_servers(tag: str) -> list[dict]:
    """Lista pronta para o `RTCConfiguration` dos dois lados.

    `tag` só serve para rastrear de quem é a credencial nos logs do TURN.

    Sem `turn_host` ou `turn_secret` configurados, devolve só o STUN: é o
    comportamento de antes, e um servidor sem TURN não pode virar erro para
    quem está só querendo ver a tela.
    """
    servers: list[dict] = [{"urls": list(settings.stun_urls)}]
    if not settings.turn_host or not settings.turn_secret:
        return servers

    username, credential = _credential(
        tag, settings.turn_ttl_seconds, settings.turn_secret
    )
    porta = settings.turn_port
    servers.append(
        {
            # UDP é o caminho bom; TCP existe para redes que bloqueiam UDP,
            # e é comum em Wi-Fi corporativo.
            "urls": [
                f"turn:{settings.turn_host}:{porta}?transport=udp",
                f"turn:{settings.turn_host}:{porta}?transport=tcp",
            ],
            "username": username,
            "credential": credential,
        }
    )
    return servers
