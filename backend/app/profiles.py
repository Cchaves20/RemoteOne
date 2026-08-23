"""Perfis de controle montados pelo usuário.

Os cinco perfis que vêm com o app (Sistema, Vídeo, Navegador, Trabalho,
Slides) continuam no app: eles são atalhos de teclado, ou seja, código. O que
mora aqui são os perfis **criados pelo usuário**, e o que eles guardam é uma
lista de programas para abrir.

Duas decisões que valem explicação:

- **Ficam no servidor**, não no telefone. A conta é usada em mais de um
  aparelho, e o app instalado por sideload é reinstalado com frequência —
  perfil guardado só no aparelho seria perdido junto com ele.
- **A ordem inclui os perfis de fábrica.** A barra é uma só, e dizer onde um
  perfil criado entra exige saber a fila inteira. Guardar apenas a posição dos
  criados não responderia "antes ou depois do perfil de Vídeo?".
"""

import json
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import cobranca, plano
from app.auth import get_current_user
from app.db import get_db
from app.models import ControlProfile, Device, ProfileLayout, User
from app.schemas import ProfileIn, ProfileOrderIn, ProfileOut, ProfilesOut

router = APIRouter(prefix="/api/v1", tags=["profiles"])

#: Teto de perfis por conta. Não é escassez de espaço: uma barra com cinquenta
#: perfis deixa de ser um atalho e vira uma lista para procurar dentro.
MAX_PROFILES = 30


def _loads(text: str) -> list:
    """JSON guardado por nós. Um valor corrompido vira lista vazia.

    Preferir a lista vazia a estourar é deliberado: um campo ilegível não pode
    derrubar a tela inteira de perfis.
    """
    try:
        value = json.loads(text or "[]")
    except json.JSONDecodeError:
        return []
    return value if isinstance(value, list) else []


def _owned_device_ids(db: Session, user: User) -> set[str]:
    return set(db.scalars(select(Device.device_id).where(Device.user_id == user.id)))


def _to_out(row: ControlProfile, meus: set[str]) -> ProfileOut:
    """Converte a linha do banco no que o app recebe.

    Computadores que saíram da conta são filtrados aqui, e não apagados do
    banco: se a pessoa reparear a mesma máquina, o perfil volta a valer nela
    sem precisar ser editado de novo.
    """
    return ProfileOut(
        id=row.profile_id,
        name=row.name,
        icon=row.icon,
        apps=_loads(row.apps),
        devices=[d for d in _loads(row.devices) if d in meus],
    )


def _check_devices(body: ProfileIn, meus: set[str]) -> None:
    """Recusa computador que não é da conta.

    Aceitar em silêncio guardaria um identificador que nunca casaria com nada,
    e o perfil simplesmente não apareceria — sem nada explicando por quê.
    """
    estranhos = [d for d in body.devices if d not in meus]
    if estranhos:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"computador não encontrado: {estranhos[0]}",
        )


@router.get("/profiles", response_model=ProfilesOut)
def list_profiles(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProfilesOut:
    """Os perfis criados por esta conta, e a ordem da barra."""
    rows = db.scalars(
        select(ControlProfile)
        .where(ControlProfile.user_id == current_user.id)
        .order_by(ControlProfile.position, ControlProfile.id)
    ).all()
    meus = _owned_device_ids(db, current_user)
    layout = db.get(ProfileLayout, current_user.id)
    return ProfilesOut(
        profiles=[_to_out(r, meus) for r in rows],
        order=_loads(layout.order) if layout else [],
    )


@router.post("/profiles", response_model=ProfileOut, status_code=status.HTTP_201_CREATED)
def create_profile(
    body: ProfileIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProfileOut:
    """Cria um perfil. O identificador é gerado aqui e nunca muda."""
    cobranca.exigir_recurso(current_user, plano.Recurso.PERFIS)
    meus = _owned_device_ids(db, current_user)
    _check_devices(body, meus)

    quantos = len(
        db.scalars(
            select(ControlProfile.id).where(ControlProfile.user_id == current_user.id)
        ).all()
    )
    if quantos >= MAX_PROFILES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"limite de {MAX_PROFILES} perfis por conta",
        )

    row = ControlProfile(
        profile_id=f"u-{uuid.uuid4().hex[:16]}",
        user_id=current_user.id,
        name=body.name,
        icon=body.icon,
        position=quantos,
        apps=json.dumps([a.model_dump() for a in body.apps]),
        devices=json.dumps(body.devices),
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return _to_out(row, meus)


# `/profiles/order` vem **antes** de `/profiles/{profile_id}`: o FastAPI casa as
# rotas na ordem em que foram declaradas, e ao contrário disto um pedido de
# reordenação cairia no endpoint de edição com `profile_id="order"`.
@router.put("/profiles/order", status_code=status.HTTP_204_NO_CONTENT)
def set_order(
    body: ProfileOrderIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Guarda a ordem da barra.

    A lista chega inteira, com os perfis de fábrica junto — é o app que sabe
    quais são eles. O servidor não valida os identificadores de fábrica: eles
    são código do app, e uma versão nova pode trazer outros. O que ele faz é
    guardar a fila como ela veio, e o app ignora o que não reconhece.
    """
    layout = db.get(ProfileLayout, current_user.id)
    if layout is None:
        layout = ProfileLayout(user_id=current_user.id)
        db.add(layout)
    layout.order = json.dumps(body.ids)
    db.commit()


def _owned_profile(db: Session, profile_id: str, user: User) -> ControlProfile:
    row = db.scalar(
        select(ControlProfile).where(ControlProfile.profile_id == profile_id)
    )
    # Mesmo 404 para "não existe" e "é de outra conta": distinguir os dois diria
    # a um estranho quais identificadores existem.
    if row is None or row.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="perfil não encontrado"
        )
    return row


@router.put("/profiles/{profile_id}", response_model=ProfileOut)
def update_profile(
    profile_id: str,
    body: ProfileIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProfileOut:
    """Substitui o conteúdo de um perfil. O identificador continua o mesmo."""
    # A checagem de dono vem **antes**: quem edita perfil alheio recebe 404, e
    # não uma oferta de plano — dizer "isto é pago" sobre o que é de outra
    # pessoa confirmaria que aquilo existe.
    row = _owned_profile(db, profile_id, current_user)
    cobranca.exigir_recurso(current_user, plano.Recurso.PERFIS)
    meus = _owned_device_ids(db, current_user)
    _check_devices(body, meus)

    row.name = body.name
    row.icon = body.icon
    row.apps = json.dumps([a.model_dump() for a in body.apps])
    row.devices = json.dumps(body.devices)
    db.commit()
    db.refresh(row)
    return _to_out(row, meus)


@router.delete("/profiles/{profile_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_profile(
    profile_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Apaga um perfil e o tira da ordem guardada."""
    row = _owned_profile(db, profile_id, current_user)
    db.delete(row)

    # Sem isto, o identificador apagado ficaria na ordem para sempre — inofensivo
    # hoje, mas um lixo que cresce a cada perfil removido.
    layout = db.get(ProfileLayout, current_user.id)
    if layout is not None:
        restante = [i for i in _loads(layout.order) if i != profile_id]
        layout.order = json.dumps(restante)
    db.commit()
