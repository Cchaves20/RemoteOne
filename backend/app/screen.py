"""Cache do último frame de tela recebido de cada agente.

O agente envia frames JPEG (binários) pelo seu WebSocket; o backend guarda
apenas o mais recente por dispositivo, que o app busca por HTTP. Manter só o
último frame evita acúmulo e mantém a latência baixa.
"""


class FrameStore:
    def __init__(self) -> None:
        self._frames: dict[str, bytes] = {}

    def put(self, device_id: str, frame: bytes) -> None:
        self._frames[device_id] = frame

    def get(self, device_id: str) -> bytes | None:
        return self._frames.get(device_id)

    def clear(self, device_id: str) -> None:
        self._frames.pop(device_id, None)


frame_store = FrameStore()
