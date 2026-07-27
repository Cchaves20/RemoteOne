"""Pergunta e resposta com o agente pelo WebSocket.

Até aqui o backend só *mandava* comandos ao agente (mão única). Para listar os
aplicativos precisamos **esperar a resposta**, então cada pedido leva um
`request_id` e fica aguardando um `Future`, que é resolvido quando chega a
mensagem correspondente do agente.

Vive em memória, num processo. Ao escalar para vários workers, o registro passa
a ser respaldado por Redis (mesmo caminho já previsto para as conexões).
"""

import asyncio
import uuid


class PendingRequests:
    """Pedidos aguardando resposta do agente, indexados por `request_id`."""

    def __init__(self) -> None:
        self._pending: dict[str, asyncio.Future] = {}

    def create(self) -> tuple[str, asyncio.Future]:
        """Registra um novo pedido e devolve (request_id, future)."""
        request_id = uuid.uuid4().hex
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        return request_id, future

    def resolve(self, request_id: str, payload) -> bool:
        """Entrega a resposta a quem espera. False se ninguém mais esperava."""
        future = self._pending.pop(request_id, None)
        if future is None or future.done():
            return False
        future.set_result(payload)
        return True

    def cancel(self, request_id: str) -> None:
        """Desiste do pedido (timeout ou agente desconectado)."""
        future = self._pending.pop(request_id, None)
        if future is not None and not future.done():
            future.cancel()

    def pending_count(self) -> int:
        return len(self._pending)


# Instância única compartilhada pelos endpoints e pelo canal do agente.
pending = PendingRequests()
