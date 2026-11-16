"""O widget do celular: um computador e três botões, escolhidos pela pessoa.

A configuração mora aqui (ver `models.WidgetConfig` para o porquê), e quem lê
é o widget — que precisa de nomes prontos para escrever na tela e do estado
de agora (o computador está online?). Por isso a resposta já vem resolvida.

## Referências que somem

O computador escolhido pode sair da conta, e a automação de um botão pode
ser apagada. Nada disso apaga a configuração: na leitura, o que sumiu é
trocado pelo padrão (o primeiro computador) ou deixado de fora (o botão de
uma automação que não existe mais). Um widget que mostra um botão quebrado
ensina a pessoa a não confiar nele.
"""

import json

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import get_current_user
from app.connections import manager
from app.db import get_db
from app.models import Automation, Device, User, WidgetConfig
from app.schemas import BotaoDoWidgetOut, WidgetIn, WidgetOut

router = APIRouter(prefix="/api/v1", tags=["widget"])


def _computadores(db: Session, user: User) -> list[Device]:
    return list(
        db.scalars(
            select(Device).where(Device.user_id == user.id).order_by(Device.id)
        )
    )


def _automacoes(db: Session, user: User) -> list[Automation]:
    return list(
        db.scalars(
            select(Automation)
            .where(Automation.user_id == user.id)
            .order_by(Automation.position, Automation.id)
        )
    )


def _ler(db: Session, user: User) -> dict:
    linha = db.get(WidgetConfig, user.id)
    if linha is None:
        return {}
    try:
        dados = json.loads(linha.dados or "{}")
    except json.JSONDecodeError:
        return {}
    return dados if isinstance(dados, dict) else {}


def montar(db: Session, user: User) -> WidgetOut:
    """O widget como ele deve aparecer agora."""
    dados = _ler(db, user)
    computadores = _computadores(db, user)
    automacoes = {a.automation_id: a for a in _automacoes(db, user)}

    escolhido = next(
        (d for d in computadores if d.device_id == dados.get("device_id")), None
    )
    computador = escolhido or (computadores[0] if computadores else None)

    if "botoes" in dados:
        brutos = dados.get("botoes") or []
    else:
        # Nunca configurado: o que a tela sugere — apresentação, tocar/pausar
        # e a primeira automação, se houver uma.
        brutos = [{"tipo": "apresentacao"}, {"tipo": "tocar_pausar"}]
        primeira = next(iter(automacoes), None)
        if primeira:
            brutos.append({"tipo": "automacao", "automacao_id": primeira})

    botoes: list[BotaoDoWidgetOut] = []
    for bruto in brutos[:3]:
        if not isinstance(bruto, dict):
            continue
        if bruto.get("tipo") == "automacao":
            automacao = automacoes.get(bruto.get("automacao_id") or "")
            if automacao is None:
                continue
            botoes.append(
                BotaoDoWidgetOut(
                    tipo="automacao",
                    automacao_id=automacao.automation_id,
                    automacao_nome=automacao.name,
                )
            )
        else:
            try:
                botoes.append(BotaoDoWidgetOut(tipo=bruto.get("tipo")))
            except ValueError:
                continue  # tipo que esta versão não conhece

    atalhos = [i for i in (dados.get("atalhos") or []) if i in automacoes][:4]

    return WidgetOut(
        device_id=computador.device_id if computador else None,
        device_name=computador.name if computador else None,
        online=manager.is_online(computador.device_id) if computador else False,
        botoes=botoes,
        atalhos=atalhos,
    )


@router.get("/widget", response_model=WidgetOut)
def ler_widget(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> WidgetOut:
    return montar(db, current_user)


@router.put("/widget", response_model=WidgetOut)
def salvar_widget(
    body: WidgetIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> WidgetOut:
    """Guarda a escolha. Tudo o que ela cita precisa ser desta conta."""
    meus = {d.device_id for d in _computadores(db, current_user)}
    if body.device_id is not None and body.device_id not in meus:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="computador não encontrado"
        )
    minhas = {a.automation_id for a in _automacoes(db, current_user)}
    for botao in body.botoes:
        if botao.tipo == "automacao":
            if not botao.automacao_id:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail="escolha qual automação o botão roda",
                )
            if botao.automacao_id not in minhas:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="automação não encontrada",
                )
        elif botao.automacao_id is not None:
            # Lixo de uma escolha anterior: não guardar o que não vale.
            botao.automacao_id = None
    for atalho in body.atalhos:
        if atalho not in minhas:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="automação não encontrada"
            )

    linha = db.get(WidgetConfig, current_user.id)
    if linha is None:
        linha = WidgetConfig(user_id=current_user.id)
        db.add(linha)
    linha.dados = json.dumps(body.model_dump(), ensure_ascii=False)
    db.commit()
    return montar(db, current_user)
