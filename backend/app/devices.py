"""Rotas de pareamento e gerenciamento de dispositivos (Etapas 5 e 7.2)."""

import asyncio

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Response, status
from sqlalchemy.orm import Session

from app import pairing
from app.auth import get_current_user
from app.connections import manager
from app.db import get_db
from app.input import InputAction
from app.models import Device, User
from app.rpc import pending
from app.schemas import (
    AppActionRequest,
    AppOut,
    ClaimRequest,
    DeviceOut,
    PowerRequest,
    RenameDeviceRequest,
)
from app.screen import frame_store

router = APIRouter(prefix="/api/v1", tags=["devices"])

# Alvo de fps padrão que o backend pede ao agente ao iniciar a transmissão.
_STREAM_FPS = 3
# Faixas aceitas para ajuste de qualidade/desempenho pelo app.
_FPS_RANGE = (1, 30)
_QUALITY_RANGE = (20, 90)
_WIDTH_RANGE = (640, 1920)
# Tempo máximo esperando o agente responder com a lista de aplicativos.
_APPS_TIMEOUT_SECONDS = 15


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


@router.get("/devices/{device_id}/apps", response_model=list[AppOut])
async def list_apps(
    device_id: str,
    kind: str = Query("installed", pattern="^(installed|running)$"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[AppOut]:
    """Lista os aplicativos do computador: instalados ou em execução.

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
