import asyncio
import json
import logging
from contextlib import asynccontextmanager

import jwt
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app import pairing
from app.agents import AgentRegistry
from app.auth import router as auth_router
from app.config import settings
from app.connections import Viewer, manager, viewers
from app.db import SessionLocal, init_db
from app.devices import router as devices_router
from app.ice import ice_servers
from app.profiles import router as profiles_router
from app.protocol import (
    Ack,
    AppList,
    Clipboard,
    ClipboardChanged,
    Error,
    FileChunk,
    FileDone,
    FileList,
    Foreground,
    Hello,
    MonitorList,
    PairCode,
    Paired,
    SystemStats,
    WebrtcAnswer,
    WebrtcIce,
    Welcome,
    parse_client_message,
)
from app.rpc import pending
from app.screen import frame_store
from app.security import decode_token
from app.signaling import (
    SignalingError,
    close_session,
    is_signaling,
    to_agent,
    to_viewer,
)
from app.transfers import transfers

logger = logging.getLogger("remoteone")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Cria as tabelas ausentes na subida (MVP; futuramente via Alembic).
    init_db()
    yield


app = FastAPI(title=settings.app_name, version=settings.version, lifespan=lifespan)
app.include_router(auth_router)
app.include_router(devices_router)
app.include_router(profiles_router)

# Registro de agentes conectados (em memória; ver app/agents.py).
registry = AgentRegistry()


# Recursos que este código sabe fazer, para dar de responder "o que está no ar
# é novo?" sem adivinhação. A versão do app sobe devagar e não serve para isso;
# um recurso que aparece aqui é um recurso que o binário implantado tem.
#
# Nasceu de um problema repetido: por três vezes um defeito foi rastreado até
# um componente desatualizado, e cada diagnóstico começou por dedução em vez de
# medida. `curl /health` agora responde direto.
FEATURES = [
    "pairing",
    "input",
    "screen-jpeg",
    "apps",
    "wake-on-lan",
    "totp",
    "webrtc-signaling",
    "system-stats",
    "media-keys",
    "file-transfer",
    "foreground-app",
    "audio-stream",
    "ice-servers",
    "clipboard",
    "monitors",
    "control-profiles",
]


@app.get("/health")
def health() -> dict:
    """Disponibilidade e o que este backend implementa.

    Usada pela CI, por orquestradores e para conferir qual código está no ar.
    """
    return {
        "status": "ok",
        "version": settings.version,
        "features": FEATURES,
    }


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


def _client_public_ip(websocket: WebSocket) -> str | None:
    """IP público do agente. Atrás do Caddy, vem no cabeçalho X-Forwarded-For."""
    forwarded = websocket.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return websocket.client.host if websocket.client else None


def _update_device_presence(device_id: str, mac: str | None, public_ip: str | None) -> None:
    """Guarda o MAC e o último IP público do dispositivo pareado (Wake-on-LAN)."""
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        if device is None:
            return
        changed = False
        if mac and device.mac_address != mac:
            device.mac_address = mac
            changed = True
        if public_ip and device.last_public_ip != public_ip:
            device.last_public_ip = public_ip
            changed = True
        if changed:
            db.commit()


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
        hostname = message.hostname
        os_name = message.os
        mac_addr = message.mac
        public_ip = _client_public_ip(websocket)
        registry.register(message)
        manager.register(device_id, websocket, public_ip)
        _update_device_presence(device_id, mac_addr, public_ip)
        logger.info("agente conectado: %s (%s)", device_id, message.hostname)
        await websocket.send_json(
            Welcome(
                server_version=settings.version,
                ice_servers=ice_servers(f"agent-{device_id}"),
            ).model_dump()
        )

        intro = _pairing_intro(message)
        paired_notified = intro["type"] == "paired"
        await websocket.send_json(intro)

        while True:
            packet = await websocket.receive()
            if packet["type"] == "websocket.disconnect":
                break

            # Frame de tela (binário): guarda o mais recente e o oferece aos
            # apps que estão assistindo (não bloqueia; cada um envia no seu
            # ritmo, descartando frames velhos).
            if packet.get("bytes") is not None:
                frame_store.put(device_id, packet["bytes"])
                viewers.broadcast(device_id, packet["bytes"])
                continue

            text = packet.get("text")
            if text is None:
                continue
            try:
                message = parse_client_message(json.loads(text))
            except (ValueError, json.JSONDecodeError):
                await websocket.send_json(Error(message="mensagem inválida").model_dump())
                continue

            if isinstance(message, AppList):
                # Resposta a um pedido de lista de aplicativos: entrega a quem
                # está esperando (o endpoint HTTP que fez a pergunta).
                pending.resolve(
                    message.request_id, [a.model_dump() for a in message.apps]
                )
            elif isinstance(message, MonitorList):
                pending.resolve(
                    message.request_id,
                    {
                        "monitors": [m.model_dump() for m in message.monitors],
                        "selected": message.selected,
                    },
                )
            elif isinstance(message, FileList):
                pending.resolve(
                    message.request_id,
                    {
                        "listing": message.listing.model_dump()
                        if message.listing
                        else None,
                        "error": message.error,
                    },
                )
            elif isinstance(message, FileChunk):
                # Pedaço de um arquivo indo ao celular. O `await` aqui é o que
                # segura o agente quando o celular não consome: a fila enche e
                # este socket para de ser drenado.
                download = transfers.get(message.transfer_id)
                if download is not None:
                    await download.push(message.seq, message.data)
            elif isinstance(message, FileDone):
                # Serve aos dois sentidos: fim de um download (fila) ou a
                # confirmação de um envio (pedido pendente).
                download = transfers.get(message.transfer_id)
                if download is not None:
                    await download.finish(message.ok, message.detail)
                else:
                    pending.resolve(
                        message.transfer_id,
                        {"ok": message.ok, "detail": message.detail},
                    )
            elif isinstance(message, Clipboard):
                pending.resolve(
                    message.request_id,
                    {
                        "text": message.text,
                        "files": [f.model_dump() for f in message.files],
                        "ignored": message.ignored,
                    },
                )
            elif isinstance(message, ClipboardChanged):
                # Aviso sem pedido: vai para quem estiver com a tela aberta.
                # Se ninguém estiver, some - e é o certo: guardar o que alguém
                # copiou no computador para entregar depois seria guardar
                # justamente o tipo de coisa que não se deve guardar.
                enviados = viewers.notify(
                    device_id, {"type": "clipboard", "text": message.text}
                )
                logger.debug("área de transferência → %s viewer(s)", enviados)
            elif isinstance(message, Foreground):
                # Primeiro plano: o `None` é resposta legítima (nenhuma janela
                # em foco), então vai como está para quem perguntou.
                pending.resolve(
                    message.request_id,
                    {"app": message.app.model_dump() if message.app else None},
                )
            elif isinstance(message, SystemStats):
                # Métricas medidas: entrega a quem pediu (o endpoint HTTP).
                pending.resolve(message.request_id, message.stats.model_dump())
            elif isinstance(message, (WebrtcAnswer, WebrtcIce)):
                # Sinalização de volta: acha o app daquela sessão e repassa.
                # `by_session` confere que a sessão é deste dispositivo — sem
                # isso, um agente poderia responder na sessão de outro PC.
                viewer = viewers.by_session(message.session_id, device_id)
                if viewer is None:
                    logger.info(
                        "sinalização descartada: sessão %s não é de %s",
                        message.session_id,
                        device_id,
                    )
                else:
                    viewer.signal(to_viewer(message.model_dump()))
            elif isinstance(message, Hello):
                # Re-identificação (ex.: após reconexão na mesma sessão).
                device_id = message.device_id
                hostname = message.hostname
                os_name = message.os
                mac_addr = message.mac
                public_ip = _client_public_ip(websocket)
                registry.register(message)
                manager.register(device_id, websocket, public_ip)
                _update_device_presence(device_id, mac_addr, public_ip)
                await websocket.send_json(
                    Welcome(
                        server_version=settings.version,
                        ice_servers=ice_servers(f"agent-{device_id}"),
                    ).model_dump()
                )
            else:  # Heartbeat
                registry.heartbeat(device_id)
                await websocket.send_json(Ack().model_dump())
                # Detecta mudanças de pareamento entre heartbeats:
                #  - vinculado agora → avisa o agente (`paired`);
                #  - desvinculado no app → gera e reexibe um novo código, para o
                #    usuário poder reparear sem reiniciar o agente.
                now_paired = _paired_email(device_id) is not None
                if now_paired and not paired_notified:
                    email = _paired_email(device_id)
                    await websocket.send_json(Paired(user_email=email).model_dump())
                    paired_notified = True
                    # Acabou de parear: guarda MAC/IP para o Wake-on-LAN.
                    _update_device_presence(device_id, mac_addr, public_ip)
                elif not now_paired and paired_notified:
                    paired_notified = False
                    with SessionLocal() as db:
                        code = pairing.create_pairing_request(
                            db, device_id, hostname, os_name, settings.pairing_ttl_seconds
                        )
                    await websocket.send_json(
                        PairCode(
                            code=code, expires_in_seconds=settings.pairing_ttl_seconds
                        ).model_dump()
                    )
    except WebSocketDisconnect:
        pass
    finally:
        if device_id is not None:
            registry.unregister(device_id)
            manager.unregister(device_id, websocket)
            frame_store.clear(device_id)
            logger.info("agente desconectado: %s", device_id)


def _authenticate_viewer(token: str, device_id: str) -> bool:
    """Valida o token e a posse do dispositivo para assistir à tela."""
    try:
        payload = decode_token(token)
    except jwt.PyJWTError:
        return False
    if payload.get("type") != "access":
        return False
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        return device is not None and str(device.user_id) == str(payload.get("sub"))


# Paradas de transmissão agendadas por dispositivo. Ao sair o último viewer,
# o stream é mantido "aquecido" por alguns segundos antes de parar de fato —
# assim, voltar à tela logo em seguida é instantâneo (Etapa de refino #16).
_pending_stops: dict[str, asyncio.Task] = {}
_STREAM_GRACE_SECONDS = 8

# Faixas aceitas para o ajuste de qualidade/desempenho vindo do app.
_FPS_RANGE = (1, 30)
_QUALITY_RANGE = (20, 90)
_WIDTH_RANGE = (640, 1920)


def _clamp(value: int, bounds: tuple[int, int]) -> int:
    low, high = bounds
    return max(low, min(high, value))


def _start_stream_message(auth: dict) -> dict:
    """Monta o start_stream com a qualidade pedida pelo app (ou o padrão)."""
    message: dict = {"type": "start_stream", "max_fps": settings.stream_fps}
    fps = auth.get("fps")
    if isinstance(fps, int):
        message["max_fps"] = _clamp(fps, _FPS_RANGE)
    quality = auth.get("quality")
    if isinstance(quality, int):
        message["quality"] = _clamp(quality, _QUALITY_RANGE)
    max_width = auth.get("max_width")
    if isinstance(max_width, int):
        message["max_width"] = _clamp(max_width, _WIDTH_RANGE)
    return message


async def _delayed_stop(device_id: str) -> None:
    try:
        await asyncio.sleep(_STREAM_GRACE_SECONDS)
    except asyncio.CancelledError:
        return
    _pending_stops.pop(device_id, None)
    if viewers.count(device_id) == 0:
        await manager.send_to_agent(device_id, {"type": "stop_stream"})
        frame_store.clear(device_id)


@app.websocket("/ws/viewer/{device_id}")
async def viewer_ws(websocket: WebSocket, device_id: str) -> None:
    """Canal do app para assistir à tela em tempo real.

    O app envia `{"token": "..."}` como primeira mensagem; autenticado e sendo
    dono do dispositivo, passa a receber os frames JPEG (binários) empurrados
    pelo backend. A transmissão do agente é ligada ao conectar o primeiro
    viewer e desligada alguns segundos após o último sair (stream aquecido).
    """
    await websocket.accept()
    viewer = Viewer(websocket)
    registered = False
    sender_task: asyncio.Task | None = None
    try:
        auth = await websocket.receive_json()
        if not _authenticate_viewer(auth.get("token", ""), device_id):
            await websocket.close(code=4401)  # não autorizado
            return

        count = viewers.add(device_id, viewer)
        registered = True
        sender_task = asyncio.create_task(viewer.run_sender())

        # Se havia uma parada agendada, o agente ainda está transmitindo
        # (aquecido): cancela a parada e a entrada é instantânea. Senão, e
        # sendo o primeiro viewer, liga a transmissão (cold start) com a
        # qualidade que o app pediu no handshake.
        pending = _pending_stops.pop(device_id, None)
        if pending is not None:
            pending.cancel()
        elif count == 1:
            await manager.send_to_agent(
                device_id, _start_stream_message(auth)
            )

        # Oferece o último frame guardado, se houver (exibe algo na hora).
        cached = frame_store.get(device_id)
        if cached is not None:
            viewer.offer(cached)

        # Daqui em diante os frames são empurrados pelo sender. O que chega do
        # app é sinalização de WebRTC, repassada ao agente com o `session_id`
        # desta conexão.
        while True:
            packet = await websocket.receive()
            if packet["type"] == "websocket.disconnect":
                break
            text = packet.get("text")
            if text is None:
                continue
            try:
                incoming = json.loads(text)
            except json.JSONDecodeError:
                viewer.signal({"type": "error", "message": "json inválido"})
                continue
            if not is_signaling(incoming):
                continue  # mensagem desconhecida: ignorada, não é erro fatal
            try:
                outgoing = to_agent(incoming, viewer.session_id)
            except SignalingError as exc:
                viewer.signal({"type": "error", "message": str(exc)})
                continue
            if not await manager.send_to_agent(device_id, outgoing):
                viewer.signal(
                    {"type": "error", "message": "computador não está conectado"}
                )
    except WebSocketDisconnect:
        pass
    finally:
        if sender_task is not None:
            sender_task.cancel()
        if registered:
            remaining = viewers.remove(device_id, viewer)
            # Avisa o agente que a sessão morreu, para ele soltar a conexão
            # WebRTC correspondente em vez de mantê-la pendurada.
            await manager.send_to_agent(device_id, close_session(viewer.session_id))
            if remaining == 0 and device_id not in _pending_stops:
                # Agenda a parada com carência (mantém o stream aquecido).
                _pending_stops[device_id] = asyncio.create_task(
                    _delayed_stop(device_id)
                )
