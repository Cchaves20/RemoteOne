"""O caminho HTTP da assinatura: validar, vincular, renovar e revogar.

Aqui o que se testa não é a regra (isso é `test_assinatura.py`) — é o que
acontece com o **banco** e com o plano da conta quando ela é aplicada. Três
propriedades importam mais que as outras, e cada uma tem seu bloco:

1. um comprovante vale para **uma** conta;
2. o aplicativo não decide se pagou — a loja decide;
3. um reembolso rebaixa a conta, e uma notificação atrasada não a religa.
"""

from datetime import UTC, datetime, timedelta

import pytest
from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import lojas
from app.assinatura import Ambiente, Compra, Estado, Loja
from app.compras import resumo_do_id
from app.config import settings
from app.db import SessionLocal
from app.main import app
from app.models import Assinatura, User

client = TestClient(app)

PRODUTO = "com.deskside.pro.mensal"


def cabecalho(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


class LojaDeTeste(lojas.Verificador):
    """Um verificador sob controle do teste.

    Existe pelo mesmo motivo do `EntregadorEspiao`: exercitar o fluxo inteiro
    sem conta de loja, sem chave privada e sem esperar uma renovação de verdade.
    O que ele devolve é exatamente o formato que a Apple e o Google devolveriam
    depois de normalizados.
    """

    def __init__(self, compra: Compra | None = None, erro: Exception | None = None):
        self.compra = compra
        self.erro = erro
        self.pedidos: list[str] = []

    def verificar(self, comprovante: str) -> Compra:
        self.pedidos.append(comprovante)
        if self.erro is not None:
            raise self.erro
        return self.compra

    def ler_notificacao(self, corpo: bytes) -> Compra:
        if self.erro is not None:
            raise self.erro
        return self.compra


def uma_compra(
    id_original: str = "1000000000000001",
    estado: Estado = Estado.ATIVA,
    ambiente: Ambiente = Ambiente.PRODUCAO,
    product_id: str = PRODUTO,
    dias: int = 30,
    visto_em: datetime | None = None,
) -> Compra:
    agora = datetime.now(UTC)
    return Compra(
        loja=Loja.APPLE,
        id_original=id_original,
        product_id=product_id,
        estado=estado,
        ambiente=ambiente,
        expira_em=agora + timedelta(days=dias),
        visto_em=visto_em or agora,
    )


@pytest.fixture
def loja(monkeypatch):
    """Instala um verificador controlado no lugar dos de verdade."""
    dublê = LojaDeTeste()
    monkeypatch.setattr(lojas, "verificador_de", lambda _loja: dublê)
    from app import compras

    monkeypatch.setattr(compras.lojas, "verificador_de", lambda _loja: dublê)
    return dublê


def _plano_de(email: str) -> tuple[str, datetime | None]:
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        return user.plano, user.plano_ate


def _rebaixar(email: str) -> None:
    """Deixa a conta no grátis, como o fim dos 30 dias iniciais faria."""
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        user.plano = "gratis"
        user.plano_ate = datetime.now(UTC) - timedelta(seconds=1)
        db.commit()


def _validar(token: str, comprovante: str = "comprovante-de-teste"):
    return client.post(
        "/api/v1/assinatura/validar",
        json={"loja": "apple", "comprovante": comprovante},
        headers=cabecalho(token),
    )


class TestValidar:
    def test_compra_valida_torna_a_conta_paga(self, loja):
        token = criar_conta(client, "assina1@example.com")["access_token"]
        _rebaixar("assina1@example.com")
        loja.compra = uma_compra()

        resposta = _validar(token)

        assert resposta.status_code == 200, resposta.text
        corpo = resposta.json()
        assert corpo["plano"] == "pago"
        assert corpo["ativa"] is True
        assert _plano_de("assina1@example.com")[0] == "pago"

    def test_o_comprovante_do_aplicativo_e_conferido_com_a_loja(self, loja):
        """O aplicativo não afirma que pagou — ele entrega algo para conferir.

        Este teste vigia que o comprovante **chega** ao verificador. Se um dia
        alguém "otimizar" confiando no corpo da requisição, é aqui que quebra.
        """
        token = criar_conta(client, "assina2@example.com")["access_token"]
        loja.compra = uma_compra()

        _validar(token, "jws-vindo-do-storekit")

        assert loja.pedidos == ["jws-vindo-do-storekit"]

    def test_comprovante_recusado_pela_loja_vira_402(self, loja):
        token = criar_conta(client, "assina3@example.com")["access_token"]
        _rebaixar("assina3@example.com")
        loja.erro = lojas.ComprovanteInvalido("transação não encontrada")

        resposta = _validar(token)

        assert resposta.status_code == 402
        assert _plano_de("assina3@example.com")[0] == "gratis"

    def test_loja_fora_do_ar_vira_502_e_nao_libera_nada(self, loja):
        """Falha de rede não pode virar plano pago nem plano cortado.

        502 e não 402: no primeiro caso adianta tentar de novo, no segundo não —
        e o aplicativo precisa dessa diferença para saber se mostra "tente de
        novo" ou "não conseguimos confirmar sua compra".
        """
        token = criar_conta(client, "assina4@example.com")["access_token"]
        _rebaixar("assina4@example.com")
        loja.erro = lojas.LojaError("timeout")

        resposta = _validar(token)

        assert resposta.status_code == 502
        assert _plano_de("assina4@example.com")[0] == "gratis"

    def test_sandbox_nao_libera_plano_pago(self, loja):
        """O buraco mais caro, testado ponta a ponta e não só na regra."""
        token = criar_conta(client, "assina5@example.com")["access_token"]
        _rebaixar("assina5@example.com")
        loja.compra = uma_compra(ambiente=Ambiente.SANDBOX)

        resposta = _validar(token)

        assert resposta.status_code == 200
        assert resposta.json()["ativa"] is False
        assert _plano_de("assina5@example.com")[0] == "gratis"

    def test_sem_token_nao_entra(self, loja):
        loja.compra = uma_compra()
        resposta = client.post(
            "/api/v1/assinatura/validar",
            json={"loja": "apple", "comprovante": "x" * 16},
        )
        assert resposta.status_code == 401


class TestVinculoExclusivo:
    def test_o_mesmo_comprovante_nao_serve_em_duas_contas(self, loja):
        """A fraude mais barata contra compra em loja.

        Assina uma vez, passa o comprovante para o grupo do WhatsApp, e todo
        mundo tem plano pago. A restrição de unicidade em `id_hash` é o que
        impede — e este teste é o que garante que ela existe de verdade, e não
        só na intenção.
        """
        primeiro = criar_conta(client, "dono@example.com")["access_token"]
        segundo = criar_conta(client, "carona@example.com")["access_token"]
        _rebaixar("carona@example.com")
        loja.compra = uma_compra(id_original="transacao-compartilhada")

        assert _validar(primeiro).status_code == 200
        resposta = _validar(segundo)

        assert resposta.status_code == 409
        assert _plano_de("carona@example.com")[0] == "gratis"

    def test_a_recusa_nao_revela_de_quem_e_a_outra_conta(self, loja):
        """Um 409 que dissesse o e-mail do dono confirmaria a existência dele.

        É o mesmo cuidado do 404-antes-do-402 nos dispositivos: a mensagem de
        erro não pode ser um oráculo de contas alheias.
        """
        primeiro = criar_conta(client, "vitima@example.com")["access_token"]
        segundo = criar_conta(client, "curioso@example.com")["access_token"]
        loja.compra = uma_compra(id_original="transacao-espiada")
        _validar(primeiro)

        detalhe = _validar(segundo).json()["detail"]

        assert "vitima@example.com" not in detalhe

    def test_revalidar_na_mesma_conta_e_idempotente(self, loja):
        """Restaurar compras é o mesmo caminho, e a Apple exige que exista.

        Trocar de celular não pode cobrar de novo nem criar uma segunda linha.
        """
        token = criar_conta(client, "restaura@example.com")["access_token"]
        loja.compra = uma_compra(id_original="transacao-unica")

        assert _validar(token).status_code == 200
        assert _validar(token).status_code == 200

        with SessionLocal() as db:
            linhas = db.query(Assinatura).all()
            assert len(linhas) == 1


class TestBanco:
    def test_o_identificador_da_loja_nao_vai_em_texto_puro(self, loja):
        """Uma cópia do banco não pode entregar transações consultáveis.

        O token de compra do Google é credencial: quem o tem consulta a
        assinatura na API do Play. O banco sai da VM todo dia no backup, então
        o que se guarda é o resumo — serve para casar, não para reproduzir.
        """
        token = criar_conta(client, "hash@example.com")["access_token"]
        segredo = "token-de-compra-secreto-do-google"
        loja.compra = uma_compra(id_original=segredo)

        _validar(token)

        with SessionLocal() as db:
            linha = db.query(Assinatura).one()
            assert linha.id_hash == resumo_do_id(Loja.APPLE, segredo)
            assert segredo not in linha.id_hash
            # E nenhuma outra coluna guardou o valor por baixo do pano.
            guardado = " ".join(
                str(getattr(linha, c.name)) for c in linha.__table__.columns
            )
            assert segredo not in guardado

    def test_apagar_a_conta_leva_a_assinatura_junto(self, loja):
        """O SQLite reaproveita id: linha órfã vira plano pago da próxima conta.

        É a mesma armadilha que já mordeu perfis e computadores pareados, agora
        valendo dinheiro.
        """
        token = criar_conta(client, "some@example.com")["access_token"]
        loja.compra = uma_compra()
        _validar(token)

        resposta = client.request(
            "DELETE",
            "/api/v1/auth/me",
            json={"password": "senhaSegura123!"},
            headers=cabecalho(token),
        )
        assert resposta.status_code in (200, 204), resposta.text

        with SessionLocal() as db:
            assert db.query(Assinatura).count() == 0


class TestWebhook:
    def _assinar_conta(self, loja, email: str, id_original: str) -> str:
        token = criar_conta(client, email)["access_token"]
        loja.compra = uma_compra(id_original=id_original)
        _validar(token)
        return token

    def test_reembolso_rebaixa_a_conta(self, loja):
        """O caso que custa dinheiro, agora pelo caminho de verdade.

        A loja avisa o estorno por notificação — não pelo aplicativo, que a
        pessoa reembolsada não vai abrir.
        """
        self._assinar_conta(loja, "estorno@example.com", "transacao-estornada")
        assert _plano_de("estorno@example.com")[0] == "pago"

        loja.compra = uma_compra(
            id_original="transacao-estornada",
            estado=Estado.REVOGADA,
            visto_em=datetime.now(UTC) + timedelta(minutes=5),
        )
        resposta = client.post("/webhooks/apple", content=b"{}")

        assert resposta.status_code == 204
        assert _plano_de("estorno@example.com")[0] == "gratis"

    def test_renovacao_estende_o_prazo(self, loja):
        self._assinar_conta(loja, "renova@example.com", "transacao-renovada")
        _, antes = _plano_de("renova@example.com")

        loja.compra = uma_compra(
            id_original="transacao-renovada",
            dias=60,
            visto_em=datetime.now(UTC) + timedelta(minutes=5),
        )
        client.post("/webhooks/apple", content=b"{}")

        _, depois = _plano_de("renova@example.com")
        assert depois > antes

    def test_notificacao_atrasada_nao_religa_quem_foi_reembolsado(self, loja):
        """A que ninguém escreve, e a que dá o prejuízo silencioso.

        As lojas não prometem ordem. Um `renovou` de dez minutos atrás chegando
        depois de um `reembolsou` devolveria o plano pago a quem já recebeu o
        dinheiro de volta — e tudo pareceria ter funcionado.
        """
        self._assinar_conta(loja, "atrasada@example.com", "transacao-fora-de-ordem")
        agora = datetime.now(UTC)

        loja.compra = uma_compra(
            id_original="transacao-fora-de-ordem",
            estado=Estado.REVOGADA,
            visto_em=agora + timedelta(minutes=10),
        )
        client.post("/webhooks/apple", content=b"{}")
        assert _plano_de("atrasada@example.com")[0] == "gratis"

        # Agora a renovação antiga, que se atrasou na rede.
        loja.compra = uma_compra(
            id_original="transacao-fora-de-ordem",
            estado=Estado.ATIVA,
            visto_em=agora + timedelta(minutes=1),
        )
        client.post("/webhooks/apple", content=b"{}")

        assert _plano_de("atrasada@example.com")[0] == "gratis"

    def test_notificacao_nao_assinada_e_recusada(self, loja):
        """O endereço do webhook não pede senha, e não pode pedir.

        Quem bate ali é a Apple, que não faz login. O que separa a loja de
        qualquer pessoa da internet é a assinatura do corpo — e uma recusa dela
        precisa virar 400, não uma atualização de plano.
        """
        self._assinar_conta(loja, "forjada@example.com", "transacao-forjada")
        loja.erro = lojas.ComprovanteInvalido("assinatura inválida")

        resposta = client.post("/webhooks/apple", content=b'{"forjado": true}')

        assert resposta.status_code == 400
        assert _plano_de("forjada@example.com")[0] == "pago"

    def test_notificacao_de_assinatura_desconhecida_nao_derruba_nada(self, loja):
        """Conta apagada, ou compra nunca validada pelo aplicativo.

        Devolver 500 faria a loja reenviar em intervalos crescentes por dias, e
        a fila das notificações **de verdade** ficaria atrás desta.
        """
        loja.compra = uma_compra(id_original="transacao-que-ninguem-conhece")

        resposta = client.post("/webhooks/apple", content=b"{}")

        assert resposta.status_code == 204


class TestSaude:
    def test_o_health_denuncia_o_modo_sem_loja(self):
        corpo = client.get("/health").json()
        assert corpo["stores"] == {"apple": False, "google": False}
        assert corpo["sandbox_aceito"] is False
        assert "assinatura-loja" in corpo["features"]

    def test_o_verificador_de_mentira_so_produz_sandbox(self):
        """Um servidor sem credencial de loja **não** distribui plano pago.

        É o que garante que subir em produção sem configurar nada falhe fechado:
        o verificador de desenvolvimento existe, responde, e o que ele devolve
        não vale como pagamento.
        """
        assert settings.aceitar_sandbox is False
        compra = lojas.DeMentira().verificar("qualquer-coisa")
        assert compra.ambiente is Ambiente.SANDBOX

        from app.assinatura import vale_como_pago

        assert vale_como_pago(compra) is False

    def test_corpo_gigante_e_recusado_antes_de_ser_lido(self):
        """O único endereço aberto na internet que lê o corpo inteiro.

        Sem teto, um `POST` de um gigabyte derruba uma VM de 1 GB de RAM sem
        precisar de conta, de token e de nada — e o servidor do Deskside tem
        exatamente 1 GB.
        """
        from app.compras import MAX_CORPO_WEBHOOK

        resposta = client.post(
            "/webhooks/apple", content=b"x" * (MAX_CORPO_WEBHOOK + 1)
        )

        assert resposta.status_code == 413
