"""Serviço de pareamento (Etapa 5).

Fluxo: o agente conecta → o backend gera um código de pareamento ligado ao
`device_id` → o usuário autenticado informa o código no app → o dispositivo é
vinculado à conta.

O backend é a fonte única do código (garante unicidade e expiração). O
alfabeto e o tamanho espelham o gerador do agente em `agent/src/pairing.rs`.
"""

import hashlib
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


def resumo_de_segredo(segredo: str) -> str:
    """O que vai ao banco no lugar do segredo do agente.

    SHA-256 puro, e não bcrypt: o segredo é sorteado pelo servidor com 32 bytes
    de entropia, então não há dicionário para tentar e não há nada que um custo
    de trabalho torne mais difícil. Bcrypt aqui só custaria CPU a cada conexão
    de agente — e são muitas.

    O que se ganha é o que importa: o banco sai desta máquina todo dia no
    backup, e a partir daqui ele não carrega mais a credencial que controla o
    computador de ninguém. Quem ler uma cópia lê resumos.
    """
    return hashlib.sha256(segredo.encode()).hexdigest()


def e_resumo(guardado: str | None) -> bool:
    """Distingue um resumo (64 hex) de um segredo em texto puro, de antes.

    Sem ambiguidade possível: `novo_segredo_de_agente` devolve 43 caracteres de
    base64, que nunca formam 64 dígitos hexadecimais. É o que permite a troca
    acontecer sem parada e sem migração de uma vez só — ver `_autorizar_agente`.
    """
    if not guardado or len(guardado) != 64:
        return False
    return all(c in "0123456789abcdef" for c in guardado)


def novo_segredo_de_agente() -> str:
    """O segredo que este computador vai apresentar daqui em diante.

    Sorteado **aqui**, no ato do pareamento, e não depois: enquanto um
    dispositivo pareado estiver sem segredo, ele é adotável por quem chegar
    primeiro. Emitir junto com o vínculo faz essa janela não existir.
    """
    return secrets.token_urlsafe(32)


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

    # O segredo nasce em texto puro porque o agente precisa recebê-lo uma vez —
    # e some do banco assim que ele provar que recebeu (ver `_autorizar_agente`).
    # O que fica para sempre é o resumo.
    segredo = novo_segredo_de_agente()
    device = Device(
        device_id=request.device_id,
        user_id=user.id,
        name=request.hostname,
        os=request.os,
        hostname=request.hostname,
        agent_secret=resumo_de_segredo(segredo),
        agent_secret_pendente=segredo,
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


def rename_device(db: Session, device_id: str, user: User, name: str) -> Device | None:
    """Renomeia (apelido) um dispositivo da conta. None se não existir."""
    device = db.scalar(
        select(Device).where(
            Device.device_id == device_id, Device.user_id == user.id
        )
    )
    if device is None:
        return None
    device.name = name
    db.commit()
    db.refresh(device)
    return device


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
