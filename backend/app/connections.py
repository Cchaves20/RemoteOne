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


# Instância única compartilhada pelo endpoint do agente e pelo relay de input.
manager = ConnectionManager()
