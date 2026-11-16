"""Registro em memória dos agentes conectados.

Para o MVP, os agentes online vivem num dicionário em memória do processo.
Quando houver múltiplos workers/instâncias do backend, este registro passa a
ser respaldado pelo Redis (já previsto na stack) — a interface aqui foi
pensada para essa troca ser localizada.
"""

from dataclasses import dataclass
from datetime import UTC, datetime

from app.protocol import Hello


def _now() -> datetime:
    return datetime.now(UTC)


@dataclass
class AgentInfo:
    device_id: str
    hostname: str
    os: str
    agent_version: str
    connected_at: datetime
    last_seen: datetime

    def as_dict(self) -> dict[str, str]:
        return {
            "device_id": self.device_id,
            "hostname": self.hostname,
            "os": self.os,
            "agent_version": self.agent_version,
            "connected_at": self.connected_at.isoformat(),
            "last_seen": self.last_seen.isoformat(),
        }


class AgentRegistry:
    def __init__(self) -> None:
        self._agents: dict[str, AgentInfo] = {}

    def register(self, hello: Hello) -> AgentInfo:
        now = _now()
        info = AgentInfo(
            device_id=hello.device_id,
            hostname=hello.hostname,
            os=hello.os,
            agent_version=hello.agent_version,
            connected_at=now,
            last_seen=now,
        )
        self._agents[hello.device_id] = info
        return info

    def heartbeat(self, device_id: str) -> bool:
        """Atualiza o `last_seen`. Retorna False se o agente não está registrado."""
        agent = self._agents.get(device_id)
        if agent is None:
            return False
        agent.last_seen = _now()
        return True

    def unregister(self, device_id: str) -> None:
        self._agents.pop(device_id, None)

    def get(self, device_id: str) -> AgentInfo | None:
        return self._agents.get(device_id)

    def list(self) -> list[AgentInfo]:
        return list(self._agents.values())
