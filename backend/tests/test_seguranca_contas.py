"""A verificação em duas etapas em toda porta da conta, e os avisos ao dono.

O que esta suíte guarda (ver `app/segundo_fator.py` e `app/alertas.py`):

- a recuperação de senha, que antes pulava a verificação, agora a cobra;
- os códigos de recuperação: valem uma vez só, e qualquer porta os aceita;
- o código do autenticador não vale duas vezes;
- desligar a verificação, trocar senha, trocar contato e excluir a conta pedem
  o código;
- cada passo de quem tomaria a conta gera um aviso — e a troca de contato
  avisa o endereço **antigo**.
"""

from datetime import UTC, datetime, timedelta

import pyotp
import pytest
from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient

from app import alertas, auth, entrega, segundo_fator
from app.db import SessionLocal
from app.main import app
from app.models import PairingRequest

client = TestClient(app)

EMAIL = "cofre@example.com"
NOVA = "OutraSenha456!"


class Relogio:
    """O relógio do segundo fator, que o teste avança de passo em passo.

    Cada código do autenticador vale uma vez só; sem controlar o tempo, dois
    usos no mesmo teste dependeriam de esperar 30 segundos de verdade.
    """

    def __init__(self) -> None:
        self.agora = datetime.now(UTC)

    def now(self, tz=None) -> datetime:
        return self.agora

    def codigo(self, segredo: str) -> str:
        """O código do passo seguinte, já avançando o relógio até ele."""
        self.agora += timedelta(seconds=30)
        return pyotp.TOTP(segredo).at(self.agora)


@pytest.fixture
def relogio(monkeypatch) -> Relogio:
    falso = Relogio()
    monkeypatch.setattr(segundo_fator, "datetime", falso)
    return falso


def _entrar(email: str = EMAIL) -> dict:
    tokens = criar_conta(client, email=email)
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _ligar(headers: dict, relogio: Relogio) -> tuple[str, list[str]]:
    """Liga a verificação como o app novo: pedindo os códigos de recuperação."""
    segredo = client.post("/api/v1/auth/2fa/setup", headers=headers).json()["secret"]
    resp = client.post(
        "/api/v1/auth/2fa/enable",
        json={"code": relogio.codigo(segredo), "recovery_codes": True},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return segredo, resp.json()["codes"]


def _login(codigo: str | None = None, senha: str = SENHA):
    corpo = {"email": EMAIL, "password": senha}
    if codigo is not None:
        corpo["totp_code"] = codigo
    return client.post("/api/v1/auth/login", json=corpo)


def _redefinir(espiao, codigo_2fa: str | None = None, pedir: bool = True):
    """Recupera a senha; `pedir=False` reaproveita o código do e-mail já enviado
    (pedir de novo antes de um minuto é recusado)."""
    if pedir:
        resp = client.post("/api/v1/auth/password/forgot", json={"email": EMAIL})
        assert resp.status_code == 200
    corpo = {
        "destination": EMAIL,
        "code": espiao.ultimo_codigo(EMAIL),
        "password": NOVA,
        "password_confirm": NOVA,
    }
    if codigo_2fa is not None:
        corpo["totp_code"] = codigo_2fa
    return client.post("/api/v1/auth/password/reset", json=corpo)


def _assuntos(espiao) -> list[str]:
    return [assunto for _, assunto, _ in espiao.avisos]


# --- recuperar a senha ---------------------------------------------------------


def test_recuperar_a_senha_cobra_o_segundo_fator(espiao, relogio):
    """O buraco que motivou o pacote: com o e-mail (ou o chip) da pessoa,
    redefinia-se a senha e entrava-se, com a verificação ligada ou não."""
    headers = _entrar()
    segredo, _ = _ligar(headers, relogio)

    sem = _redefinir(espiao)
    assert sem.status_code == 401
    assert sem.json()["detail"] == "two_factor_required"

    # O pedido continua de pé enquanto o código não vem.
    errado = _redefinir(espiao, "000000", pedir=False)
    assert errado.status_code == 401
    assert errado.json()["detail"] == "two_factor_invalid"

    # A senha não mudou em nenhuma das duas.
    assert _login(relogio.codigo(segredo)).status_code == 200

    certo = _redefinir(espiao, relogio.codigo(segredo), pedir=False)
    assert certo.status_code == 200
    assert certo.json()["access_token"]
    assert "A senha da sua conta Deskside mudou" in _assuntos(espiao)


def test_codigo_errado_na_recuperacao_gasta_as_tentativas(espiao, relogio):
    """Seis dígitos sem limite se adivinham: os erros contam nas mesmas
    tentativas do código do e-mail, e no fim o pedido cai."""
    _ligar(_entrar(), relogio)
    assert client.post("/api/v1/auth/password/forgot", json={"email": EMAIL}).status_code == 200
    corpo = {
        "destination": EMAIL,
        "code": espiao.ultimo_codigo(EMAIL),
        "password": NOVA,
        "password_confirm": NOVA,
        "totp_code": "000000",
    }
    respostas = [
        client.post("/api/v1/auth/password/reset", json=corpo).status_code for _ in range(5)
    ]
    assert respostas[-1] == 429
    assert set(respostas[:-1]) == {401}
    # O pedido caiu: nem o código certo do e-mail serve mais.
    assert client.post("/api/v1/auth/password/reset", json=corpo).status_code == 404


def test_recuperar_com_codigo_de_recuperacao(espiao, relogio):
    """Quem perdeu o celular do autenticador ainda recupera a conta — é para
    isso que os códigos existem."""
    _, codigos = _ligar(_entrar(), relogio)

    assert _redefinir(espiao, codigos[0]).status_code == 200
    assert "Um código de recuperação foi usado" in _assuntos(espiao)


# --- códigos de recuperação ------------------------------------------------------


def test_ligar_devolve_dez_codigos_e_o_me_conta(relogio):
    headers = _entrar()
    _, codigos = _ligar(headers, relogio)

    assert len(codigos) == 10
    assert len(set(codigos)) == 10
    for codigo in codigos:
        assert len(codigo) == 11 and codigo[5] == "-"
        assert not set(codigo) & set("01ILO")
    assert client.get("/api/v1/auth/me", headers=headers).json()["recovery_codes_left"] == 10


def test_codigo_de_recuperacao_entra_uma_vez_so(espiao, relogio):
    headers = _entrar()
    _, codigos = _ligar(headers, relogio)

    # Minúsculas e sem traço: é como se digita copiando de um papel.
    digitado = codigos[3].lower().replace("-", " ")
    assert _login(digitado).status_code == 200
    segunda = _login(codigos[3])
    assert segunda.status_code == 401
    assert segunda.json()["detail"] == "two_factor_invalid"

    assert client.get("/api/v1/auth/me", headers=headers).json()["recovery_codes_left"] == 9
    aviso = next(c for _, a, c in espiao.avisos if a == "Um código de recuperação foi usado")
    assert "Restam 9 códigos." in aviso


def test_codigos_novos_anulam_os_antigos(espiao, relogio):
    headers = _entrar()
    segredo, antigos = _ligar(headers, relogio)

    resp = client.post(
        "/api/v1/auth/2fa/recovery-codes",
        json={"totp_code": relogio.codigo(segredo)},
        headers=headers,
    )
    assert resp.status_code == 200
    novos = resp.json()["codes"]
    assert not set(novos) & set(antigos)

    assert _login(antigos[0]).status_code == 401
    assert _login(novos[0]).status_code == 200
    assert "Novos códigos de recuperação" in _assuntos(espiao)


def test_codigos_novos_pedem_o_segundo_fator(relogio):
    headers = _entrar()
    _ligar(headers, relogio)
    resp = client.post(
        "/api/v1/auth/2fa/recovery-codes", json={"totp_code": "000000"}, headers=headers
    )
    assert resp.status_code == 401


def test_o_app_antigo_continua_ligando_sem_codigos(relogio):
    """O app que já está nos celulares confere o 204; quebrá-lo seria quebrar a
    ativação para quem ainda não atualizou."""
    headers = _entrar()
    segredo = client.post("/api/v1/auth/2fa/setup", headers=headers).json()["secret"]
    resp = client.post(
        "/api/v1/auth/2fa/enable", json={"code": relogio.codigo(segredo)}, headers=headers
    )
    assert resp.status_code == 204
    assert client.get("/api/v1/auth/me", headers=headers).json()["recovery_codes_left"] == 0


# --- o código do autenticador não vale duas vezes -------------------------------


def test_o_mesmo_codigo_nao_entra_duas_vezes(relogio):
    """Quem visse o código na tela de outra pessoa entraria com ele logo depois."""
    segredo, _ = _ligar(_entrar(), relogio)
    codigo = relogio.codigo(segredo)

    assert _login(codigo).status_code == 200
    de_novo = _login(codigo)
    assert de_novo.status_code == 401
    assert de_novo.json()["detail"] == "two_factor_invalid"

    # O do passo seguinte entra.
    assert _login(relogio.codigo(segredo)).status_code == 200


def test_codigo_anterior_ao_usado_tambem_nao_entra(relogio):
    """A janela aceita o passo anterior (relógio atrasado), mas não um anterior
    a um já usado."""
    segredo, _ = _ligar(_entrar(), relogio)
    anterior = pyotp.TOTP(segredo).at(relogio.agora)  # o da ativação
    relogio.agora += timedelta(seconds=30)
    assert _login(anterior).status_code == 401


def test_confere_recusa_formatos_estranhos(relogio):
    segredo, _ = _ligar(_entrar(), relogio)
    for lixo in ("", "12345", "1234567", "abcdef", "ABCDE-FGHJ"):
        assert _login(lixo).status_code == 401


# --- ações sensíveis pedem o código ---------------------------------------------


def test_desligar_pede_o_codigo(espiao, relogio):
    headers = _entrar()
    segredo, _ = _ligar(headers, relogio)

    sem = client.post("/api/v1/auth/2fa/disable", json={"password": SENHA}, headers=headers)
    assert sem.status_code == 401
    assert sem.json()["detail"] == "two_factor_required"

    resp = client.post(
        "/api/v1/auth/2fa/disable",
        json={"password": SENHA, "totp_code": relogio.codigo(segredo)},
        headers=headers,
    )
    assert resp.status_code == 204
    conta = client.get("/api/v1/auth/me", headers=headers).json()
    assert conta["totp_enabled"] is False
    assert conta["recovery_codes_left"] == 0
    assert "Verificação em duas etapas desligada" in _assuntos(espiao)


def test_trocar_a_senha_pede_o_codigo(espiao, relogio):
    headers = _entrar()
    segredo, _ = _ligar(headers, relogio)
    corpo = {"current_password": SENHA, "new_password": NOVA}

    sem = client.patch("/api/v1/auth/me/password", json=corpo, headers=headers)
    assert sem.status_code == 401
    assert sem.json()["detail"] == "two_factor_required"

    resp = client.patch(
        "/api/v1/auth/me/password",
        json={**corpo, "totp_code": relogio.codigo(segredo)},
        headers=headers,
    )
    assert resp.status_code == 200
    assert "A senha da sua conta Deskside mudou" in _assuntos(espiao)


def test_trocar_o_contato_pede_o_codigo(espiao, relogio):
    headers = _entrar()
    segredo, _ = _ligar(headers, relogio)
    corpo = {"current_password": SENHA, "email": "novo@example.com"}

    sem = client.post("/api/v1/auth/me/contact/start", json=corpo, headers=headers)
    assert sem.status_code == 401
    assert sem.json()["detail"] == "two_factor_required"
    assert not [e for e in espiao.enviados if e[1] == "novo@example.com"]

    resp = client.post(
        "/api/v1/auth/me/contact/start",
        json={**corpo, "totp_code": relogio.codigo(segredo)},
        headers=headers,
    )
    assert resp.status_code == 200


def test_excluir_a_conta_pede_o_codigo(relogio):
    headers = _entrar()
    segredo, _ = _ligar(headers, relogio)

    sem = client.request(
        "DELETE", "/api/v1/auth/me", json={"password": SENHA}, headers=headers
    )
    assert sem.status_code == 401
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 200

    resp = client.request(
        "DELETE",
        "/api/v1/auth/me",
        json={"password": SENHA, "totp_code": relogio.codigo(segredo)},
        headers=headers,
    )
    assert resp.status_code == 204


def test_erros_seguidos_numa_acao_sensivel_esperam(relogio):
    """Com a sessão e a senha em mãos, faltariam só seis dígitos sem limite."""
    headers = _entrar()
    _ligar(headers, relogio)
    corpo = {"password": SENHA, "totp_code": "000000"}
    respostas = [
        client.post("/api/v1/auth/2fa/disable", json=corpo, headers=headers).status_code
        for _ in range(8)
    ]
    assert 429 in respostas


def test_conta_sem_verificacao_nao_muda_nada(espiao):
    """Sem a verificação ligada, nenhuma porta pede código: quem não ligou não
    pode ficar preso por um campo que o app dele nem mostra."""
    headers = _entrar()
    resp = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": SENHA, "new_password": NOVA},
        headers=headers,
    )
    assert resp.status_code == 200
    assert _redefinir(espiao).status_code == 200


# --- avisos ------------------------------------------------------------------------


def test_login_avisa_o_dono(espiao):
    _entrar()
    espiao.avisos.clear()
    assert _login().status_code == 200
    assert espiao.avisos[0][0] == EMAIL
    assert espiao.avisos[0][1] == "Novo acesso à sua conta Deskside"
    assert "horário de Brasília" in espiao.avisos[0][2]


def test_login_errado_nao_avisa(espiao):
    _entrar()
    espiao.avisos.clear()
    assert _login(senha="errada12345").status_code == 401
    assert espiao.avisos == []


def test_ligar_a_verificacao_avisa(espiao, relogio):
    _ligar(_entrar(), relogio)
    assert "Verificação em duas etapas ligada" in _assuntos(espiao)


def test_troca_de_contato_avisa_o_endereco_antigo(espiao):
    """Se quem trocou foi um invasor, o contato novo é dele: o antigo é o único
    que o dono ainda lê."""
    headers = _entrar()
    client.post(
        "/api/v1/auth/me/contact/start",
        json={"current_password": SENHA, "email": "novo@example.com"},
        headers=headers,
    )
    codigo = espiao.ultimo_codigo("novo@example.com")
    resp = client.post(
        "/api/v1/auth/me/contact/verify", json={"code": codigo}, headers=headers
    )
    assert resp.status_code == 200

    destino, assunto, corpo = espiao.avisos[-1]
    assert destino == EMAIL
    assert assunto == "O contato da sua conta Deskside foi trocado"
    # O endereço novo vai mascarado: é um dado a mais circulando se for de um
    # invasor.
    assert "n***@example.com" in corpo
    assert "novo@example.com" not in corpo


def test_computador_pareado_avisa(espiao):
    headers = _entrar()
    with SessionLocal() as db:
        db.add(
            PairingRequest(
                code="NOVOPC234",
                device_id="dev-novo",
                hostname="notebook-sala",
                os="windows",
                expires_at=datetime.now(UTC) + timedelta(minutes=10),
            )
        )
        db.commit()
    resp = client.post("/api/v1/pairing/claim", json={"code": "NOVOPC234"}, headers=headers)
    assert resp.status_code == 201, resp.text

    _, assunto, corpo = espiao.avisos[-1]
    assert assunto == "Computador novo na sua conta Deskside"
    assert "notebook-sala" in corpo


def test_conta_por_telefone_recebe_o_aviso_por_sms(espiao):
    criar_conta(client, phone="11987654321", country="BR")
    espiao.avisos.clear()
    resp = client.post(
        "/api/v1/auth/login",
        json={"phone": "11987654321", "country": "BR", "password": SENHA},
    )
    assert resp.status_code == 200
    destino, texto, _ = espiao.avisos[0]
    assert destino == "+5511987654321"
    assert texto.startswith("Deskside: novo acesso")


def test_aviso_que_falha_nao_derruba_o_login(monkeypatch):
    """Um provedor de e-mail fora do ar não pode impedir ninguém de entrar."""

    def quebrado(*_):
        raise entrega.EntregaError("smtp fora do ar")

    monkeypatch.setattr(entrega.entregador, "aviso", quebrado)
    _entrar()
    assert _login().status_code == 200


def test_mascarar():
    assert alertas.mascarar("caio@gmail.com") == "c***@gmail.com"
    assert alertas.mascarar("+5511987654321") == "+55 •••• 4321"
    assert alertas.mascarar("123") == "••••"


# --- detalhes ---------------------------------------------------------------------


def test_composto_entrega_os_avisos():
    """O `Composto` é o entregador de produção, e não tinha os avisos: o de fim
    de teste caía no `NotImplementedError` da interface."""

    class Anota(entrega.Entregador):
        def __init__(self) -> None:
            self.recebidos: list[tuple] = []

        def aviso(self, destino, assunto, corpo):
            self.recebidos.append(("aviso", destino, assunto))

        def aviso_sms(self, destino, texto):
            self.recebidos.append(("sms", destino, texto))

    por_email, por_sms = Anota(), Anota()
    composto = entrega.Composto(por_email, por_sms)
    composto.aviso("a@b.com", "assunto", "corpo")
    composto.aviso_sms("+5511987654321", "texto")
    assert por_email.recebidos == [("aviso", "a@b.com", "assunto")]
    assert por_sms.recebidos == [("sms", "+5511987654321", "texto")]


def test_login_de_conta_inexistente_tambem_passa_pelo_bcrypt(monkeypatch):
    """Sem o bcrypt, "não existe" responderia na hora e "senha errada" depois
    dele — e o tempo contaria o que a mensagem esconde."""
    chamadas = []
    original = auth.verify_password

    def contando(senha, hashed):
        chamadas.append(hashed)
        return original(senha, hashed)

    monkeypatch.setattr(auth, "verify_password", contando)
    resp = client.post(
        "/api/v1/auth/login", json={"email": "ninguem@example.com", "password": SENHA}
    )
    assert resp.status_code == 401
    assert len(chamadas) == 1
