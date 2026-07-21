"""Rotas de pareamento e gerenciamento de dispositivos (Etapas 5 e 7.2)."""

from fastapi import APIRouter, Body, Depends, HTTPException, Response, status
from sqlalchemy.orm import Session

from app import pairing
from app.auth import get_current_user
from app.connections import manager
from app.db import get_db
from app.input import InputAction
from app.models import Device, User
from app.schemas import ClaimRequest, DeviceOut
from app.screen import frame_store

router = APIRouter(prefix="/api/v1", tags=["devices"])

# Alvo de fps que o backend pede ao agente ao iniciar a transmissão.
_STREAM_FPS = 3


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
    return DeviceOut.model_validate(device)


@router.get("/devices", response_model=list[DeviceOut])
def list_devices(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[DeviceOut]:
    """Lista os computadores pareados na conta."""
    return [DeviceOut.model_validate(d) for d in pairing.list_devices(db, current_user)]


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


@router.post("/devices/{device_id}/screen/start", status_code=status.HTTP_204_NO_CONTENT)
async def start_screen(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Pede ao agente que comece a transmitir a tela (Etapa 7)."""
    _owned_device_or_404(db, device_id, current_user)
    message = {"type": "start_stream", "max_fps": _STREAM_FPS}
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
