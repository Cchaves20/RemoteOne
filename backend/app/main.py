import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app.agents import AgentRegistry
from app.auth import router as auth_router
from app.config import settings
from app.db import init_db
from app.protocol import Ack, Error, Hello, Welcome, parse_client_message

logger = logging.getLogger("remoteone")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Cria as tabelas ausentes na subida (MVP; futuramente via Alembic).
    init_db()
    yield


app = FastAPI(title=settings.app_name, version=settings.version, lifespan=lifespan)
app.include_router(auth_router)

# Registro de agentes conectados (em memória; ver app/agents.py).
registry = AgentRegistry()


@app.get("/health")
def health() -> dict[str, str]:
    """Verificação de disponibilidade usada pela CI e por orquestradores."""
    return {"status": "ok", "version": settings.version}


@app.get("/api/v1")
def api_root() -> dict[str, str]:
    """Raiz da API v1. Autenticação e pareamento entram aqui (Etapas 2 e 5)."""
    return {"name": settings.app_name}


@app.get("/api/v1/agents")
def list_agents() -> dict:
    """Lista os agentes atualmente conectados (online)."""
    return {"agents": [a.as_dict() for a in registry.list()]}


@app.websocket("/ws/agent")
async def agent_ws(websocket: WebSocket) -> None:
    """Canal do agente desktop.

    Fluxo: o agente envia `hello` (identificação), o backend responde
    `welcome` e o registra como online; em seguida o agente envia `heartbeat`
    periodicamente, respondido com `ack`. Ao desconectar, o agente sai do
    registro.
    """
    await websocket.accept()
    device_id: str | None = None
    try:
        # A primeira mensagem precisa ser um hello.
        first = await websocket.receive_json()
        try:
            message = parse_client_message(first)
        except ValueError:
            await websocket.send_json(Error(message="mensagem inválida").model_dump())
            await websocket.close()
            return

        if not isinstance(message, Hello):
            await websocket.send_json(
                Error(message="esperado hello como primeira mensagem").model_dump()
            )
            await websocket.close()
            return

        device_id = message.device_id
        registry.register(message)
        logger.info("agente conectado: %s (%s)", device_id, message.hostname)
        await websocket.send_json(Welcome(server_version=settings.version).model_dump())

        while True:
            raw = await websocket.receive_json()
            try:
                message = parse_client_message(raw)
            except ValueError:
                await websocket.send_json(Error(message="mensagem inválida").model_dump())
                continue

            if isinstance(message, Hello):
                # Re-identificação (ex.: após reconexão na mesma sessão).
                device_id = message.device_id
                registry.register(message)
                await websocket.send_json(
                    Welcome(server_version=settings.version).model_dump()
                )
            else:  # Heartbeat
                registry.heartbeat(device_id)
                await websocket.send_json(Ack().model_dump())
    except WebSocketDisconnect:
        pass
    finally:
        if device_id is not None:
            registry.unregister(device_id)
            logger.info("agente desconectado: %s", device_id)
