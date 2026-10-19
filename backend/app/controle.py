"""Quem está controlando cada computador, e o "Desconectar" do próprio PC.

O golpe da "mão fantasma" é alguém controlando o computador de outra pessoa
sem ela perceber. A defesa tem duas metades, e as duas passam por aqui:

- **Ver.** O agente recebe a lista de quem está com a tela aberta (`controle`)
  e mostra uma barra no alto da tela enquanto ela não estiver vazia.
- **Cortar.** O "Desconectar" da barra chega como `encerrar_controle`. Fechar
  só a tela não adiantaria — quem invadiu reconectaria no segundo seguinte —,
  então o login de cada aparelho que estava vendo é encerrado, e o dono da
  conta é avisado por e-mail ou SMS. Para voltar, é a senha e, se ligada, a
  verificação em duas etapas.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime

from app import alertas, pairing, sessoes
from app.connections import Viewer, manager, viewers
from app.db import SessionLocal
from app.models import Sessao, User
from app.security import nova_chave_de_sessao

logger = logging.getLogger("deskside")

#: O código com que a tela do app é fechada pelo "Desconectar" do computador.
#: O app reconhece e mostra o motivo em vez de tentar reconectar.
FECHADO_NO_COMPUTADOR = 4403


def identificar(viewer: Viewer, credencial: dict) -> None:
    """Anota no viewer de quem ele é: conta, sessão, nome e aparelho."""
    viewer.user_id = int(credencial["sub"])
    viewer.sid = credencial.get("sid")
    with SessionLocal() as db:
        user = db.get(User, viewer.user_id)
        viewer.nome = user.first_name if user is not None else ""
        sessao = db.get(Sessao, viewer.sid) if viewer.sid else None
        viewer.aparelho = sessao.aparelho if sessao is not None else ""


def mensagem(device_id: str) -> dict:
    """A lista para o agente: um item por tela aberta."""
    return {
        "type": "controle",
        "viewers": [
            {"nome": v.nome, "aparelho": v.aparelho} for v in viewers.de(device_id)
        ],
    }


async def avisar_agente(device_id: str) -> None:
    """Manda a lista atual ao agente. Falhar aqui não pode derrubar a tela."""
    try:
        await manager.send_to_agent(device_id, mensagem(device_id))
    except Exception as exc:  # noqa: BLE001 - o socket do agente pode ter caído
        logger.info("lista de controle não chegou ao agente %s: %s", device_id, exc)


async def encerrar(device_id: str) -> int:
    """Fecha a tela de todos que estão vendo e encerra o login deles.

    Devolve quantas telas foram fechadas.
    """
    alvos = viewers.de(device_id)
    if not alvos:
        return 0
    agora = datetime.now(UTC)
    with SessionLocal() as db:
        device = pairing.get_device(db, device_id)
        computador = device.name if device is not None else device_id
        avisados: set[int] = set()
        avisos = []
        for viewer in alvos:
            user = db.get(User, viewer.user_id) if viewer.user_id else None
            if user is None:
                continue
            sessao = db.get(Sessao, viewer.sid) if viewer.sid else None
            if sessao is not None and sessao.user_id == user.id:
                sessoes.encerrar(sessao, agora)
            else:
                # App de antes das sessões: não há como tirar só ele, então
                # saem todos os aparelhos da conta. Exagero no caso raro é
                # melhor que deixar quem invadiu dentro.
                user.token_key = nova_chave_de_sessao()
            if user.id not in avisados:
                avisados.add(user.id)
                avisos.append(
                    alertas.montar(
                        user, "controle_encerrado", detalhe=computador, agora=agora
                    )
                )
        db.commit()
    for viewer in alvos:
        try:
            await viewer.websocket.close(code=FECHADO_NO_COMPUTADOR)
        except Exception:  # noqa: BLE001 - já pode ter fechado sozinho
            pass
    # Fora do laço de eventos: o envio fala com o SMTP, e o resto do servidor
    # não pode esperar por ele.
    for aviso in avisos:
        await asyncio.to_thread(alertas.enviar, aviso)
    logger.info("controle encerrado no computador %s (%s tela(s))", device_id, len(alvos))
    return len(alvos)
