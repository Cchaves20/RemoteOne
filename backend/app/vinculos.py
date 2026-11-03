"""Quem pode falar com qual computador, guardado na memória.

## Por quê

Com a tela aberta, o app pergunta ao computador o programa em primeiro plano a
cada 3 s e os programas abertos a cada 10 s, e cada computador manda uma batida
a cada 10 s. Cada uma dessas perguntas conferia no banco o usuário, a sessão e
o dono do computador — três consultas, com troca de thread em cada uma. No
teste de carga (ver `docs/teste-de-carga.md`), com 160 celulares o servidor
respondia em 1,5 s usando um terço do processador: o tempo ia na fila das
threads, não em trabalho. As respostas mudam raramente — só quando alguém
troca a senha, sai de um aparelho ou despareia um computador —, então elas
ficam aqui, e o banco só é consultado quando falta.

## Por que não fica desatualizado

A memória é apagada **sozinha** quando o banco muda um usuário, uma sessão ou
um computador: um ouvinte nos eventos do SQLAlchemy anota o que mudou em cada
`flush` e apaga depois do `commit` (ver `_ao_gravar`). Nenhuma rota precisa
lembrar de avisar — a troca de senha, o "sair de todos os aparelhos", o
desparear e a exclusão da conta passam todos por ali.

Duas proteções a mais, para o que escapar disso:

- **Validade de 60 s.** Uma mudança feita fora do ORM (um `UPDATE` em massa,
  um ajuste à mão no banco) vale em no máximo um minuto — o mesmo atraso que
  a tela aberta já tinha para perceber uma expulsão (`REVALIDAR_VIEWER`).
- **Geração.** Uma leitura do banco que começou antes de uma mudança não é
  guardada depois dela: sem isso, uma consulta lenta poderia gravar na memória
  a senha velha logo depois de a troca apagá-la.

Um processo só, de propósito: o backend inteiro já depende disso (o registro de
quem está conectado também vive na memória). Com dois processos, cada um teria
a sua, e a apagada num não apagaria no outro.
"""

from __future__ import annotations

import threading
import time

from sqlalchemy import event
from sqlalchemy.orm import Session

#: Por quanto tempo uma resposta vale sem voltar ao banco.
VALIDADE = 60.0

_trava = threading.Lock()
#: (user_id, chave do token, sid) -> quando vence. Só respostas "vale".
_sessoes: dict[tuple[int, str | None, str | None], float] = {}
#: device_id -> (dono, quando vence). Dono `None` = não pareado.
_donos: dict[str, tuple[int | None, float]] = {}
#: Sobe a cada apagada (ver "Geração", acima).
_geracao = 0


def geracao() -> int:
    return _geracao


def _chave(payload: dict) -> tuple[int, str | None, str | None]:
    return (int(payload["sub"]), payload.get("tk"), payload.get("sid"))


def sessao_vale(payload: dict) -> bool:
    """A memória sabe que este token vale? `False` é "não sei", não "não vale"."""
    vence = _sessoes.get(_chave(payload))
    return vence is not None and vence > time.monotonic()


def guardar_sessao(payload: dict, desde: int) -> None:
    """Anota que o token vale — se nada mudou desde a geração `desde`."""
    with _trava:
        if _geracao == desde:
            _sessoes[_chave(payload)] = time.monotonic() + VALIDADE


_NAO_SEI = object()


def dono(device_id: str):
    """O dono do computador (ou `None`, não pareado); `_NAO_SEI` se não sabe."""
    guardado = _donos.get(device_id)
    if guardado is None or guardado[1] <= time.monotonic():
        return _NAO_SEI
    return guardado[0]


def sabe(resposta) -> bool:
    return resposta is not _NAO_SEI


def guardar_dono(device_id: str, user_id: int | None, desde: int) -> None:
    with _trava:
        if _geracao == desde:
            _donos[device_id] = (user_id, time.monotonic() + VALIDADE)


def na_memoria(payload: dict, device_id: str) -> tuple[bool, int | None] | None:
    """`(sessão vale, dono do computador)`, ou `None` se a memória não sabe."""
    resposta = dono(device_id)
    if not sabe(resposta) or not sessao_vale(payload):
        return None
    return True, resposta


def do_banco(payload: dict, device_id: str) -> tuple[bool, int | None]:
    """O mesmo, pelo banco — e guarda o que achou. Bloqueia: numa rota
    assíncrona, chame numa thread (`asyncio.to_thread`)."""
    from app.auth import sessao_valida
    from app.db import SessionLocal
    from app.models import User
    from app.pairing import get_device

    desde = _geracao
    with SessionLocal() as db:
        user = db.get(User, int(payload["sub"]))
        vale = user is not None and sessao_valida(payload, user, db)
        device = get_device(db, device_id)
        o_dono = device.user_id if device is not None else None
    if vale:
        guardar_sessao(payload, desde)
    guardar_dono(device_id, o_dono, desde)
    return vale, o_dono


def dono_do_banco(device_id: str) -> int | None:
    """O dono do computador pelo banco, e guarda. Bloqueia, como `do_banco`."""
    from app.db import SessionLocal
    from app.pairing import get_device

    desde = _geracao
    with SessionLocal() as db:
        device = get_device(db, device_id)
        o_dono = device.user_id if device is not None else None
    guardar_dono(device_id, o_dono, desde)
    return o_dono


def esquecer_tudo() -> None:
    """Para os testes, e para quem mexeu no banco por fora e não quer esperar."""
    global _geracao
    with _trava:
        _sessoes.clear()
        _donos.clear()
        _geracao += 1


# --- a apagada automática ----------------------------------------------------


def _ao_gravar(session: Session, _contexto) -> None:
    """Anota, a cada `flush`, quem mudou: usuários, sessões e computadores."""
    from app.models import Device, Sessao, User

    mudou = session.info.setdefault("vinculos_mudou", {"users": set(), "devices": set()})
    for obj in (*session.new, *session.dirty, *session.deleted):
        if isinstance(obj, User):
            mudou["users"].add(obj.id)
        elif isinstance(obj, Sessao):
            mudou["users"].add(obj.user_id)
        elif isinstance(obj, Device):
            mudou["devices"].add(obj.device_id)


def _apos_confirmar(session: Session) -> None:
    """Depois do `commit`: o banco já tem o novo, e a memória esquece o velho.

    Depois, e não no `flush`: apagando antes, uma leitura que acontecesse entre
    o `flush` e o `commit` ainda veria o banco velho e o guardaria de novo.
    """
    global _geracao
    mudou = session.info.pop("vinculos_mudou", None)
    if not mudou or not (mudou["users"] or mudou["devices"]):
        return
    with _trava:
        _geracao += 1
        if mudou["users"]:
            for chave in [c for c in _sessoes if c[0] in mudou["users"]]:
                del _sessoes[chave]
            for device_id in [d for d, (u, _) in _donos.items() if u in mudou["users"]]:
                del _donos[device_id]
        for device_id in mudou["devices"]:
            _donos.pop(device_id, None)


def _apos_desfazer(session: Session) -> None:
    session.info.pop("vinculos_mudou", None)


event.listen(Session, "after_flush", _ao_gravar)
event.listen(Session, "after_commit", _apos_confirmar)
event.listen(Session, "after_soft_rollback", lambda s, _t: _apos_desfazer(s))
