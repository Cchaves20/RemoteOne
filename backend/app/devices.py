"""Rotas de pareamento e gerenciamento de dispositivos (Etapas 5 e 7.2)."""

from fastapi import APIRouter, Body, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app import pairing
from app.auth import get_current_user
from app.connections import manager
from app.db import get_db
from app.input import InputAction
from app.models import User
from app.schemas import ClaimRequest, DeviceOut

router = APIRouter(prefix="/api/v1", tags=["devices"])


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
    device = pairing.get_device(db, device_id)
    if device is None or device.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="dispositivo não encontrado"
        )

    envelope = {"type": "input", "action": action.model_dump()}
    if not await manager.send_to_agent(device_id, envelope):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="agente offline",
        )
