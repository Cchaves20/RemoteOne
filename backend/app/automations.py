"""Automações: uma sequência de passos que um toque executa.

O irmão dos perfis, e deliberadamente uma tela ao lado da deles em vez de uma
aba escondida nas configurações. A diferença entre os dois cabe numa frase e
aparece no uso: num perfil a ordem não significa nada — são botões lado a lado,
e você toca no que quiser —, enquanto numa automação a ordem **é** o recurso.

Duas decisões que valem explicação:

- **A sequência inteira vai numa mensagem só, e o computador executa.** Não é
  detalhe de implementação: o iOS suspende o app quando a tela apaga. Se o
  telefone mandasse passo a passo, bastaria a pessoa bloquear o aparelho para a
  rotina parar no meio — com o Teams aberto, o som ainda alto e o brilho como
  estava.
- **Uma falha não interrompe as seguintes.** Se o Slack não estava aberto para
  ser fechado, o brilho ainda deve baixar e a máquina ainda deve suspender: quem
  pediu "fim do expediente" quer o expediente encerrado, não uma verificação de
  integridade. Mas o resultado de cada passo volta, e o app mostra qual falhou.
"""

import asyncio
import json
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import pairing
from app.auth import get_current_user
from app.connections import manager
from app.db import get_db
from app.models import Automation, User
from app.rpc import pending
from app.schemas import (
    AutomationIn,
    AutomationOut,
    AutomationRunOut,
    AutomationsOut,
    StepResultOut,
)

router = APIRouter(prefix="/api/v1", tags=["automations"])

#: Teto por conta. Mesmo raciocínio dos perfis: uma lista com cinquenta
#: automações deixa de ser um atalho e vira uma lista para procurar dentro.
MAX_AUTOMATIONS = 30

#: Quanto esperar pela sequência inteira.
#:
#: O mais folgado de todos os pedidos ao agente, e por construção: são até 24
#: passos, e o próprio agente já se limita a 60 segundos de espera somada mais
#: o tempo de cada ação. Curto demais aqui daria 504 numa automação que estava
#: funcionando — e pior, sem dizer até onde ela chegou.
_RUN_TIMEOUT_SECONDS = 150


def _loads(text: str) -> list:
    """JSON guardado por nós. Um valor corrompido vira lista vazia.

    Preferir a lista vazia a estourar é deliberado: um campo ilegível não pode
    derrubar a tela inteira de automações.
    """
    try:
        value = json.loads(text or "[]")
    except json.JSONDecodeError:
        return []
    return value if isinstance(value, list) else []


async def enviar_agenda(db: Session, user_id: int, device_id: str) -> None:
    """Manda ao computador as automações agendadas que rodam nele.

    É o que torna o agendamento independente do celular: o agente guarda a
    agenda e dispara sozinho, mesmo com o telefone descarregado, longe ou
    desinstalado. Se o servidor tivesse de mandar o comando na hora, "18:00"
    dependeria de o servidor estar de pé às 18:00 **e** de a máquina estar
    conectada naquele exato minuto - em vez de em qualquer momento antes.

    Manda a agenda **inteira**, e não a diferença: é uma lista curta, e lista
    inteira não tem como dessincronizar. Com diferenças, um envio perdido
    deixaria o computador com uma automação fantasma para sempre.

    Agenda vazia é resposta válida e importante - é como se apaga o que foi
    desagendado.
    """
    linhas = db.scalars(
        select(Automation).where(
            Automation.user_id == user_id,
            Automation.device_id == device_id,
            Automation.schedule_time != "",
        )
    ).all()
    agenda = [
        {
            "id": row.automation_id,
            "name": row.name,
            "time": row.schedule_time,
            "days": [d for d in _loads(row.schedule_days) if isinstance(d, int)],
            "steps": _loads(row.steps),
        }
        for row in linhas
    ]
    await manager.send_to_agent(device_id, {"type": "set_schedule", "items": agenda})


async def _reenviar_agendas(db: Session, user: User, *device_ids: str) -> None:
    """Reenvia a agenda dos computadores tocados por uma mudança.

    Aceita mais de um identificador porque editar uma automação pode **mudar**
    de computador: o novo passa a ter o agendamento, e o antigo precisa
    perdê-lo. Reenviando só ao novo, o antigo continuaria disparando o que já
    não é dele.
    """
    for device_id in {d for d in device_ids if d}:
        await enviar_agenda(db, user.id, device_id)


def _to_out(row: Automation) -> AutomationOut:
    # Agendamento sem computador é lido como "não agendada", e não devolvido
    # como está. Duas razões, e as duas importam:
    #
    # - `AutomationOut` herda a validação de `AutomationIn`, que agora recusa
    #   essa combinação. Uma linha antiga assim derrubaria a listagem **inteira**
    #   com 500 - a tela de perfis sumiria por causa de uma automação.
    # - Ela nunca disparou de verdade: sem computador não há a quem mandar a
    #   agenda. Mostrar "18:00" seria prometer o que não acontece.
    agendada = bool(row.device_id and row.schedule_time)
    return AutomationOut(
        id=row.automation_id,
        name=row.name,
        icon=row.icon,
        steps=_loads(row.steps),
        device_id=row.device_id,
        schedule_time=row.schedule_time if agendada else "",
        schedule_days=[d for d in _loads(row.schedule_days) if isinstance(d, int)]
        if agendada
        else [],
    )


def _passos(body: AutomationIn) -> str:
    """Serializa os passos jogando fora os campos que não são do tipo.

    `exclude_none` importa: um passo `media` carrega `id`, `zone`, `level` e
    `delta` nulos só porque o `StepIn` tem um campo por tipo. Gravá-los faria o
    agente receber `{"kind":"media","action":...,"level":null,...}` — que o
    `serde` do Rust recusaria inteiro, e o passo falharia sem motivo aparente.
    """
    return json.dumps([s.model_dump(exclude_none=True) for s in body.steps])


def _check_device(body: AutomationIn, db: Session, user: User) -> None:
    """Recusa computador que não é da conta.

    Aceitar em silêncio guardaria um identificador que nunca casaria com nada,
    e a automação simplesmente não rodaria — sem nada explicando por quê.
    """
    if not body.device_id:
        return
    device = pairing.get_device(db, body.device_id)
    if device is None or device.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"computador não encontrado: {body.device_id}",
        )


def _owned(db: Session, automation_id: str, user: User) -> Automation:
    row = db.scalar(
        select(Automation).where(Automation.automation_id == automation_id)
    )
    # Mesmo 404 para "não existe" e "é de outra conta": distinguir os dois diria
    # a um estranho quais identificadores existem.
    if row is None or row.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="automação não encontrada"
        )
    return row


# `exclude_none` aqui é a mesma limpeza que `_passos` faz na gravação, e pelo
# mesmo motivo: o `StepIn` tem um campo por tipo, então um passo `media` sai com
# `id`, `zone`, `level` e `delta` nulos. Sem isto, o que o app recebe não é o
# que está guardado, e comparar os dois numa investigação levaria ao lado
# errado.
@router.get(
    "/automations", response_model=AutomationsOut, response_model_exclude_none=True
)
def list_automations(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AutomationsOut:
    """As automações desta conta, na ordem em que foram criadas."""
    rows = db.scalars(
        select(Automation)
        .where(Automation.user_id == current_user.id)
        .order_by(Automation.position, Automation.id)
    ).all()
    return AutomationsOut(automations=[_to_out(r) for r in rows])


@router.post(
    "/automations",
    response_model=AutomationOut,
    response_model_exclude_none=True,
    status_code=status.HTTP_201_CREATED,
)
async def create_automation(
    body: AutomationIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AutomationOut:
    """Cria uma automação. O identificador é gerado aqui e nunca muda."""
    _check_device(body, db, current_user)

    quantas = len(
        db.scalars(
            select(Automation.id).where(Automation.user_id == current_user.id)
        ).all()
    )
    if quantas >= MAX_AUTOMATIONS:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"limite de {MAX_AUTOMATIONS} automações por conta",
        )

    row = Automation(
        automation_id=f"u-{uuid.uuid4().hex[:16]}",
        user_id=current_user.id,
        name=body.name,
        icon=body.icon,
        position=quantas,
        steps=_passos(body),
        device_id=body.device_id,
        schedule_time=body.schedule_time,
        schedule_days=json.dumps(sorted(body.schedule_days)),
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    await _reenviar_agendas(db, current_user, row.device_id)
    return _to_out(row)


@router.put(
    "/automations/{automation_id}",
    response_model=AutomationOut,
    response_model_exclude_none=True,
)
async def update_automation(
    automation_id: str,
    body: AutomationIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AutomationOut:
    """Substitui o conteúdo de uma automação. O identificador continua o mesmo."""
    row = _owned(db, automation_id, current_user)
    _check_device(body, db, current_user)

    # O computador de antes precisa saber que perdeu a automação; o de agora,
    # que ganhou. Guardado antes da escrita, senão só sobra o novo.
    antes = row.device_id

    row.name = body.name
    row.icon = body.icon
    row.steps = _passos(body)
    row.device_id = body.device_id
    row.schedule_time = body.schedule_time
    row.schedule_days = json.dumps(sorted(body.schedule_days))
    db.commit()
    db.refresh(row)
    await _reenviar_agendas(db, current_user, antes, row.device_id)
    return _to_out(row)


@router.delete(
    "/automations/{automation_id}", status_code=status.HTTP_204_NO_CONTENT
)
async def delete_automation(
    automation_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Apaga uma automação."""
    row = _owned(db, automation_id, current_user)
    # Guardado antes de apagar: depois do `delete` a linha não responde mais.
    onde = row.device_id
    db.delete(row)
    db.commit()
    # Sem isto, apagar uma automação agendada a deixaria disparando no
    # computador para sempre - o agente só sabe o que lhe contaram.
    await _reenviar_agendas(db, current_user, onde)


@router.post(
    "/automations/{automation_id}/run", response_model=AutomationRunOut
)
async def run_automation(
    automation_id: str,
    device_id: str = "",
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AutomationRunOut:
    """Executa a automação num computador e conta o que aconteceu em cada passo.

    O computador vem do parâmetro quando a automação não fixou um. É o caso de
    quem tem duas máquinas e a mesma rotina nas duas — fixar obrigaria a criar a
    automação duas vezes.

    Uma automação sem passo nenhum é recusada aqui em vez de virar uma ida ao
    computador que não faz nada: o resultado seria uma lista vazia, e uma lista
    vazia é indistinguível de "rodou tudo e nada deu errado".
    """
    row = _owned(db, automation_id, current_user)

    alvo = row.device_id or device_id
    if not alvo:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="escolha em qual computador rodar",
        )
    device = pairing.get_device(db, alvo)
    if device is None or device.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="dispositivo não encontrado"
        )

    passos = _loads(row.steps)
    if not passos:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="esta automação está sem passos",
        )

    request_id, future = pending.create()
    message = {
        "type": "run_automation",
        "request_id": request_id,
        "steps": passos,
    }
    if not await manager.send_to_agent(alvo, message):
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="agente offline"
        )
    try:
        reply = await asyncio.wait_for(future, timeout=_RUN_TIMEOUT_SECONDS)
    except (TimeoutError, asyncio.CancelledError) as exc:
        pending.cancel(request_id)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="o computador demorou para responder",
        ) from exc
    return AutomationRunOut(
        results=[StepResultOut(**r) for r in reply.get("results", [])]
    )
