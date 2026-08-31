"""Gerenciador das conexões WebSocket vivas dos agentes.

Diferente do `AgentRegistry` (metadados de presença), este guarda o objeto
WebSocket em si, para que o backend possa **enviar** comandos ao agente (ex.:
relay de input do app). Vive num único processo/worker; ao escalar, o relay
passa a usar um canal Redis (pub/sub) entre instâncias.
"""

import asyncio
import uuid
from collections import deque

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

    def get(self, device_id: str) -> WebSocket | None:
        """A conexão registrada agora, para quem precisa saber **qual** é.

        Quem encerra uma conexão precisa disso: com o agente já reconectado por
        outro socket, o antigo não pode limpar nada. Ver `main.encerrar_agente`.
        """
        return self._agents.get(device_id)

    def is_online(self, device_id: str) -> bool:
        return device_id in self._agents

    async def send_to_agent(self, device_id: str, message: dict) -> bool:
        """Envia uma mensagem ao agente. Retorna False se ele não está conectado."""
        websocket = self._agents.get(device_id)
        if websocket is None:
            return False
        await websocket.send_json(message)
        return True


class Viewer:
    """Um app assistindo à tela.

    Para os frames, mantém apenas o **mais recente** (descarta os anteriores
    ainda não enviados). Assim, se a rede é mais lenta que a captura, o app não
    acumula atraso — ele sempre pula para o frame atual em vez de exibir uma
    fila de frames velhos.

    Para a sinalização de WebRTC vale o contrário: **nada pode ser descartado**,
    porque uma resposta SDP ou um candidato ICE perdido quebra a negociação. Por
    isso ela vai numa fila, e não num slot único.

    Tudo sai por um único `run_sender`, de propósito: dois `send` concorrentes no
    mesmo WebSocket embaralhariam os quadros do protocolo.
    """

    def __init__(self, websocket: WebSocket) -> None:
        self.websocket = websocket
        # Identifica esta sessão nas mensagens trocadas com o agente, que pode
        # estar negociando com vários apps ao mesmo tempo.
        self.session_id = uuid.uuid4().hex
        self._latest: bytes | None = None
        self._signals: deque[dict] = deque()
        self._event = asyncio.Event()

    def offer(self, frame: bytes) -> None:
        """Oferece um frame; substitui qualquer pendente (drop do antigo)."""
        self._latest = frame
        self._event.set()

    def signal(self, message: dict) -> None:
        """Enfileira uma mensagem de sinalização (não pode ser descartada)."""
        self._signals.append(message)
        self._event.set()

    async def run_sender(self) -> None:
        """Envia a sinalização pendente e o frame mais recente, nessa ordem."""
        while True:
            await self._event.wait()
            self._event.clear()
            # Sinalização primeiro: é pequena e atrasá-la atrasa a negociação.
            while self._signals:
                await self.websocket.send_json(self._signals.popleft())
            frame, self._latest = self._latest, None
            if frame is not None:
                await self.websocket.send_bytes(frame)


class ViewerRegistry:
    """Apps que assistem à tela de cada dispositivo."""

    def __init__(self) -> None:
        self._viewers: dict[str, set[Viewer]] = {}
        # session_id → (device_id, viewer), para devolver ao app certo o que o
        # agente responder na negociação de WebRTC.
        self._sessions: dict[str, tuple[str, Viewer]] = {}

    def add(self, device_id: str, viewer: Viewer) -> int:
        """Registra um viewer. Retorna quantos viewers o dispositivo tem agora."""
        viewers = self._viewers.setdefault(device_id, set())
        viewers.add(viewer)
        self._sessions[viewer.session_id] = (device_id, viewer)
        return len(viewers)

    def remove(self, device_id: str, viewer: Viewer) -> int:
        """Remove um viewer. Retorna quantos viewers restam."""
        self._sessions.pop(viewer.session_id, None)
        viewers = self._viewers.get(device_id)
        if viewers is None:
            return 0
        viewers.discard(viewer)
        remaining = len(viewers)
        if remaining == 0:
            self._viewers.pop(device_id, None)
        return remaining

    def by_session(self, session_id: str, device_id: str) -> Viewer | None:
        """Viewer de uma sessão, **desde que** pertença a `device_id`.

        A checagem de dispositivo não é decorativa: sem ela, um agente que se
        comportasse mal poderia mandar sinalização para a sessão de outro
        computador só chutando um `session_id`.
        """
        entry = self._sessions.get(session_id)
        if entry is None:
            return None
        owner, viewer = entry
        return viewer if owner == device_id else None

    def count(self, device_id: str) -> int:
        return len(self._viewers.get(device_id, ()))

    def broadcast(self, device_id: str, frame: bytes) -> None:
        """Oferece o frame a todos os viewers (não bloqueia; cada um envia no
        seu ritmo, descartando frames velhos)."""
        for viewer in self._viewers.get(device_id, ()):
            viewer.offer(frame)

    def notify(self, device_id: str, message: dict) -> int:
        """Manda uma mensagem de texto a todos os viewers de um dispositivo.

        Vai pela fila de sinalização, e não pela de frames, porque **não pode
        ser descartada**: um aviso de área de transferência perdido some sem
        deixar rastro, ao contrário de um frame, que é substituído pelo
        próximo. Devolve para quantos foi.
        """
        alvos = self._viewers.get(device_id, ())
        for viewer in alvos:
            viewer.signal(message)
        return len(alvos)


# Instâncias únicas compartilhadas entre os endpoints.
manager = ConnectionManager()
viewers = ViewerRegistry()
