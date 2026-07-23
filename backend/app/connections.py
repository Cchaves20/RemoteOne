"""Gerenciador das conexões WebSocket vivas dos agentes.

Diferente do `AgentRegistry` (metadados de presença), este guarda o objeto
WebSocket em si, para que o backend possa **enviar** comandos ao agente (ex.:
relay de input do app). Vive num único processo/worker; ao escalar, o relay
passa a usar um canal Redis (pub/sub) entre instâncias.
"""

import asyncio

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        self._agents: dict[str, WebSocket] = {}
        # IP público de cada agente online (mesmo IP público = mesma LAN),
        # usado para escolher um "peer" ligado no Wake-on-LAN.
        self._public_ip: dict[str, str] = {}

    def register(
        self, device_id: str, websocket: WebSocket, public_ip: str | None = None
    ) -> None:
        self._agents[device_id] = websocket
        if public_ip is not None:
            self._public_ip[device_id] = public_ip

    def unregister(self, device_id: str, websocket: WebSocket | None = None) -> None:
        # Só remove se for a mesma conexão (evita derrubar uma reconexão nova).
        if websocket is None or self._agents.get(device_id) is websocket:
            self._agents.pop(device_id, None)
            self._public_ip.pop(device_id, None)

    def is_online(self, device_id: str) -> bool:
        return device_id in self._agents

    def public_ip(self, device_id: str) -> str | None:
        """IP público atual do agente online (None se offline/desconhecido)."""
        return self._public_ip.get(device_id)

    async def send_to_agent(self, device_id: str, message: dict) -> bool:
        """Envia uma mensagem ao agente. Retorna False se ele não está conectado."""
        websocket = self._agents.get(device_id)
        if websocket is None:
            return False
        await websocket.send_json(message)
        return True


class Viewer:
    """Um app assistindo à tela.

    Mantém apenas o frame **mais recente** (descarta os anteriores ainda não
    enviados). Assim, se a rede é mais lenta que a captura, o app não acumula
    atraso — ele sempre pula para o frame atual em vez de exibir uma fila de
    frames velhos.
    """

    def __init__(self, websocket: WebSocket) -> None:
        self.websocket = websocket
        self._latest: bytes | None = None
        self._event = asyncio.Event()

    def offer(self, frame: bytes) -> None:
        """Oferece um frame; substitui qualquer pendente (drop do antigo)."""
        self._latest = frame
        self._event.set()

    async def run_sender(self) -> None:
        """Envia sempre o frame mais recente disponível, no ritmo da rede."""
        while True:
            await self._event.wait()
            self._event.clear()
            frame, self._latest = self._latest, None
            if frame is not None:
                await self.websocket.send_bytes(frame)


class ViewerRegistry:
    """Apps que assistem à tela de cada dispositivo."""

    def __init__(self) -> None:
        self._viewers: dict[str, set[Viewer]] = {}

    def add(self, device_id: str, viewer: Viewer) -> int:
        """Registra um viewer. Retorna quantos viewers o dispositivo tem agora."""
        viewers = self._viewers.setdefault(device_id, set())
        viewers.add(viewer)
        return len(viewers)

    def remove(self, device_id: str, viewer: Viewer) -> int:
        """Remove um viewer. Retorna quantos viewers restam."""
        viewers = self._viewers.get(device_id)
        if viewers is None:
            return 0
        viewers.discard(viewer)
        remaining = len(viewers)
        if remaining == 0:
            self._viewers.pop(device_id, None)
        return remaining

    def count(self, device_id: str) -> int:
        return len(self._viewers.get(device_id, ()))

    def broadcast(self, device_id: str, frame: bytes) -> None:
        """Oferece o frame a todos os viewers (não bloqueia; cada um envia no
        seu ritmo, descartando frames velhos)."""
        for viewer in self._viewers.get(device_id, ()):
            viewer.offer(frame)


# Instâncias únicas compartilhadas entre os endpoints.
manager = ConnectionManager()
viewers = ViewerRegistry()
