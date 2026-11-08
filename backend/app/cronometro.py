"""Anota no diário as requisições lentas.

Sem isto, "o app está lento" não tinha por onde começar: o registro de acesso do
Caddy diz quem pediu o quê, mas não quanto a API demorou. Aqui cada requisição
HTTP que passa de `LIMIAR_MS` vira uma linha no diário da API:

    lento: GET /api/v1/devices/{device_id}/apps 200 em 4210 ms

O que vai na linha é o **molde** da rota (`{device_id}`), e não o endereço
pedido: o identificador do computador não entra no diário, e linhas da mesma
rota se agrupam sozinhas num `grep`.

## Por que ASGI puro, e não `@app.middleware("http")`

O decorador do FastAPI embrulha a resposta inteira (`BaseHTTPMiddleware`), o que
custa em toda requisição e atrapalha o download de arquivo, que sai em
pedaços. Este só olha o começo e o fim da requisição e deixa o resto passar
como está. WebSocket passa direto, sem cronômetro: uma conexão que dura horas
não é lenta.

## O que não é medido

A transferência de arquivos demora o tamanho do arquivo, e anotá-la como lenta
só encheria o diário. As perguntas ao computador (programas abertos, pastas,
métricas) **são** medidas: ali a espera é pelo computador, e é exatamente o que
a pessoa sente como lentidão.
"""

from __future__ import annotations

import logging
import time

logger = logging.getLogger("deskside.lento")

#: A partir de quanto uma requisição vira linha no diário.
LIMIAR_MS = 1000

#: Moldes de rota que demoram por natureza.
FORA = ("/files/download", "/files/upload")


class Cronometro:
    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        inicio = time.perf_counter()
        situacao = {"codigo": 0}

        async def enviar(mensagem) -> None:
            if mensagem["type"] == "http.response.start":
                situacao["codigo"] = mensagem["status"]
            await send(mensagem)

        try:
            await self.app(scope, receive, enviar)
        finally:
            ms = (time.perf_counter() - inicio) * 1000
            if ms >= LIMIAR_MS:
                # O roteador do FastAPI põe a rota no `scope` ao achá-la. Sem
                # rota (404), fica o "?": o endereço pedido não entra.
                rota = getattr(scope.get("route"), "path", "?")
                if not rota.endswith(FORA):
                    logger.warning(
                        "lento: %s %s %s em %.0f ms",
                        scope.get("method", "?"),
                        rota,
                        situacao["codigo"] or "sem resposta",
                        ms,
                    )
