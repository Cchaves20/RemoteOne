"""Esqueci minha senha: código, troca e o que **não** se conta a um estranho.

O que esta suíte protege, além do caminho feliz:

- que a resposta seja **idêntica** para conta que existe e conta que não existe.
  A diferença viraria um oráculo: alguém digitaria endereços em sequência e
  descobriria quais têm conta no Deskside — e cada conta aqui é um computador;
- que a senha nova cumpra as mesmas cinco regras do cadastro;
- que o código usado morra, junto com qualquer outro em aberto da mesma conta.
"""

from datetime import UTC, datetime, timedelta

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import verificacao
from app.db import SessionLocal
from app.main import app
from app.models import PasswordReset

client = TestClient(app)

NOVA = "OutraSenha456!"


def pedir(**corpo):
    return client.post("/api/v1/auth/password/forgot", json=corpo)


def trocar(destino, codigo, senha=NOVA):
    return client.post(
        "/api/v1/auth/password/reset",
        json={
            "destination": destino,
            "code": codigo,
            "password": senha,
            "password_confirm": senha,
        },
    )


def test_recupera_a_senha_e_ja_entra(espiao):
    """Entrar direto é deliberado: quem acabou de provar posse do contato e
    escolher uma senha já fez tudo o que o login pediria — e a senha
    recém-criada é a que mais se esquece se tiver de ser digitada de novo no
    minuto seguinte."""
    criar_conta(client, email="esqueci@example.com")

    assert pedir(email="esqueci@example.com").status_code == 200
    codigo = espiao.ultimo_codigo("esqueci@example.com")

    resp = trocar("esqueci@example.com", codigo)
    assert resp.status_code == 200
    assert resp.json()["access_token"]

    # A senha antiga não vale mais; a nova vale.
    assert client.post(
        "/api/v1/auth/login", json={"email": "esqueci@example.com", "password": SENHA}
    ).status_code == 401
    assert client.post(
        "/api/v1/auth/login", json={"email": "esqueci@example.com", "password": NOVA}
    ).status_code == 200


def test_recupera_por_telefone(espiao):
    criar_conta(client, phone="11955554444", country="BR")
    resp = pedir(phone="(11) 95555-4444", country="BR")
    assert resp.status_code == 200
    # O destino volta normalizado, e é ele que a tela manda de volta.
    assert resp.json()["destination"] == "+5511955554444"
    assert resp.json()["channel"] == "phone"

    codigo = espiao.ultimo_codigo("+5511955554444")
    assert trocar("+5511955554444", codigo).status_code == 200


def test_contato_desconhecido_responde_igual(espiao):
    """A propriedade que separa esta rota do cadastro.

    Lá, dizer "e-mail já cadastrado" é necessário — a pessoa precisa saber para
    ir entrar em vez de tentar cadastrar de novo. Aqui, a mesma franqueza
    entregaria a lista de quem tem conta.
    """
    criar_conta(client, email="existe@example.com")

    tem = pedir(email="existe@example.com")
    nao_tem = pedir(email="naoexiste@example.com")

    assert tem.status_code == nao_tem.status_code == 200
    # Mesma forma de resposta, campo a campo — só o destino difere, e ele é o
    # que a pessoa digitou.
    assert tem.json().keys() == nao_tem.json().keys()
    assert tem.json()["channel"] == nao_tem.json()["channel"]
    assert tem.json()["resend_in_seconds"] == nao_tem.json()["resend_in_seconds"]
    assert tem.json()["delivered"] == nao_tem.json()["delivered"]

    # E nada foi enviado para quem não existe: um envio a mais seria o mesmo
    # vazamento por outro caminho (quem controla o servidor de e-mail veria).
    enviados = [d for _, d, _ in espiao.enviados]
    assert "naoexiste@example.com" not in enviados
    assert "existe@example.com" in enviados

    # E não sobrou pedido no banco para uma conta que não existe.
    with SessionLocal() as db:
        assert len(db.scalars(select(PasswordReset)).all()) == 1


def test_senha_nova_precisa_das_cinco_regras(espiao):
    criar_conta(client, email="fraca@example.com")
    pedir(email="fraca@example.com")
    codigo = espiao.ultimo_codigo("fraca@example.com")

    resp = trocar("fraca@example.com", codigo, senha="semnumero!!")
    assert resp.status_code == 400
    assert "número" in resp.json()["detail"]

    # E o código continua valendo: recusar a senha não pode custar o código.
    assert trocar("fraca@example.com", codigo).status_code == 200


def test_confirmacao_precisa_bater(espiao):
    criar_conta(client, email="confirma@example.com")
    pedir(email="confirma@example.com")
    resp = client.post(
        "/api/v1/auth/password/reset",
        json={
            "destination": "confirma@example.com",
            "code": espiao.ultimo_codigo("confirma@example.com"),
            "password": NOVA,
            "password_confirm": "OutraCoisa1!",
        },
    )
    assert resp.status_code == 422


def test_codigo_errado_conta_tentativa_e_depois_desiste(espiao):
    criar_conta(client, email="tentativas@example.com")
    pedir(email="tentativas@example.com")

    for restantes in range(verificacao.MAX_TENTATIVAS - 1, 0, -1):
        resp = trocar("tentativas@example.com", "000000")
        assert resp.status_code == 401
        assert str(restantes) in resp.json()["detail"]

    assert trocar("tentativas@example.com", "000000").status_code == 429
    with SessionLocal() as db:
        assert db.scalar(select(PasswordReset)) is None


def test_codigo_expirado(espiao):
    criar_conta(client, email="expira@example.com")
    pedir(email="expira@example.com")
    codigo = espiao.ultimo_codigo("expira@example.com")

    with SessionLocal() as db:
        pedido = db.scalar(select(PasswordReset))
        pedido.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        db.commit()

    assert trocar("expira@example.com", codigo).status_code == 410
    with SessionLocal() as db:
        assert db.scalar(select(PasswordReset)) is None


def test_o_codigo_usado_morre(espiao):
    """Um código que continua valendo depois de trocar a senha é uma senha que
    qualquer um com o e-mail antigo pode trocar de novo."""
    criar_conta(client, email="umavez@example.com")
    pedir(email="umavez@example.com")
    codigo = espiao.ultimo_codigo("umavez@example.com")

    assert trocar("umavez@example.com", codigo).status_code == 200
    assert trocar("umavez@example.com", codigo).status_code == 404


def test_pedir_de_novo_antes_da_hora_nao_gasta_envio(espiao):
    """Cada SMS custa dinheiro, e o botão de reenviar é o que se aperta
    repetidamente quando a mensagem demora."""
    criar_conta(client, email="apressado@example.com")
    assert pedir(email="apressado@example.com").status_code == 200
    quantos = len(espiao.enviados)

    cedo = pedir(email="apressado@example.com")
    assert cedo.status_code == 429
    assert len(espiao.enviados) == quantos

    with SessionLocal() as db:
        pedido = db.scalar(select(PasswordReset))
        pedido.last_sent_at = datetime.now(UTC) - verificacao.ESPERA_REENVIO
        db.commit()

    assert pedir(email="apressado@example.com").status_code == 200
    assert len(espiao.enviados) == quantos + 1
    # O código novo vale; o antigo não.
    assert trocar("apressado@example.com", espiao.enviados[-1][2]).status_code == 200


def test_precisa_de_email_ou_telefone_e_so_um():
    assert pedir().status_code == 422
    assert pedir(email="a@b.com", phone="11987654321", country="BR").status_code == 422
    assert pedir(phone="11987654321").status_code == 422


def test_recuperacao_sem_pedido_em_andamento():
    assert trocar("fantasma@example.com", "123456").status_code == 404
