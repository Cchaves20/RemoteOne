"""Trocar o e-mail ou o telefone da conta — agora com código de verificação.

Antes a troca era imediata: bastava a senha atual, e o contato novo entrava na
conta na mesma requisição. Isso abria **dois** buracos de uma vez, e o segundo é
o menos óbvio:

1. Apontar a conta para um endereço que não é seu — e perder a conta, porque é
   por ele que se entra e é para ele que vai a recuperação de senha.
2. **Ocupar aquele contato.** A coluna é única: com o endereço de outra pessoa
   preso a esta conta, o dono real não conseguiria mais se cadastrar. Sem nunca
   ter provado nada.

É exatamente o buraco que o cadastro em duas etapas fechou do outro lado, e ele
seguia aberto por aqui. Agora o contato novo só entra depois de provado, e a
pendência **não** reserva nada enquanto isso — o que tem teste próprio, porque é
a parte que seria fácil errar tentando consertar a primeira.
"""

from datetime import UTC, datetime, timedelta

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import verificacao
from app.db import SessionLocal
from app.main import app
from app.models import PendingContactChange, User

client = TestClient(app)


def _entrar(email: str | None = None, phone: str | None = None) -> dict:
    tokens = criar_conta(client, email=email, phone=phone, country="BR" if phone else None)
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _comecar(headers: dict, **contato) -> "object":
    return client.post(
        "/api/v1/auth/me/contact/start",
        json={"current_password": SENHA, **contato},
        headers=headers,
    )


def _confirmar(headers: dict, codigo: str) -> "object":
    return client.post(
        "/api/v1/auth/me/contact/verify", json={"code": codigo}, headers=headers
    )


def _conta(headers: dict) -> dict:
    return client.get("/api/v1/auth/me", headers=headers).json()


def _login(**corpo) -> int:
    return client.post(
        "/api/v1/auth/login", json={"password": SENHA, **corpo}
    ).status_code


# --- o caminho feliz ---------------------------------------------------------


def test_fluxo_completo_de_email(espiao):
    headers = _entrar(email="antigo@example.com")

    inicio = _comecar(headers, email="novo@example.com")
    assert inicio.status_code == 200, inicio.text
    assert inicio.json()["destination"] == "novo@example.com"
    assert inicio.json()["channel"] == "email"

    fim = _confirmar(headers, espiao.ultimo_codigo("novo@example.com"))
    assert fim.status_code == 200, fim.text
    assert fim.json()["email"] == "novo@example.com"

    assert _login(email="novo@example.com") == 200
    assert _login(email="antigo@example.com") == 401


def test_o_codigo_vai_para_o_endereco_novo(espiao):
    """Óbvio e essencial: mandar para o endereço **antigo** provaria que a pessoa
    tem o contato que ela já tinha, que é justamente o que não está em questão."""
    headers = _entrar(email="dono@example.com")
    _comecar(headers, email="destino@example.com")

    canal, alvo, _ = espiao.enviados[-1]
    assert (canal, alvo) == ("email", "destino@example.com")


def test_telefone_normaliza_e_muda_o_login(espiao):
    """Sem normalizar, a pessoa trocaria o número e ficaria fora da conta.

    Gravar "(11) 98765-4321" como veio produziria uma forma que o login — que
    normaliza — nunca encontraria. A conta continuaria lá, inacessível, e nada
    na tela explicaria por quê.
    """
    headers = _entrar(phone="11911112222")

    inicio = _comecar(headers, phone="(11) 98765-4321", country="BR")
    assert inicio.status_code == 200, inicio.text
    assert inicio.json()["destination"] == "+5511987654321"

    fim = _confirmar(headers, espiao.ultimo_codigo("+5511987654321"))
    assert fim.status_code == 200
    assert fim.json()["phone"] == "+5511987654321"

    # Entra com o novo, escrito de qualquer jeito; não entra com o antigo.
    assert _login(phone="11 98765 4321", country="BR") == 200
    assert _login(phone="11911112222", country="BR") == 401


def test_trocar_de_email_para_telefone_limpa_o_email(espiao):
    """A conta se identifica por **um** contato, e é por ele que se entra.
    Deixar os dois preenchidos daria duas formas de login para uma conta que só
    provou uma delas."""
    headers = _entrar(email="vira@example.com")

    _comecar(headers, phone="11955556666", country="BR")
    fim = _confirmar(headers, espiao.ultimo_codigo("+5511955556666"))
    assert fim.status_code == 200
    assert fim.json()["phone"] == "+5511955556666"
    assert fim.json()["email"] is None
    assert _login(email="vira@example.com") == 401


# --- o que não pode acontecer antes do código --------------------------------


def test_nada_muda_enquanto_o_codigo_nao_for_conferido(espiao):
    headers = _entrar(email="firme@example.com")
    _comecar(headers, email="ainda-nao@example.com")

    assert _conta(headers)["email"] == "firme@example.com"
    assert _login(email="firme@example.com") == 200
    assert _login(email="ainda-nao@example.com") == 401


def test_a_troca_pendente_nao_reserva_o_contato(espiao):
    """O buraco menos óbvio, e o que seria fácil reintroduzir.

    A tentação, ao adiar a troca, é guardar a pendência com o destino **único** —
    "para ninguém pegar antes". Isso recriaria o problema num degrau acima:
    bastaria começar uma troca para o e-mail de outra pessoa para impedir que ela
    se cadastrasse, sem nunca provar nada. Uma pendência não prova posse, e por
    isso não reserva coisa nenhuma.
    """
    headers = _entrar(email="alguem@example.com")
    _comecar(headers, email="disputado@example.com")

    # O dono de verdade se cadastra normalmente.
    criar_conta(client, email="disputado@example.com")
    assert _login(email="disputado@example.com") == 200


def test_quem_confirma_depois_perde_para_quem_chegou_primeiro(espiao):
    """A corrida que a conferência no `verify` cobre.

    Duas trocas pendentes para o mesmo destino são legítimas — nenhuma provou
    nada ainda. Quem confirma primeiro fica com ele; a segunda tem de receber um
    409 explicando, e não um 500 vindo da restrição de unicidade do banco.
    """
    primeira = _entrar(email="corredor1@example.com")
    segunda = _entrar(email="corredor2@example.com")

    _comecar(primeira, email="premio@example.com")
    codigo_um = espiao.ultimo_codigo("premio@example.com")
    _comecar(segunda, email="premio@example.com")
    codigo_dois = espiao.ultimo_codigo("premio@example.com")

    assert _confirmar(primeira, codigo_um).status_code == 200
    perdedora = _confirmar(segunda, codigo_dois)
    assert perdedora.status_code == 409
    assert _conta(segunda)["email"] == "corredor2@example.com"


# --- recusas no início -------------------------------------------------------


def test_senha_errada_nao_manda_nada(espiao):
    headers = _entrar(email="cauteloso@example.com")
    resp = client.post(
        "/api/v1/auth/me/contact/start",
        json={"current_password": "outra1!Senha", "email": "nao@example.com"},
        headers=headers,
    )
    assert resp.status_code == 401
    assert not any(alvo == "nao@example.com" for _, alvo, _ in espiao.enviados)


def test_contato_ja_cadastrado(espiao):
    criar_conta(client, email="ocupado@example.com")
    headers = _entrar(email="outro@example.com")
    assert _comecar(headers, email="ocupado@example.com").status_code == 409


def test_trocar_para_o_proprio_contato(espiao):
    """Recusa cedo em vez de mandar um código para o endereço que a pessoa já
    tem: o fluxo inteiro terminaria sem mudar nada, o que parece defeito."""
    headers = _entrar(email="mesmo@example.com")
    resp = _comecar(headers, email="mesmo@example.com")
    assert resp.status_code == 400
    assert "já é o contato" in resp.json()["detail"]


def test_telefone_impossivel(espiao):
    headers = _entrar(phone="11922223333")
    resp = _comecar(headers, phone="1199", country="BR")
    assert resp.status_code == 400
    assert "Brasil" in resp.json()["detail"]


def test_exige_estar_autenticado():
    resp = client.post(
        "/api/v1/auth/me/contact/start",
        json={"current_password": SENHA, "email": "x@example.com"},
    )
    assert resp.status_code == 401  # sem Bearer, barra antes de olhar o corpo


# --- o código: prazo, tentativas, reenvio ------------------------------------


def test_codigo_errado_gasta_tentativa_e_diz_quantas_faltam(espiao):
    headers = _entrar(email="erra@example.com")
    _comecar(headers, email="alvo@example.com")

    resp = _confirmar(headers, "000000")
    assert resp.status_code == 401
    assert "4 tentativas restantes" in resp.json()["detail"]

    # O certo ainda vale depois do erro.
    assert _confirmar(headers, espiao.ultimo_codigo("alvo@example.com")).status_code == 200


def test_tentativas_demais_descartam_a_troca(espiao):
    """Seis dígitos com tentativas infinitas se adivinham em minutos. Descartar a
    pendência inteira — e não só recusar o código — evita que recomeçar com um
    código novo devolva as tentativas de graça."""
    headers = _entrar(email="teimoso@example.com")
    _comecar(headers, email="cofre@example.com")

    for _ in range(verificacao.MAX_TENTATIVAS - 1):
        assert _confirmar(headers, "000000").status_code == 401
    assert _confirmar(headers, "000000").status_code == 429

    # E o código certo não serve mais para nada.
    assert _confirmar(headers, espiao.ultimo_codigo("cofre@example.com")).status_code == 404
    assert _conta(headers)["email"] == "teimoso@example.com"


def test_codigo_expirado(espiao):
    headers = _entrar(email="tarde@example.com")
    _comecar(headers, email="atrasado@example.com")
    with SessionLocal() as db:
        pendente = db.scalar(select(PendingContactChange))
        pendente.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        db.commit()

    assert _confirmar(headers, espiao.ultimo_codigo("atrasado@example.com")).status_code == 410
    with SessionLocal() as db:
        assert db.scalar(select(PendingContactChange)) is None


def test_reenviar_espera_e_troca_o_codigo(espiao):
    headers = _entrar(email="repete@example.com")
    _comecar(headers, email="denovo@example.com")
    primeiro = espiao.ultimo_codigo("denovo@example.com")

    cedo = client.post("/api/v1/auth/me/contact/resend", headers=headers)
    assert cedo.status_code == 429

    with SessionLocal() as db:
        pendente = db.scalar(select(PendingContactChange))
        pendente.last_sent_at = datetime.now(UTC) - verificacao.ESPERA_REENVIO
        db.commit()

    assert client.post("/api/v1/auth/me/contact/resend", headers=headers).status_code == 200
    segundo = espiao.ultimo_codigo("denovo@example.com")
    assert segundo != primeiro

    # O antigo morreu; o novo vale.
    assert _confirmar(headers, primeiro).status_code == 401
    assert _confirmar(headers, segundo).status_code == 200


def test_corrigir_o_destino_nao_espera_um_minuto(espiao):
    """Recomeçar com **outro** destino é o caso de ter digitado errado. Fazer
    esperar um minuto para corrigir um erro de digitação seria castigo sem ganho:
    a espera existe contra apertar "enviar" de novo para o mesmo lugar."""
    headers = _entrar(email="dedoduro@example.com")
    assert _comecar(headers, email="erradoo@example.com").status_code == 200
    assert _comecar(headers, email="certo@example.com").status_code == 200

    # E só a última vale: a anterior foi substituída.
    assert _confirmar(headers, espiao.ultimo_codigo("erradoo@example.com")).status_code == 401
    assert _confirmar(headers, espiao.ultimo_codigo("certo@example.com")).status_code == 200


# --- portas fechadas ---------------------------------------------------------


def test_nao_existe_atalho_para_trocar_sem_verificar():
    """Os `PATCH /me/email` e `/me/phone` saíram, e isso é o recurso — não um
    resto. Enquanto existissem, o código de seis dígitos seria decoração:
    bastaria chamar a rota velha para apontar a conta a um endereço qualquer.

    404 e não 405: as rotas foram **removidas**, não trocadas de método. Um 405
    diria que o caminho ainda existe para outro verbo, e é essa a diferença que
    o teste registra.
    """
    headers = _entrar(email="atalho@example.com")
    for rota, corpo in (
        ("/api/v1/auth/me/email", {"current_password": SENHA, "new_email": "x@y.com"}),
        (
            "/api/v1/auth/me/phone",
            {"current_password": SENHA, "new_phone": "11999998888", "country": "BR"},
        ),
    ):
        assert client.patch(rota, json=corpo, headers=headers).status_code == 404, rota


def test_excluir_a_conta_leva_a_troca_pendente_junto(espiao):
    """A cascata que faltaria.

    O SQLite reaproveita o id: sem a declaração no `User`, a pendência da conta
    apagada continuaria no banco com `user_id = 1` e viraria uma troca de contato
    **em andamento** na conta seguinte — que poderia confirmá-la com um código
    que nunca recebeu.
    """
    headers = _entrar(email="efemero@example.com")
    _comecar(headers, email="fantasma@example.com")

    assert client.request(
        "DELETE", "/api/v1/auth/me", json={"password": SENHA}, headers=headers
    ).status_code == 204

    with SessionLocal() as db:
        assert db.scalar(select(PendingContactChange)) is None

    # E a conta seguinte, que herda o id, não tem troca nenhuma em andamento.
    novos = _entrar(email="herdeiro@example.com")
    with SessionLocal() as db:
        assert list(db.scalars(select(User.id))) == [1]
    assert client.post("/api/v1/auth/me/contact/resend", headers=novos).status_code == 404
