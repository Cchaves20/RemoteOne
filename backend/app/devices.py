"""Rotas de pareamento e gerenciamento de dispositivos (Etapas 5 e 7.2)."""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app import pairing
from app.auth import get_current_user
from app.db import get_db
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
