"""Criação de conta: formulário, código de verificação e as duas etapas.

O que esta suíte protege não é "o endpoint responde 201". É um conjunto de
coisas que, se quebrarem, quebram **em silêncio** — e num lugar caro, porque
cada tentativa de cadastro por telefone custa um SMS:

- que a conta **não nasça** antes de o código ser conferido;
- que o mesmo telefone digitado de três jeitos vire uma conta só;
- que o código expire, tenha limite de tentativas e não possa ser pedido em
  sequência;
- que a validação toda aconteça **antes** do envio.
"""

from datetime import UTC, datetime, timedelta

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import telefone, verificacao
from app.db import SessionLocal
from app.main import app
from app.models import PendingSignup, User

client = TestClient(app)


def formulario(**mudancas) -> dict:
    base = {
        "first_name": "Caio",
        "last_name": "Chaves",
        "birth_date": "1998-04-20",
        "email": "novo@example.com",
        "password": SENHA,
        "password_confirm": SENHA,
    }
    base.update(mudancas)
    return {k: v for k, v in base.items() if v is not None}


def comecar(**mudancas):
    return client.post("/api/v1/auth/signup/start", json=formulario(**mudancas))


# --- a conta só nasce depois do código ---------------------------------------


def test_a_conta_nao_existe_antes_da_verificacao(espiao):
    """O ponto inteiro do fluxo de duas etapas.

    Se a conta nascesse aqui, o código seria enfeite — e, pior, bastaria digitar
    o e-mail de outra pessoa para **ocupar** o endereço dela e impedir que ela
    se cadastrasse, sem nunca provar que o endereço é seu.
    """
    resp = comecar(email="ninguem@example.com")
    assert resp.status_code == 201

    with SessionLocal() as db:
        assert db.scalar(select(User).where(User.email == "ninguem@example.com")) is None
        assert db.scalar(select(PendingSignup)) is not None

    # E o login também não existe ainda.
    assert client.post(
        "/api/v1/auth/login", json={"email": "ninguem@example.com", "password": SENHA}
    ).status_code == 401

    # Com o código, existe.
    codigo = espiao.ultimo_codigo("ninguem@example.com")
    fim = client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "ninguem@example.com", "code": codigo},
    )
    assert fim.status_code == 201
    assert fim.json()["access_token"]
    with SessionLocal() as db:
        # E o pendente sai: deixá-lo permitiria usar o mesmo código de novo.
        assert db.scalar(select(PendingSignup)) is None


def test_os_dados_do_formulario_chegam_na_conta(espiao):
    criar_conta(client, email="dados@example.com", first_name="Ana", last_name="Souza")
    with SessionLocal() as db:
        u = db.scalar(select(User).where(User.email == "dados@example.com"))
    assert u.first_name == "Ana"
    assert u.last_name == "Souza"
    assert u.birth_date.isoformat() == "1998-04-20"
    assert u.phone is None


def test_conta_por_telefone_guarda_e164(espiao):
    criar_conta(client, phone="(11) 98765-4321", country="BR")
    with SessionLocal() as db:
        u = db.scalar(select(User).where(User.phone == "+5511987654321"))
    assert u is not None
    # Sem e-mail, e é legítimo: um dos dois identifica a conta.
    assert u.email is None


# --- validação, antes de gastar o envio --------------------------------------


def test_senha_precisa_das_cinco_regras(espiao):
    """E o erro diz **o que falta**, não "senha inválida".

    Um formulário que revela uma exigência por vez faz a pessoa tentar cinco
    vezes para descobrir cinco regras.
    """
    ruins = {
        "semmaiuscula1!": "maiúscula",
        "SEMMINUSCULA1!": "minúscula",
        "SemNumero!!": "número",
        "SemEspecial123": "especial",
        "Ab1!": "8 caracteres",
    }
    for ruim, esperado in ruins.items():
        resp = comecar(password=ruim, password_confirm=ruim)
        assert resp.status_code == 400, ruim
        assert esperado in resp.json()["detail"], ruim
    # E nada foi enviado: validar antes é o que evita gastar SMS à toa.
    assert espiao.enviados == []


def test_confirmacao_de_senha_precisa_bater(espiao):
    resp = comecar(password_confirm="OutraCoisa1!")
    assert resp.status_code == 422
    assert espiao.enviados == []


def test_idade_minima_e_datas_impossiveis(espiao):
    hoje = datetime.now(UTC).date()
    futuro = (hoje + timedelta(days=1)).isoformat()
    crianca = (hoje - timedelta(days=365 * 8)).isoformat()
    matusalem = (hoje - timedelta(days=365 * 130)).isoformat()

    assert comecar(birth_date=futuro).status_code == 400
    assert comecar(birth_date=crianca).status_code == 400
    assert comecar(birth_date=matusalem).status_code == 400
    assert espiao.enviados == []


def test_aniversario_hoje_nao_tira_um_ano(espiao):
    """A conta de idade com (mês, dia), e não dividindo dias por 365.

    Quem completa a idade mínima hoje entra; quem completa amanhã, não. É o par
    de casos onde um cálculo por aproximação erra.
    """
    hoje = datetime.now(UTC).date()
    faz_hoje = hoje.replace(year=hoje.year - 13)
    faz_amanha = (hoje + timedelta(days=1)).replace(year=hoje.year - 13)
    assert comecar(email="a@example.com", birth_date=faz_hoje.isoformat()).status_code == 201
    assert comecar(email="b@example.com", birth_date=faz_amanha.isoformat()).status_code == 400


def test_telefone_invalido_para_o_pais(espiao):
    curto = comecar(email=None, phone="1198765", country="BR")
    assert curto.status_code == 400
    assert "Brasil" in curto.json()["detail"]
    assert comecar(email=None, phone="11987654321", country="XX").status_code == 400
    assert espiao.enviados == []


def test_precisa_de_email_ou_telefone_e_so_um(espiao):
    assert comecar(email=None).status_code == 422
    assert comecar(phone="11987654321", country="BR").status_code == 422
    # Telefone sem país.
    assert comecar(email=None, phone="11987654321").status_code == 422


def test_email_ou_telefone_ja_cadastrado(espiao):
    criar_conta(client, email="ocupado@example.com")
    assert comecar(email="ocupado@example.com").status_code == 409
    # E o mesmo endereço em outra caixa: normalizado, é o mesmo.
    assert comecar(email="Ocupado@Example.com").status_code == 409

    criar_conta(client, phone="11911112222", country="BR")
    assert comecar(email=None, phone="(11) 91111-2222", country="BR").status_code == 409


# --- o código -----------------------------------------------------------------


def test_codigo_errado_conta_tentativa_e_depois_desiste(espiao):
    comecar(email="tenta@example.com")
    for restantes in range(verificacao.MAX_TENTATIVAS - 1, 0, -1):
        resp = client.post(
            "/api/v1/auth/signup/verify",
            json={"destination": "tenta@example.com", "code": "000000"},
        )
        assert resp.status_code == 401
        assert str(restantes) in resp.json()["detail"]

    # A última derruba o cadastro inteiro. Manter o pendente com um código novo
    # devolveria as tentativas de graça, e seis dígitos se adivinham.
    ultima = client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "tenta@example.com", "code": "000000"},
    )
    assert ultima.status_code == 429
    with SessionLocal() as db:
        assert db.scalar(select(PendingSignup)) is None


def test_codigo_certo_depois_de_um_erro_ainda_vale(espiao):
    """Errar de dedo não pode custar o cadastro."""
    comecar(email="dedo@example.com")
    client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "dedo@example.com", "code": "000000"},
    )
    codigo = espiao.ultimo_codigo("dedo@example.com")
    assert client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "dedo@example.com", "code": codigo},
    ).status_code == 201


def test_codigo_expirado(espiao):
    comecar(email="tarde@example.com")
    with SessionLocal() as db:
        pendente = db.scalar(select(PendingSignup))
        pendente.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        db.commit()

    codigo = espiao.ultimo_codigo("tarde@example.com")
    resp = client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "tarde@example.com", "code": codigo},
    )
    assert resp.status_code == 410
    with SessionLocal() as db:
        assert db.scalar(select(PendingSignup)) is None


def test_reenviar_espera_e_troca_o_codigo(espiao):
    comecar(email="dinovo@example.com")
    primeiro = espiao.ultimo_codigo("dinovo@example.com")

    # Logo em seguida, não: cada SMS custa dinheiro, e o botão de reenviar é
    # exatamente o que se aperta repetidamente quando a mensagem demora.
    cedo = client.post(
        "/api/v1/auth/signup/resend", json={"destination": "dinovo@example.com"}
    )
    assert cedo.status_code == 429

    with SessionLocal() as db:
        pendente = db.scalar(select(PendingSignup))
        pendente.last_sent_at = datetime.now(UTC) - verificacao.ESPERA_REENVIO
        db.commit()

    de_novo = client.post(
        "/api/v1/auth/signup/resend", json={"destination": "dinovo@example.com"}
    )
    assert de_novo.status_code == 200
    segundo = espiao.ultimo_codigo("dinovo@example.com")
    assert segundo != primeiro

    # O antigo morreu; o novo vale.
    assert client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "dinovo@example.com", "code": primeiro},
    ).status_code == 401
    assert client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "dinovo@example.com", "code": segundo},
    ).status_code == 201


def test_recomecar_substitui_o_pendente(espiao):
    """Dois códigos válidos para o mesmo destino confundiriam quem esperava o
    primeiro."""
    comecar(email="denovo@example.com")
    velho = espiao.ultimo_codigo("denovo@example.com")
    comecar(email="denovo@example.com", first_name="Outro")
    novo = espiao.ultimo_codigo("denovo@example.com")

    with SessionLocal() as db:
        assert len(db.scalars(select(PendingSignup)).all()) == 1

    assert client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "denovo@example.com", "code": velho},
    ).status_code == 401
    assert client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "denovo@example.com", "code": novo},
    ).status_code == 201
    with SessionLocal() as db:
        assert (
            db.scalar(select(User).where(User.email == "denovo@example.com")).first_name
            == "Outro"
        )


def test_verificar_destino_que_nao_esta_em_andamento(espiao):
    resp = client.post(
        "/api/v1/auth/signup/verify",
        json={"destination": "fantasma@example.com", "code": "123456"},
    )
    assert resp.status_code == 404


def test_o_codigo_tem_seis_digitos_e_aceita_zeros_a_esquerda():
    """Cortar o zero à esquerda daria códigos de tamanho variável, e a tela que
    espera seis dígitos recusaria o próprio código que o servidor mandou."""
    for _ in range(200):
        codigo = verificacao.gerar()
        assert len(codigo) == 6 and codigo.isdigit()


# --- países e telefone --------------------------------------------------------


def test_lista_de_paises_tem_bandeira_e_ddi():
    resp = client.get("/api/v1/auth/countries")
    assert resp.status_code == 200
    paises = resp.json()
    assert paises[0]["iso"] == "BR"
    assert paises[0]["dial_code"] == "55"
    assert paises[0]["flag"] == "🇧🇷"


def test_normalizacao_de_telefone():
    # Espaço, parêntese e hífen são enfeite de leitura.
    for escrito in ("11987654321", "(11) 98765-4321", "11 98765 4321", " 11987654321 "):
        assert telefone.normalizar(escrito, "BR") == "+5511987654321"
    # O zero de tronco (o `0` que se disca antes do DDD dentro do Brasil).
    assert telefone.normalizar("011987654321", "BR") == "+5511987654321"
    # O DDI digitado junto não vira +55 55.
    assert telefone.normalizar("+55 11 98765-4321", "BR") == "+5511987654321"
    # Mas um DDD que começa com 55 continua intacto: 55 é o DDD de Santa Maria.
    assert telefone.normalizar("55987654321", "BR") == "+5555987654321"
    # Tamanhos impossíveis.
    assert telefone.normalizar("1198765", "BR") is None
    assert telefone.normalizar("119876543210000", "BR") is None
    assert telefone.normalizar("", "BR") is None
    assert telefone.normalizar("11987654321", "ZZ") is None


def test_todo_pais_da_tabela_tem_intervalo_coerente():
    """Um intervalo invertido recusaria todo número daquele país — e só se
    descobriria quando alguém de lá tentasse se cadastrar."""
    for p in telefone.PAISES:
        assert 4 <= p.minimo <= p.maximo <= 15, p.iso
        assert p.ddi.isdigit(), p.iso
        assert len(p.iso) == 2 and p.iso.isupper(), p.iso
        assert len(p.bandeira) == 2, p.iso


# --- o servidor diz em que modo está ------------------------------------------


def test_health_conta_se_a_entrega_esta_configurada():
    """Sem isto, "o código não chegou" começaria por dedução."""
    corpo = client.get("/health").json()
    assert "delivery" in corpo
    assert set(corpo["delivery"]) == {"email", "sms"}
    assert "signup-verification" in corpo["features"]
