"""Gerenciador das conexões WebSocket vivas dos agentes.

Diferente do `AgentRegistry` (metadados de presença), este guarda o objeto
WebSocket em si, para que o backend possa **enviar** comandos ao agente (ex.:
relay de input do app). Vive num único processo/worker; ao escalar, o relay
passa a usar um canal Redis (pub/sub) entre instâncias.
"""

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        self._agents: dict[str, WebSocket] = {}

    def register(self, device_id: str, websocket: WebSocket) -> None:
        self._agents[device_id] = websocket

    def unregister(self, device_id: str, websocket: WebSocket | None = None) -> None:
        # Só remove se for a mesma conexão (evita derrubar uma reconexão nova).
        if websocket is None or self._agents.get(device_id) is websocket:
            self._agents.pop(device_id, None)

    def is_online(self, device_id: str) -> bool:
        return device_id in self._agents

    async def send_to_agent(self, device_id: str, message: dict) -> bool:
        """Envia uma mensagem ao agente. Retorna False se ele não está conectado."""
        websocket = self._agents.get(device_id)
        if websocket is None:
            return False
        await websocket.send_json(message)
        return True


class ViewerRegistry:
    """Conexões WebSocket dos apps que assistem à tela de cada dispositivo."""

    def __init__(self) -> None:
        self._viewers: dict[str, set[WebSocket]] = {}

    def add(self, device_id: str, websocket: WebSocket) -> int:
        """Registra um viewer. Retorna quantos viewers o dispositivo tem agora."""
        viewers = self._viewers.setdefault(device_id, set())
        viewers.add(websocket)
        return len(viewers)

    def remove(self, device_id: str, websocket: WebSocket) -> int:
        """Remove um viewer. Retorna quantos viewers restam."""
        viewers = self._viewers.get(device_id)
        if viewers is None:
            return 0
        viewers.discard(websocket)
        remaining = len(viewers)
        if remaining == 0:
            self._viewers.pop(device_id, None)
        return remaining

    def count(self, device_id: str) -> int:
        return len(self._viewers.get(device_id, ()))

    async def broadcast(self, device_id: str, frame: bytes) -> None:
        """Envia um frame a todos os viewers; descarta os que falharem."""
        viewers = list(self._viewers.get(device_id, ()))
        for websocket in viewers:
            try:
                await websocket.send_bytes(frame)
            except Exception:  # noqa: BLE001 — viewer caiu; remove e segue
                self.remove(device_id, websocket)


# Instâncias únicas compartilhadas entre os endpoints.
manager = ConnectionManager()
viewers = ViewerRegistry()
