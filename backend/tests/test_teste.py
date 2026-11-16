"""Um teste de 30 dias por pessoa — e no máximo dois por computador.

O que se protege aqui é o atalho de graça: criar outra conta a cada mês com
`+sufixo` no mesmo Gmail, ou reinstalar o agente no mesmo PC. O que **não**
pode acontecer é o contrário — negar o teste a uma pessoa de verdade, ou cortar
o plano de quem paga. Metade dos testes guarda esse segundo lado.
"""

import hashlib
from datetime import UTC, datetime, timedelta

from conftest import criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import pairing, teste
from app.db import SessionLocal
from app.main import app
from app.models import TesteConcedido, User

client = TestClient(app)

MAQUINA = hashlib.sha256(b"deskside:maquina:{GUID-DO-PC-DA-SALA}").hexdigest()
OUTRA_MAQUINA = hashlib.sha256(b"deskside:maquina:{GUID-DO-NOTEBOOK}").hexdigest()


def cabecalho(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _plano(email: str) -> tuple[str, datetime | None]:
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == email))
        return user.plano, user.plano_ate


def _parear(token: str, device_id: str, maquina: str | None) -> dict:
    """O agente se apresenta com este resumo, e a conta digita o código."""
    with SessionLocal() as db:
        codigo = pairing.create_pairing_request(
            db, device_id, "PC-DA-SALA", "windows", 300, maquina=maquina
        )
    resposta = client.post(
        "/api/v1/pairing/claim", json={"code": codigo}, headers=cabecalho(token)
    )
    assert resposta.status_code == 201, resposta.text
    return resposta.json()


class TestEmailCanonico:
    def test_sufixo_mais_e_ignorado(self):
        # O atalho de graça: uma caixa do Gmail, contas infinitas.
        assert teste.email_canonico("caio+1@gmail.com") == "caio@gmail.com"
        assert teste.email_canonico("caio+teste.dois@outlook.com") == "caio@outlook.com"

    def test_pontos_so_somem_no_gmail(self):
        assert teste.email_canonico("c.a.i.o@gmail.com") == "caio@gmail.com"
        # Fora do Gmail, `a.b` e `ab` são caixas diferentes, de pessoas
        # diferentes. Juntá-las negaria o teste a alguém de verdade.
        assert teste.email_canonico("c.aio@outlook.com") == "c.aio@outlook.com"

    def test_googlemail_e_o_mesmo_gmail(self):
        assert teste.email_canonico("C.Aio+X@GoogleMail.com") == "caio@gmail.com"

    def test_endereco_estranho_volta_como_veio(self):
        # O lado seguro: no pior caso, a pessoa ganha um teste que não devia.
        assert teste.email_canonico("sem-arroba") == "sem-arroba"
        assert teste.email_canonico("+x@gmail.com") == "+x@gmail.com"

    def test_email_e_telefone_nunca_colidem(self):
        assert teste.resumo("email:123") != teste.resumo("tel:123")


class TestResumoDeMaquina:
    def test_resumo_de_verdade_passa(self):
        assert teste.resumo_de_maquina_valido(MAQUINA)

    def test_qualquer_outra_coisa_vale_como_ausente(self):
        # Chega pela rede, de um programa no computador de outra pessoa.
        for ruim in [None, "", "abc", MAQUINA.upper(), MAQUINA + "0", "x" * 64]:
            assert not teste.resumo_de_maquina_valido(ruim), repr(ruim)


class TestCadastro:
    def test_conta_nova_ganha_o_teste(self):
        criar_conta(client, "primeira@example.com")
        plano, ate = _plano("primeira@example.com")
        assert plano == "pago"
        assert ate is not None

    def test_mais_sufixo_no_mesmo_email_nao_ganha_outro(self):
        """O atalho que motivou isto."""
        criar_conta(client, "caio@gmail.com")
        criar_conta(client, "caio+mais1@gmail.com")
        criar_conta(client, "c.aio@gmail.com")

        assert _plano("caio@gmail.com")[0] == "pago"
        assert _plano("caio+mais1@gmail.com") == ("gratis", None)
        assert _plano("c.aio@gmail.com") == ("gratis", None)

    def test_excluir_e_recriar_nao_devolve_o_teste(self):
        """O registro sobrevive à exclusão — senão bastaria excluir e recriar."""
        email = "volta@example.com"
        token = criar_conta(client, email)["access_token"]
        resposta = client.request(
            "DELETE",
            "/api/v1/auth/me",
            json={"password": "senhaSegura123!"},
            headers=cabecalho(token),
        )
        assert resposta.status_code in (200, 204), resposta.text

        criar_conta(client, email)
        assert _plano(email) == ("gratis", None)

    def test_outra_pessoa_no_mesmo_provedor_ganha_normalmente(self):
        criar_conta(client, "ana@gmail.com")
        criar_conta(client, "bia@gmail.com")
        assert _plano("bia@gmail.com")[0] == "pago"


class TestPareamento:
    def test_conta_em_teste_pareando_anota_a_maquina(self):
        token = criar_conta(client, "a@example.com")["access_token"]
        saida = _parear(token, "dev-a", MAQUINA)

        assert saida["teste_encerrado"] is False
        with SessionLocal() as db:
            linhas = db.scalars(
                select(TesteConcedido).where(TesteConcedido.maquina == MAQUINA)
            ).all()
            assert len(linhas) == 1

    def test_dois_testes_por_computador_passam(self):
        """Família com duas contas num PC da casa não é fraude."""
        primeira = criar_conta(client, "mae@example.com")["access_token"]
        segunda = criar_conta(client, "filho@example.com")["access_token"]

        assert _parear(primeira, "dev-mae", MAQUINA)["teste_encerrado"] is False
        assert _parear(segunda, "dev-filho", MAQUINA)["teste_encerrado"] is False
        assert _plano("filho@example.com")[0] == "pago"

    def test_o_terceiro_no_mesmo_computador_perde_o_teste(self):
        """E a resposta diz isso, para o app explicar em vez de calar."""
        for i in range(2):
            token = criar_conta(client, f"antes{i}@example.com")["access_token"]
            _parear(token, f"dev-antes-{i}", MAQUINA)

        terceira = criar_conta(client, "terceira@example.com")["access_token"]
        saida = _parear(terceira, "dev-terceira", MAQUINA)

        assert saida["teste_encerrado"] is True
        assert _plano("terceira@example.com") == ("gratis", None)
        # O computador fica na conta mesmo assim: o grátis alcança um.
        assert saida["device_id"] == "dev-terceira"

    def test_reinstalar_o_agente_no_mesmo_pc_nao_conta_duas_vezes(self):
        """`device_id` novo, mesma máquina, mesma pessoa: continua um teste só."""
        token = criar_conta(client, "reinstala@example.com")["access_token"]
        _parear(token, "dev-antes-de-reinstalar", MAQUINA)
        client.delete("/api/v1/devices/dev-antes-de-reinstalar", headers=cabecalho(token))
        _parear(token, "dev-depois-de-reinstalar", MAQUINA)

        with SessionLocal() as db:
            linhas = db.scalars(
                select(TesteConcedido).where(TesteConcedido.maquina == MAQUINA)
            ).all()
            assert len(linhas) == 1

    def test_outro_computador_nao_e_afetado(self):
        for i in range(2):
            token = criar_conta(client, f"sala{i}@example.com")["access_token"]
            _parear(token, f"dev-sala-{i}", MAQUINA)

        token = criar_conta(client, "notebook@example.com")["access_token"]
        assert _parear(token, "dev-notebook", OUTRA_MAQUINA)["teste_encerrado"] is False

    def test_quem_paga_nao_perde_nada_nem_e_anotado(self):
        """O registro é de testes, não de computadores."""
        for i in range(2):
            token = criar_conta(client, f"ocupou{i}@example.com")["access_token"]
            _parear(token, f"dev-ocupou-{i}", MAQUINA)

        email = "pagante@example.com"
        token = criar_conta(client, email)["access_token"]
        with SessionLocal() as db:
            user = db.scalar(select(User).where(User.email == email))
            user.plano, user.plano_ate = "pago", None  # cortesia sem prazo
            db.commit()

        assert _parear(token, "dev-pagante", MAQUINA)["teste_encerrado"] is False
        assert _plano(email) == ("pago", None)

    def test_agente_antigo_sem_resumo_nao_corta_ninguem(self):
        for i in range(2):
            token = criar_conta(client, f"cheio{i}@example.com")["access_token"]
            _parear(token, f"dev-cheio-{i}", MAQUINA)

        token = criar_conta(client, "velho@example.com")["access_token"]
        assert _parear(token, "dev-velho", None)["teste_encerrado"] is False
        assert _plano("velho@example.com")[0] == "pago"

    def test_resumo_malformado_vale_como_ausente(self):
        for i in range(2):
            token = criar_conta(client, f"lotado{i}@example.com")["access_token"]
            _parear(token, f"dev-lotado-{i}", MAQUINA)

        token = criar_conta(client, "adulterado@example.com")["access_token"]
        saida = _parear(token, "dev-adulterado", "nao-e-um-resumo")
        assert saida["teste_encerrado"] is False


class TestPontaAPonta:
    def test_o_resumo_atravessa_do_hello_ao_pareamento(self):
        """O agente manda no `Hello`, e ele chega ao computador pareado."""
        from app.models import Device

        token = criar_conta(client, "ponta@example.com")["access_token"]
        hello = {
            "type": "hello",
            "device_id": "dev-ponta",
            "hostname": "PC",
            "os": "windows",
            "agent_version": "0.1.0",
            "maquina": MAQUINA,
        }
        with client.websocket_connect("/ws/agent") as ws:
            ws.send_json(hello)
            ws.receive_json()  # welcome
            codigo = ws.receive_json()["code"]
            resposta = client.post(
                "/api/v1/pairing/claim", json={"code": codigo}, headers=cabecalho(token)
            )
            assert resposta.status_code == 201, resposta.text

        with SessionLocal() as db:
            device = db.scalar(select(Device).where(Device.device_id == "dev-ponta"))
            assert device.maquina == MAQUINA

    def test_hello_de_agente_antigo_continua_aceito(self):
        with client.websocket_connect("/ws/agent") as ws:
            ws.send_json(
                {
                    "type": "hello",
                    "device_id": "dev-antigo",
                    "hostname": "PC",
                    "os": "windows",
                    "agent_version": "0.0.9",
                }
            )
            assert ws.receive_json()["type"] == "welcome"


class TestMigracao:
    def test_contas_que_ja_existiam_contam_como_ja_tendo_tido_teste(self):
        """Senão quem já conhece o produto ganharia outro com `+sufixo`."""
        from app.db import _registrar_testes_ja_dados

        # Uma conta criada "antes" do registro existir.
        criar_conta(client, "antiga@gmail.com")
        with SessionLocal() as db:
            db.query(TesteConcedido).delete()
            db.commit()

        _registrar_testes_ja_dados()
        _registrar_testes_ja_dados()  # idempotente: rodar de novo não duplica

        with SessionLocal() as db:
            assert db.query(TesteConcedido).count() == 1

        criar_conta(client, "antiga+nova@gmail.com")
        assert _plano("antiga+nova@gmail.com") == ("gratis", None)


def test_o_teste_concedido_vale_trinta_dias():
    criar_conta(client, "trinta@example.com")
    _, ate = _plano("trinta@example.com")
    ate = ate if ate.tzinfo else ate.replace(tzinfo=UTC)
    assert timedelta(days=29) < ate - datetime.now(UTC) <= timedelta(days=30)
