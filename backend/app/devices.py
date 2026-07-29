"""Rotas de pareamento e gerenciamento de dispositivos (Etapas 5 e 7.2)."""

import asyncio
import base64
import logging

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session

from app import pairing
from app.auth import get_current_user
from app.connections import manager
from app.db import get_db
from app.ice import ice_servers
from app.input import InputAction
from app.models import Device, User
from app.rpc import pending
from app.schemas import (
    AppActionRequest,
    AppOut,
    AudioRequest,
    ClaimRequest,
    DeviceOut,
    ForegroundOut,
    ListingOut,
    MediaRequest,
    PowerRequest,
    RenameDeviceRequest,
    SystemStatsOut,
)
from app.screen import frame_store
from app.transfers import MAX_TRANSFER_BYTES, TransferError, transfers

logger = logging.getLogger("remoteone")

router = APIRouter(prefix="/api/v1", tags=["devices"])

# Alvo de fps padrão que o backend pede ao agente ao iniciar a transmissão.
_STREAM_FPS = 3
# Faixas aceitas para ajuste de qualidade/desempenho pelo app.
_FPS_RANGE = (1, 30)
_QUALITY_RANGE = (20, 90)
_WIDTH_RANGE = (640, 1920)
# Tempo máximo esperando o agente responder com a lista de aplicativos.
_APPS_TIMEOUT_SECONDS = 15
# Métricas são baratas de medir (o agente mantém o monitor pronto), mas o painel
# do app pergunta de novo a cada poucos segundos: uma espera curta evita que
# pedidos velhos se acumulem quando a rede engasga.
_SYSTEM_TIMEOUT_SECONDS = 5
# Listar uma pasta é ida e volta ao computador, como a lista de aplicativos.
_FILES_TIMEOUT_SECONDS = 20
# Quanto esperar por *cada* pedaço de um arquivo. Generoso: o computador pode
# estar lendo de um disco lento, mas um silêncio longo é conexão morta.
_CHUNK_TIMEOUT_SECONDS = 60
# Tamanho do pedaço que sobe ao computador. O mesmo do agente.
_UPLOAD_CHUNK = 64 * 1024


def _device_out(device: Device) -> DeviceOut:
    """Serializa incluindo o estado de conexão (online) do momento."""
    out = DeviceOut.model_validate(device)
    out.online = manager.is_online(device.device_id)
    return out


def _clamp(value: int, bounds: tuple[int, int]) -> int:
    low, high = bounds
    return max(low, min(high, value))


def _owned_device_or_404(db: Session, device_id: str, user: User) -> Device:
    device = pairing.get_device(db, device_id)
    if device is None or device.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="dispositivo não encontrado"
        )
    return device


@router.post("/pairing/claim", response_model=DeviceOut, status_code=status.HTTP_201_CREATED)
def claim_device(
    body: ClaimRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> DeviceOut:
    """Vincula à conta o computador identificado pelo código de pareamento."""
    try:
        device = pairing.claim(db, body.code.strip().upper(), current_user)
    except pairing.PairingError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc
    return _device_out(device)


@router.get("/devices", response_model=list[DeviceOut])
def list_devices(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[DeviceOut]:
    """Lista os computadores pareados na conta, com o estado online de cada um."""
    return [_device_out(d) for d in pairing.list_devices(db, current_user)]


@router.patch("/devices/{device_id}", response_model=DeviceOut)
def rename_device(
    device_id: str,
    body: RenameDeviceRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> DeviceOut:
    """Renomeia (apelido) um computador da conta."""
    device = pairing.rename_device(db, device_id, current_user, body.name.strip())
    if device is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="dispositivo não encontrado"
        )
    return _device_out(device)


@router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_device(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Desvincula um computador da conta."""
    if not pairing.remove_device(db, device_id, current_user):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="dispositivo não encontrado"
        )


@router.post("/devices/{device_id}/input", status_code=status.HTTP_204_NO_CONTENT)
async def send_input(
    device_id: str,
    action: InputAction = Body(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Retransmite um comando de entrada (mouse) ao computador pareado.

    Exige que o dispositivo seja da conta (posse) e esteja conectado. É a base
    do controle remoto (Etapa 6); o streaming contínuo do touchpad virá pelo
    canal WebSocket do app.
    """
    _owned_device_or_404(db, device_id, current_user)

    envelope = {"type": "input", "action": action.model_dump()}
    if not await manager.send_to_agent(device_id, envelope):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="agente offline",
        )


@router.post("/devices/{device_id}/power", status_code=status.HTTP_204_NO_CONTENT)
async def power_device(
    device_id: str,
    body: PowerRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Desliga, reinicia ou suspende o computador pareado."""
    _owned_device_or_404(db, device_id, current_user)
    message = {"type": "power", "action": body.action}
    if not await manager.send_to_agent(device_id, message):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )


@router.get("/devices/{device_id}/system", response_model=SystemStatsOut)
async def system_stats(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SystemStatsOut:
    """Mede CPU, memória e disco do computador pareado.

    Pergunta e resposta com `request_id`, como a lista de aplicativos: o backend
    espera o agente medir.
    """
    _owned_device_or_404(db, device_id, current_user)

    request_id, future = pending.create()
    message = {"type": "system_info", "request_id": request_id}
    if not await manager.send_to_agent(device_id, message):
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )
    try:
        stats = await asyncio.wait_for(future, timeout=_SYSTEM_TIMEOUT_SECONDS)
    except (TimeoutError, asyncio.CancelledError) as exc:
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="o computador demorou para responder",
        ) from exc
    return SystemStatsOut(**stats)


@router.get("/ice-servers")
async def ice_servers_for_app(
    current_user: User = Depends(get_current_user),
) -> dict:
    """Servidores ICE para o app negociar o vídeo direto.

    Vem do servidor, e não fixo no app, por dois motivos: as credenciais do
    TURN são temporárias (não dá para embutir), e trocar de servidor deixa de
    exigir um app novo.
    """
    return {"ice_servers": ice_servers(f"user-{current_user.id}")}


@router.post("/devices/{device_id}/audio", status_code=status.HTTP_204_NO_CONTENT)
async def audio_stream(
    device_id: str,
    body: AudioRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Liga ou desliga o som do computador no telefone.

    O som viaja pela conexão WebRTC que já leva a tela, numa faixa Opus. Este
    endpoint só diz ao computador para começar (ou parar) de capturar: se não
    houver conexão direta de vídeo, não há por onde o som passar.
    """
    _owned_device_or_404(db, device_id, current_user)
    message = {"type": "audio", "enabled": body.enabled, "gain": body.gain}
    if not await manager.send_to_agent(device_id, message):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )


@router.get("/devices/{device_id}/foreground", response_model=ForegroundOut)
async def foreground_app(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ForegroundOut:
    """Qual programa está em primeiro plano no computador, com o ícone dele.

    Serve à barra de perfis do app: o perfil que combina com o programa da
    frente passa a mostrar o ícone real dele. Quem decide qual perfil combina
    com qual programa é o app - aqui só se repassa o que o agente respondeu.
    """
    _owned_device_or_404(db, device_id, current_user)

    request_id, future = pending.create()
    message = {"type": "foreground_info", "request_id": request_id}
    if not await manager.send_to_agent(device_id, message):
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )
    try:
        reply = await asyncio.wait_for(future, timeout=_SYSTEM_TIMEOUT_SECONDS)
    except (TimeoutError, asyncio.CancelledError) as exc:
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="o computador demorou para responder",
        ) from exc
    return ForegroundOut(**reply)


@router.post("/devices/{device_id}/media", status_code=status.HTTP_204_NO_CONTENT)
async def media_key(
    device_id: str,
    body: MediaRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Aciona uma tecla de mídia (play/pause, faixa, volume) no computador."""
    _owned_device_or_404(db, device_id, current_user)
    message = {"type": "media", "action": body.action}
    if not await manager.send_to_agent(device_id, message):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )


@router.get("/devices/{device_id}/files", response_model=ListingOut)
async def list_files(
    device_id: str,
    path: str = Query("", max_length=4096),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ListingOut:
    """Lista uma pasta do computador. Caminho vazio = a pasta do usuário.

    O agente só enxerga dentro da pasta do usuário; um caminho fora dela volta
    como 400, não como pasta vazia.
    """
    _owned_device_or_404(db, device_id, current_user)

    request_id, future = pending.create()
    message = {"type": "list_files", "request_id": request_id, "path": path}
    if not await manager.send_to_agent(device_id, message):
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )
    try:
        payload = await asyncio.wait_for(future, timeout=_FILES_TIMEOUT_SECONDS)
    except (TimeoutError, asyncio.CancelledError) as exc:
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="o computador demorou para responder",
        ) from exc
    if payload.get("error"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=payload["error"]
        )
    return ListingOut(**payload["listing"])


@router.get("/devices/{device_id}/files/download")
async def download_file(
    device_id: str,
    path: str = Query(..., min_length=1, max_length=4096),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> StreamingResponse:
    """Traz um arquivo do computador para o celular.

    O backend **repassa** os pedaços enquanto chegam; o arquivo nunca existe
    inteiro aqui. É o que torna possível mover 100 MB numa VM de 1 GB.
    """
    _owned_device_or_404(db, device_id, current_user)

    transfer_id, download = transfers.start_download()
    message = {"type": "read_file", "transfer_id": transfer_id, "path": path}
    if not await manager.send_to_agent(device_id, message):
        transfers.drop(transfer_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )

    async def stream():
        try:
            while True:
                chunk = await asyncio.wait_for(
                    download.chunks.get(), timeout=_CHUNK_TIMEOUT_SECONDS
                )
                if chunk is None:
                    return
                if isinstance(chunk, TransferError):
                    # A conexão já começou (200 enviado): não há como virar erro
                    # HTTP. Cortar o corpo é o que sinaliza a falha ao app, que
                    # compara o recebido com o Content-Length.
                    logger.warning("transferência %s falhou: %s", transfer_id, chunk)
                    return
                yield chunk
        except (TimeoutError, asyncio.CancelledError):
            logger.info("transferência %s interrompida", transfer_id)
        finally:
            transfers.drop(transfer_id)
            # Avisa o computador para parar de ler — sem isso ele seguiria
            # bombeando um arquivo que ninguém mais quer.
            await manager.send_to_agent(
                device_id, {"type": "cancel_transfer", "transfer_id": transfer_id}
            )

    name = path.replace("\\", "/").rsplit("/", 1)[-1] or "arquivo"
    return StreamingResponse(
        stream(),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{name}"'},
    )


@router.post("/devices/{device_id}/files/upload", status_code=status.HTTP_200_OK)
async def upload_file(
    device_id: str,
    request: Request,
    name: str = Query(..., min_length=1, max_length=255),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Envia um arquivo do celular para o computador.

    O corpo é o arquivo cru (sem multipart): o app já sabe o nome, e envelopar
    custaria uma cópia a mais em cada ponta. O backend lê e repassa pedaço a
    pedaço — o `await` de cada envio ao agente é o que segura o upload quando o
    computador não acompanha.
    """
    device = _owned_device_or_404(db, device_id, current_user)

    declared = request.headers.get("content-length")
    size = int(declared) if declared and declared.isdigit() else 0
    if size > MAX_TRANSFER_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail=f"limite de {MAX_TRANSFER_BYTES // 1024 // 1024} MB por arquivo",
        )

    # O agente responde o `file_done` carregando o transfer_id, então é ele que
    # identifica o pedido pendente — não um request_id separado.
    transfer_id = transfers.new_upload_id()
    future = pending.create_with_id(transfer_id)

    begin = {
        "type": "write_file_begin",
        "transfer_id": transfer_id,
        "name": name,
        "size": size,
    }
    if not await manager.send_to_agent(device_id, begin):
        pending.cancel(transfer_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )

    seq = 0
    enviados = 0
    try:
        async for chunk in _chunked(request.stream(), _UPLOAD_CHUNK):
            enviados += len(chunk)
            if enviados > MAX_TRANSFER_BYTES:
                raise HTTPException(
                    status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                    detail=f"limite de {MAX_TRANSFER_BYTES // 1024 // 1024} MB por arquivo",
                )
            ok = await manager.send_to_agent(
                device_id,
                {
                    "type": "write_file_chunk",
                    "transfer_id": transfer_id,
                    "seq": seq,
                    "data": base64.b64encode(chunk).decode(),
                },
            )
            if not ok:
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="o computador saiu no meio do envio",
                )
            seq += 1
        await manager.send_to_agent(
            device_id, {"type": "write_file_end", "transfer_id": transfer_id}
        )
    except HTTPException:
        pending.cancel(transfer_id)
        await manager.send_to_agent(
            device_id, {"type": "cancel_transfer", "transfer_id": transfer_id}
        )
        raise

    try:
        result = await asyncio.wait_for(future, timeout=_CHUNK_TIMEOUT_SECONDS)
    except (TimeoutError, asyncio.CancelledError) as exc:
        pending.cancel(transfer_id)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="o computador não confirmou o arquivo",
        ) from exc
    if not result.get("ok"):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=result.get("detail") or "o computador recusou o arquivo",
        )
    return {"path": result.get("detail", ""), "device": device.name, "bytes": enviados}


async def _chunked(stream, size: int):
    """Reagrupa o corpo da requisição em pedaços de tamanho fixo.

    O `request.stream()` entrega o que a rede trouxer — às vezes 1 KB, às vezes
    200 KB. Sem reagrupar, o tamanho do pedaço no fio dependeria do humor da
    rede, e um pedaço grande demais estouraria a mensagem do WebSocket.
    """
    buffer = bytearray()
    async for parte in stream:
        buffer.extend(parte)
        while len(buffer) >= size:
            yield bytes(buffer[:size])
            del buffer[:size]
    if buffer:
        yield bytes(buffer)


@router.get("/devices/{device_id}/apps", response_model=list[AppOut])
async def list_apps(
    device_id: str,
    kind: str = Query("installed", pattern="^(desktop|installed|running)$"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[AppOut]:
    """Lista os aplicativos do computador.

    `kind`: `desktop` (atalhos da área de trabalho — o que a dock usa),
    `installed` (menu Iniciar) ou `running` (abertos agora).

    Diferente dos outros comandos, aqui o backend **espera a resposta** do
    agente (pergunta e resposta com `request_id`), com tempo limite.
    """
    _owned_device_or_404(db, device_id, current_user)

    request_id, future = pending.create()
    message = {"type": "list_apps", "request_id": request_id, "kind": kind}
    if not await manager.send_to_agent(device_id, message):
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )
    try:
        apps = await asyncio.wait_for(future, timeout=_APPS_TIMEOUT_SECONDS)
    except (TimeoutError, asyncio.CancelledError) as exc:
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="o computador demorou para responder",
        ) from exc
    return [AppOut(**app) for app in apps]


@router.post("/devices/{device_id}/apps/launch", status_code=status.HTTP_204_NO_CONTENT)
async def launch_app(
    device_id: str,
    body: AppActionRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Abre um aplicativo no computador (id = caminho do atalho)."""
    _owned_device_or_404(db, device_id, current_user)
    message = {"type": "launch_app", "id": body.id}
    if not await manager.send_to_agent(device_id, message):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )


@router.post("/devices/{device_id}/apps/close", status_code=status.HTTP_204_NO_CONTENT)
async def close_app(
    device_id: str,
    body: AppActionRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Encerra um aplicativo em execução (id = PID)."""
    _owned_device_or_404(db, device_id, current_user)
    message = {"type": "close_app", "id": body.id}
    if not await manager.send_to_agent(device_id, message):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )


@router.post("/devices/{device_id}/wake", status_code=status.HTTP_204_NO_CONTENT)
async def wake_device(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Acorda um computador desligado via Wake-on-LAN (peer-to-peer).

    O backend não alcança a LAN do usuário: ele escolhe outro computador da
    conta que esteja **online na mesma rede** (mesmo IP público) e pede que ele
    envie o pacote mágico ao MAC do alvo.
    """
    target = _owned_device_or_404(db, device_id, current_user)

    if manager.is_online(device_id):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="o computador já está online"
        )
    if not target.mac_address:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="MAC do computador desconhecido — conecte o agente uma vez para registrá-lo",
        )
    if not target.last_public_ip:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="rede do computador desconhecida ainda",
        )

    # Procura um peer da conta, online, na mesma rede local (mesmo IP público).
    peer_id: str | None = None
    for device in pairing.list_devices(db, current_user):
        if device.device_id == device_id:
            continue
        if manager.is_online(device.device_id) and (
            manager.public_ip(device.device_id) == target.last_public_ip
        ):
            peer_id = device.device_id
            break

    if peer_id is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "nenhum computador ligado na mesma rede para acordar este. "
                "Deixe outro PC ligado nessa rede ou use o modo roteador."
            ),
        )

    await manager.send_to_agent(peer_id, {"type": "wake", "mac": target.mac_address})


@router.post("/devices/{device_id}/screen/start", status_code=status.HTTP_204_NO_CONTENT)
async def start_screen(
    device_id: str,
    fps: int = Body(_STREAM_FPS, embed=True),
    quality: int | None = Body(None, embed=True),
    max_width: int | None = Body(None, embed=True),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Pede ao agente que comece a transmitir a tela (Etapa 7).

    O app pode ajustar desempenho enviando `fps`, `quality` (JPEG) e
    `max_width`; valores fora da faixa são limitados aos extremos aceitos.
    """
    _owned_device_or_404(db, device_id, current_user)
    message: dict = {"type": "start_stream", "max_fps": _clamp(fps, _FPS_RANGE)}
    if quality is not None:
        message["quality"] = _clamp(quality, _QUALITY_RANGE)
    if max_width is not None:
        message["max_width"] = _clamp(max_width, _WIDTH_RANGE)
    if not await manager.send_to_agent(device_id, message):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )


@router.post("/devices/{device_id}/screen/stop", status_code=status.HTTP_204_NO_CONTENT)
async def stop_screen(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Pede ao agente que pare de transmitir a tela."""
    _owned_device_or_404(db, device_id, current_user)
    frame_store.clear(device_id)
    await manager.send_to_agent(device_id, {"type": "stop_stream"})


@router.get("/devices/{device_id}/screen")
def get_screen(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    """Retorna o último frame (JPEG) da tela do computador."""
    _owned_device_or_404(db, device_id, current_user)
    frame = frame_store.get(device_id)
    if frame is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="sem frame disponível (a transmissão já começou?)",
        )
    return Response(content=frame, media_type="image/jpeg")
