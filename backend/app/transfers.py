"""Transferência de arquivos entre o app e o agente.

O backend é **relé, não depósito**: os pedaços passam por ele e seguem adiante,
sem que o arquivo inteiro exista aqui em momento algum. Isso não é elegância —
é o que permite mover 100 MB numa VM de 1 GB de RAM.

Cada transferência tem uma fila curta. É ela que faz a contrapressão: quando o
celular não consome tão rápido quanto o computador lê, a fila enche, o
`put` espera, e o agente para de mandar (o socket dele deixa de ser drenado).
Sem o limite, a fila cresceria até a memória acabar.
"""

import asyncio
import base64
import uuid

# Pedaços em espera por transferência. Quatro de 64 KiB = 256 KiB por
# transferência em curso, o suficiente para não engasgar numa rede boa.
QUEUE_LIMIT = 4

# O mesmo teto do agente (`agent/src/files.rs`).
MAX_TRANSFER_BYTES = 100 * 1024 * 1024


class TransferError(Exception):
    """O agente reportou falha no meio da transferência."""


class Download:
    """Um arquivo vindo do computador, chegando em pedaços."""

    def __init__(self) -> None:
        self.chunks: asyncio.Queue = asyncio.Queue(maxsize=QUEUE_LIMIT)
        # Sequência esperada: pedaço fora de ordem viraria arquivo corrompido
        # sem aviso, que é a pior falha possível numa transferência.
        self._next_seq = 0

    async def push(self, seq: int, data: str) -> None:
        if seq != self._next_seq:
            await self.chunks.put(
                TransferError(f"pedaço fora de ordem (esperava {self._next_seq}, veio {seq})")
            )
            return
        self._next_seq += 1
        await self.chunks.put(base64.b64decode(data))

    async def finish(self, ok: bool, detail: str | None) -> None:
        """Fecha a transferência: `None` na fila significa fim."""
        await self.chunks.put(None if ok else TransferError(detail or "falhou"))


class Transfers:
    """Transferências em curso, indexadas por `transfer_id`.

    Vive em memória, num processo — como o registro de conexões. Ao escalar
    para vários workers, isto passa a ser respaldado por Redis.
    """

    def __init__(self) -> None:
        self._downloads: dict[str, Download] = {}

    def start_download(self) -> tuple[str, Download]:
        transfer_id = uuid.uuid4().hex
        download = Download()
        self._downloads[transfer_id] = download
        return transfer_id, download

    def get(self, transfer_id: str) -> Download | None:
        return self._downloads.get(transfer_id)

    def drop(self, transfer_id: str) -> None:
        self._downloads.pop(transfer_id, None)

    def count(self) -> int:
        return len(self._downloads)

    def new_upload_id(self) -> str:
        """Id de um envio ao computador. Não guarda estado: o app manda os
        pedaços em ordem numa requisição só, e quem acumula é o agente."""
        return uuid.uuid4().hex


# Instância única compartilhada pelos endpoints e pelo canal do agente.
transfers = Transfers()
