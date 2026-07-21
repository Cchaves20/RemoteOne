import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app import pairing
from app.agents import AgentRegistry
from app.auth import router as auth_router
from app.config import settings
from app.connections import manager
from app.db import SessionLocal, init_db
from app.devices import router as devices_router
from app.protocol import (
    Ack,
    Error,
    Hello,
    PairCode,
    Paired,
    Welcome,
    parse_client_message,
)

logger = logging.getLogger("remoteone")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Cria as tabelas ausentes na subida (MVP; futuramente via Alembic).
    init_db()
    yield


app = FastAPI(title=settings.app_name, version=settings.version, lifespan=lifespan)
app.include_router(auth_router)
app.include_router(devices_router)

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


def _paired_email(device_id: str) -> str | None:
    """Retorna o e-mail da conta dona do dispositivo, ou None se não pareado."""
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        return device.user.email if device is not None else None


def _pairing_intro(hello: Hello) -> dict:
    """Mensagem enviada logo após o welcome: `paired` se já vinculado, senão `pair_code`."""
    email = _paired_email(hello.device_id)
    if email is not None:
        return Paired(user_email=email).model_dump()
    with SessionLocal() as db:
        code = pairing.create_pairing_request(
            db, hello.device_id, hello.hostname, hello.os, settings.pairing_ttl_seconds
        )
    return PairCode(code=code, expires_in_seconds=settings.pairing_ttl_seconds).model_dump()


@app.websocket("/ws/agent")
async def agent_ws(websocket: WebSocket) -> None:
    """Canal do agente desktop.

    Fluxo: o agente envia `hello` (identificação), o backend responde
    `welcome` e o registra como online. Se o dispositivo ainda não está
    pareado, o backend envia um `pair_code` para o agente exibir; quando o
    usuário reivindica o código no app, o agente recebe `paired`. Em seguida o
    agente envia `heartbeat` periodicamente, respondido com `ack`.
    """
    await websocket.accept()
    device_id: str | None = None
    paired_notified = False
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
        manager.register(device_id, websocket)
        logger.info("agente conectado: %s (%s)", device_id, message.hostname)
        await websocket.send_json(Welcome(server_version=settings.version).model_dump())

        intro = _pairing_intro(message)
        paired_notified = intro["type"] == "paired"
        await websocket.send_json(intro)

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
                manager.register(device_id, websocket)
                await websocket.send_json(
                    Welcome(server_version=settings.version).model_dump()
                )
            else:  # Heartbeat
                registry.heartbeat(device_id)
                await websocket.send_json(Ack().model_dump())
                # Detecta o pareamento concluído entre heartbeats e avisa o agente.
                if not paired_notified:
                    email = _paired_email(device_id)
                    if email is not None:
                        await websocket.send_json(Paired(user_email=email).model_dump())
                        paired_notified = True
    except WebSocketDisconnect:
        pass
    finally:
        if device_id is not None:
            registry.unregister(device_id)
            manager.unregister(device_id, websocket)
            logger.info("agente desconectado: %s", device_id)
