"""Serviço de pareamento (Etapa 5).

Fluxo: o agente conecta → o backend gera um código de pareamento ligado ao
`device_id` → o usuário autenticado informa o código no app → o dispositivo é
vinculado à conta.

O backend é a fonte única do código (garante unicidade e expiração). O
alfabeto e o tamanho espelham o gerador do agente em `agent/src/pairing.rs`.
"""

import secrets
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import Device, PairingRequest, User

# Alfabeto sem caracteres ambíguos (0/O, 1/I/L), igual ao agente.
_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_CODE_LEN = 9


class PairingError(Exception):
    """Erro de pareamento com um status HTTP associado."""

    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def generate_pairing_code() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(_CODE_LEN))


def _as_aware_utc(dt: datetime) -> datetime:
    # SQLite devolve datetimes ingênuos; assumimos UTC para comparar.
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=UTC)


def get_device(db: Session, device_id: str) -> Device | None:
    return db.scalar(select(Device).where(Device.device_id == device_id))


def create_pairing_request(
    db: Session,
    device_id: str,
    hostname: str,
    os: str,
    ttl_seconds: int,
) -> str:
    """Cria (ou substitui) o código pendente do dispositivo e o retorna."""
    # Um pedido pendente por dispositivo: remove os anteriores.
    db.execute(delete(PairingRequest).where(PairingRequest.device_id == device_id))

    # Gera um código único (colisão é rara, mas tratamos mesmo assim).
    code = generate_pairing_code()
    while db.scalar(select(PairingRequest).where(PairingRequest.code == code)):
        code = generate_pairing_code()

    db.add(
        PairingRequest(
            code=code,
            device_id=device_id,
            hostname=hostname,
            os=os,
            expires_at=datetime.now(UTC) + timedelta(seconds=ttl_seconds),
        )
    )
    db.commit()
    return code


def claim(db: Session, code: str, user: User) -> Device:
    """Vincula o dispositivo do código à conta do usuário."""
    request = db.scalar(select(PairingRequest).where(PairingRequest.code == code))
    if request is None:
        raise PairingError(404, "código de pareamento inválido")

    if _as_aware_utc(request.expires_at) < datetime.now(UTC):
        db.delete(request)
        db.commit()
        raise PairingError(410, "código de pareamento expirado")

    if get_device(db, request.device_id) is not None:
        raise PairingError(409, "dispositivo já pareado")

    device = Device(
        device_id=request.device_id,
        user_id=user.id,
        name=request.hostname,
        os=request.os,
        hostname=request.hostname,
    )
    db.add(device)
    db.delete(request)
    db.commit()
    db.refresh(device)
    return device


def list_devices(db: Session, user: User) -> list[Device]:
    return list(
        db.scalars(select(Device).where(Device.user_id == user.id).order_by(Device.id))
    )


def remove_device(db: Session, device_id: str, user: User) -> bool:
    device = db.scalar(
        select(Device).where(
            Device.device_id == device_id, Device.user_id == user.id
        )
    )
    if device is None:
        return False
    db.delete(device)
    db.commit()
    return True
