"""O segredo do agente não fica em texto puro no banco.

## Por que isto virou um arquivo próprio

Porque a revisão mediu e achou o contrário do que se supunha: a senha da conta
estava com bcrypt, e o segredo do agente — que **controla o computador da
pessoa** — estava em texto puro na mesma tabela. As duas coisas saem da VM
juntas, todo dia, na cópia de segurança.

Não é um detalhe de higiene. Quem lesse uma cópia do banco passava a ser cada
computador pareado: recebia as teclas digitadas, via a tela, abria arquivos. É
uma credencial mais poderosa que a senha, porque a senha ainda esbarra no 2FA.

Estes testes existem para que ela não volte a ser guardada assim.
"""

import hashlib

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import pairing
from app.db import SessionLocal
from app.main import _autorizar_agente, _segredo_do_aparelho
from app.main import app
from app.models import Device, User

client = TestClient(app)


def _conta(email: str) -> User:
    criar_conta(client, email)
    with SessionLocal() as db:
        return db.scalar(select(User).where(User.email == email))


def _parear(email: str, device_id: str) -> tuple[str, int]:
    """Pareia pelo caminho de verdade e devolve (segredo entregue, user_id)."""
    user = _conta(email)
    with SessionLocal() as db:
        dono = db.get(User, user.id)
        code = pairing.create_pairing_request(db, device_id, "PC", "windows", 600)
        pairing.claim(db, code, dono)
        db.commit()
    segredo = _segredo_do_aparelho(device_id)
    return segredo, user.id


def _linha(device_id: str) -> Device:
    with SessionLocal() as db:
        return db.scalar(select(Device).where(Device.device_id == device_id))


class TestNaoFicaEmTextoPuro:
    def test_a_coluna_definitiva_guarda_o_resumo(self):
        segredo, _ = _parear("seg1@example.com", "dev-seg-1")
        linha = _linha("dev-seg-1")

        assert linha.agent_secret == hashlib.sha256(segredo.encode()).hexdigest()
        assert linha.agent_secret != segredo
        assert pairing.e_resumo(linha.agent_secret)

    def test_o_texto_puro_some_quando_o_agente_prova_que_recebeu(self):
        """A janela existe e é curta — de propósito, e só até o primeiro uso.

        Não some no envio: se a entrega falhar no meio, apagar aqui trancaria o
        computador para fora da própria conta, sem nada explicando por quê.
        """
        segredo, _ = _parear("seg2@example.com", "dev-seg-2")
        assert _linha("dev-seg-2").agent_secret_pendente == segredo

        entregue, autenticado = _autorizar_agente("dev-seg-2", segredo)

        assert autenticado is True
        assert entregue is None
        assert _linha("dev-seg-2").agent_secret_pendente is None

    def test_o_segredo_certo_continua_entrando(self):
        """A conferência por resumo não pode ter quebrado a porta da frente."""
        segredo, _ = _parear("seg3@example.com", "dev-seg-3")
        assert _autorizar_agente("dev-seg-3", segredo) == (None, True)

    def test_o_segredo_errado_continua_sendo_recusado(self):
        import pytest

        from app.main import SegredoRecusado

        _parear("seg4@example.com", "dev-seg-4")
        with pytest.raises(SegredoRecusado):
            _autorizar_agente("dev-seg-4", "nao-e-esse-segredo")

    def test_o_resumo_guardado_nao_serve_como_segredo(self):
        """O ataque óbvio contra hash mal usado: apresentar o que está no banco.

        Se a conferência comparasse o apresentado direto com a coluna, quem
        lesse o banco entraria com o próprio resumo — e o hash não teria
        protegido nada.
        """
        import pytest

        from app.main import SegredoRecusado

        _parear("seg5@example.com", "dev-seg-5")
        guardado = _linha("dev-seg-5").agent_secret

        with pytest.raises(SegredoRecusado):
            _autorizar_agente("dev-seg-5", guardado)


class TestConversaoSemParada:
    """As linhas criadas antes desta mudança precisam continuar funcionando.

    A alternativa seria uma migração de uma vez só — e ela é impossível aqui:
    do texto puro dá para derivar o resumo, mas um agente que estivesse
    desligado no momento errado não teria como saber o que aconteceu.
    """

    def _envelhecer(self, device_id: str, segredo: str) -> None:
        """Devolve a linha ao formato antigo: texto puro na coluna definitiva."""
        with SessionLocal() as db:
            linha = db.scalar(select(Device).where(Device.device_id == device_id))
            linha.agent_secret = segredo
            linha.agent_secret_pendente = None
            db.commit()

    def test_agente_antigo_entra_e_a_linha_sobe_sozinha(self):
        segredo, _ = _parear("seg6@example.com", "dev-seg-6")
        self._envelhecer("dev-seg-6", segredo)
        assert not pairing.e_resumo(_linha("dev-seg-6").agent_secret)

        assert _autorizar_agente("dev-seg-6", segredo) == (None, True)

        # Entrou **e** converteu: a próxima leitura do banco já não tem o
        # segredo. Sem esta metade, a conversão dependeria de alguém rodar algo.
        depois = _linha("dev-seg-6").agent_secret
        assert pairing.e_resumo(depois)
        assert depois == hashlib.sha256(segredo.encode()).hexdigest()

    def test_a_conversao_nao_aceita_segredo_errado(self):
        """O caminho de compatibilidade não pode ser a porta dos fundos."""
        import pytest

        from app.main import SegredoRecusado

        segredo, _ = _parear("seg7@example.com", "dev-seg-7")
        self._envelhecer("dev-seg-7", segredo)

        with pytest.raises(SegredoRecusado):
            _autorizar_agente("dev-seg-7", "chute")

        # E não converteu nada ao errar.
        assert not pairing.e_resumo(_linha("dev-seg-7").agent_secret)

    def test_entrega_ao_agente_funciona_nos_dois_formatos(self):
        segredo, _ = _parear("seg8@example.com", "dev-seg-8")
        assert _segredo_do_aparelho("dev-seg-8") == segredo

        self._envelhecer("dev-seg-8", segredo)
        assert _segredo_do_aparelho("dev-seg-8") == segredo

        # Já convertida e já entregue: não há mais o que entregar.
        _autorizar_agente("dev-seg-8", segredo)
        assert _segredo_do_aparelho("dev-seg-8") is None


class TestAdocao:
    def test_a_adocao_guarda_so_o_resumo(self):
        """Adoção entrega o segredo na própria resposta.

        Não há espera, então não há nada a guardar em texto puro — e guardar
        assim mesmo seria deixar a exposição de graça.
        """
        segredo, _ = _parear("seg9@example.com", "dev-seg-9")
        with SessionLocal() as db:
            linha = db.scalar(select(Device).where(Device.device_id == "dev-seg-9"))
            linha.agent_secret = None
            linha.agent_secret_pendente = None
            db.commit()

        emitido, autenticado = _autorizar_agente("dev-seg-9", "")

        assert autenticado is True
        assert emitido and emitido != segredo
        linha = _linha("dev-seg-9")
        assert linha.agent_secret == hashlib.sha256(emitido.encode()).hexdigest()
        assert linha.agent_secret_pendente is None
