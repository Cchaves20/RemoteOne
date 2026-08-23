"""O aviso de que o mês completo está acabando.

Sem ele, os trinta dias passam e a pessoa descobre pelo limite — tenta parear o
segundo computador e é recusada. Descobrir uma mudança de plano batendo numa
porta parece defeito, não parece regra, e a primeira reação é achar que o
produto quebrou.
"""

from datetime import UTC, datetime, timedelta

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import avisos
from app.db import SessionLocal
from app.main import app
from app.models import User

client = TestClient(app)
AGORA = datetime(2026, 8, 23, 12, 0, tzinfo=UTC)


def _quando(dias: float) -> datetime:
    return AGORA + timedelta(days=dias)


def test_avisa_so_na_janela_e_so_uma_vez():
    """As quatro recusas, e cada uma evita um e-mail que geraria desconfiança."""
    # Dentro da janela: avisa.
    assert avisos.deve_avisar("pago", _quando(3), None, AGORA)
    assert avisos.deve_avisar("pago", _quando(5), None, AGORA)

    # Longe demais: um aviso com trinta dias é esquecido antes de importar.
    assert not avisos.deve_avisar("pago", _quando(20), None, AGORA)

    # Já acabou: o aviso chegaria depois do fato.
    assert not avisos.deve_avisar("pago", _quando(-1), None, AGORA)

    # Sem prazo: não há o que acabar.
    assert not avisos.deve_avisar("pago", None, None, AGORA)

    # Já no grátis.
    assert not avisos.deve_avisar("gratis", _quando(3), None, AGORA)

    # Já avisado — e é isto que permite a tarefa rodar todo dia sem virar spam.
    assert not avisos.deve_avisar("pago", _quando(3), _quando(-1), AGORA)


def test_o_texto_diz_primeiro_o_que_continua_funcionando():
    """Uma mensagem que abre com o que se perde é lida como ameaça.

    E a reação a uma ameaça de software é desinstalar. Este teste fixa a ordem
    porque ela é a decisão, não o enfeite.
    """
    assunto, corpo = avisos.texto("Caio", _quando(5))

    assert "28/08" in assunto
    continua = corpo.index("continua")
    para = corpo.index("plano pago")
    assert continua < para, "o aviso abre falando do que se perde"
    assert "Nada é apagado" in corpo


def test_manda_de_verdade_e_marca_a_conta(espiao):
    criar_conta(client, "quase-la@example.com")
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == "quase-la@example.com"))
        user.plano_ate = datetime.now(UTC) + timedelta(days=3)
        db.commit()

    assert avisos.rodar() == 1
    assert espiao.avisos and espiao.avisos[0][0] == "quase-la@example.com"

    # Rodar de novo no mesmo dia não manda outro.
    assert avisos.rodar() == 0
    assert len(espiao.avisos) == 1


def test_falha_de_envio_nao_marca_a_conta(espiao, monkeypatch):
    """Marcar antes de enviar é como se perde um aviso para sempre.

    Um provedor fora do ar por uma hora não pode custar o aviso inteiro: a
    tarefa de amanhã precisa tentar de novo.
    """
    from app import entrega

    criar_conta(client, "provedor-caiu@example.com")
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == "provedor-caiu@example.com"))
        user.plano_ate = datetime.now(UTC) + timedelta(days=2)
        db.commit()

    def explode(*_args, **_kwargs):
        raise entrega.EntregaError("provedor fora do ar")

    monkeypatch.setattr(espiao, "aviso", explode)
    assert avisos.rodar() == 0

    with SessionLocal() as db:
        marca = db.scalar(
            select(User.aviso_fim_teste_em).where(User.email == "provedor-caiu@example.com")
        )
    assert marca is None, "a conta foi marcada sem o e-mail ter saído"


def test_conta_por_telefone_nao_e_marcada_em_silencio(espiao):
    """Sem SMS contratado não há por onde avisar — e fingir que houve some com o caso.

    Marcar como avisada esconderia para sempre que essas contas nunca recebem
    nada, e o defeito só apareceria como "eu não fui avisado" meses depois.
    """
    criar_conta(client, phone="11987654321", country="BR")
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.phone.is_not(None)))
        user.plano_ate = datetime.now(UTC) + timedelta(days=2)
        db.commit()
        user_id = user.id

    assert avisos.rodar() == 0
    with SessionLocal() as db:
        assert db.get(User, user_id).aviso_fim_teste_em is None
