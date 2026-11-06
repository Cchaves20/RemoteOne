"""LGPD e segurança: o que a auditoria de conformidade de novembro de 2026 pediu.

Aceite dos termos com versão e data, a data de nascimento que não fica, a cópia
dos próprios dados sem credenciais, a faxina do que venceu, o telefone recusado
sem SMS e o limite na senha atual.
"""

from datetime import UTC, date, datetime, timedelta

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select, text

from app import db as banco
from app import entrega, faxina, limite, termos
from app.config import settings
from app.db import SessionLocal, engine
from app.main import app
from app.models import Device, PendingSignup, Sessao, User

client = TestClient(app)


def _cabecalho(email: str) -> dict:
    tokens = criar_conta(client, email=email)
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _formulario(**mudancas) -> dict:
    base = {
        "first_name": "Ana",
        "last_name": "Souza",
        "birth_date": "1998-04-20",
        "email": "termos@example.com",
        "password": SENHA,
        "password_confirm": SENHA,
        "terms_version": termos.VERSAO,
    }
    base.update(mudancas)
    return {k: v for k, v in base.items() if v is not None}


# --- aceite dos termos ---------------------------------------------------------


def test_cadastro_sem_aceite_e_recusado():
    """Um app antigo, sem a caixa de aceite, não manda a versão."""
    resp = client.post("/api/v1/auth/signup/start", json=_formulario(terms_version=None))
    assert resp.status_code == 400
    assert "termos" in resp.json()["detail"]


def test_aceitar_uma_versao_antiga_nao_vale():
    resp = client.post("/api/v1/auth/signup/start", json=_formulario(terms_version="2020-01"))
    assert resp.status_code == 400


def test_a_conta_diz_qual_versao_aceitou_e_qual_esta_em_vigor():
    cab = _cabecalho("versao@example.com")
    eu = client.get("/api/v1/auth/me", headers=cab).json()
    assert eu["termos_versao"] == termos.VERSAO
    assert eu["termos_atual"] == termos.VERSAO


def test_conta_antiga_aceita_a_versao_nova_pelo_app():
    cab = _cabecalho("antiga@example.com")
    with SessionLocal() as db:
        u = db.scalar(select(User).where(User.email == "antiga@example.com"))
        u.termos_versao, u.termos_aceitos_em = "", None
        db.commit()
    assert client.get("/api/v1/auth/me", headers=cab).json()["termos_versao"] == ""

    # Uma versão que não é a em vigor não vale como aceite do texto novo.
    velha = client.post("/api/v1/auth/me/terms", json={"version": "2020-01"}, headers=cab)
    assert velha.status_code == 409

    ok = client.post("/api/v1/auth/me/terms", json={"version": termos.VERSAO}, headers=cab)
    assert ok.status_code == 204
    with SessionLocal() as db:
        u = db.scalar(select(User).where(User.email == "antiga@example.com"))
        assert u.termos_versao == termos.VERSAO
        assert u.termos_aceitos_em is not None


# --- minimização ---------------------------------------------------------------


def test_o_cadastro_pendente_nao_guarda_a_data_de_nascimento():
    assert client.post("/api/v1/auth/signup/start", json=_formulario()).status_code == 201
    with SessionLocal() as db:
        p = db.scalar(select(PendingSignup).where(PendingSignup.destino == "termos@example.com"))
        assert p.birth_date is None
        assert p.termos_versao == termos.VERSAO


def test_datas_guardadas_antes_sao_apagadas_na_subida():
    criar_conta(client, email="nascida@example.com")
    with engine.begin() as conn:
        conn.execute(text("UPDATE users SET birth_date = '1990-01-01'"))
    banco._apagar_datas_de_nascimento()
    with SessionLocal() as db:
        assert db.scalar(select(User.birth_date).where(User.email == "nascida@example.com")) is None


# --- a cópia dos próprios dados ------------------------------------------------


def test_exportar_traz_os_dados_e_nenhuma_credencial():
    cab = _cabecalho("exporta@example.com")
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == "exporta@example.com"))
        db.add(
            Device(
                device_id="dev-exp",
                user_id=uid,
                name="pc",
                os="windows",
                hostname="pc",
                agent_secret="a" * 64,
                agent_secret_pendente="segredo-em-texto",
            )
        )
        db.commit()
        user = db.get(User, uid)
        hash_da_senha, chave = user.hashed_password, user.token_key

    resp = client.get("/api/v1/auth/me/export", headers=cab)
    assert resp.status_code == 200
    dados = resp.json()
    assert dados["conta"]["email"] == "exporta@example.com"
    assert [c["device_id"] for c in dados["computadores"]] == ["dev-exp"]

    corpo = resp.text
    for segredo in (hash_da_senha, chave, "a" * 64, "segredo-em-texto"):
        assert segredo not in corpo
    for nome in ("hashed_password", "totp_secret", "recovery_codes", "token_key", "agent_secret"):
        assert f'"{nome}"' not in corpo


def test_exportar_exige_login():
    assert client.get("/api/v1/auth/me/export").status_code in (401, 403)


# --- telefone sem SMS ----------------------------------------------------------


def test_sem_sms_o_cadastro_por_telefone_e_recusado(monkeypatch, espiao):
    """Sem provedor de SMS, o código ia para o diário com o número junto."""
    monkeypatch.setattr(entrega, "entregador", entrega.Composto(espiao, entrega.NoDiario()))
    resp = client.post(
        "/api/v1/auth/signup/start",
        json=_formulario(email=None, phone="11987654321", country="BR"),
    )
    assert resp.status_code == 400
    assert "SMS" in resp.json()["detail"]
    # O e-mail continua normal.
    assert client.post("/api/v1/auth/signup/start", json=_formulario()).status_code == 201


def test_sem_sms_o_esqueci_a_senha_por_telefone_e_recusado(monkeypatch, espiao):
    monkeypatch.setattr(entrega, "entregador", entrega.Composto(espiao, entrega.NoDiario()))
    resp = client.post(
        "/api/v1/auth/password/forgot", json={"phone": "11987654321", "country": "BR"}
    )
    assert resp.status_code == 400


# --- limite na senha atual -----------------------------------------------------


def test_errar_a_senha_atual_demais_vira_429():
    cab = _cabecalho("senha-atual@example.com")
    corpo = {"current_password": "errada-1A!", "new_password": "OutraSenha1!"}
    for _ in range(limite.LIMIAR_CONTA):
        assert client.patch("/api/v1/auth/me/password", json=corpo, headers=cab).status_code == 401
    resp = client.patch("/api/v1/auth/me/password", json=corpo, headers=cab)
    assert resp.status_code == 429
    # Nem a senha certa passa durante a espera.
    certo = {"current_password": SENHA, "new_password": "OutraSenha1!"}
    assert client.patch("/api/v1/auth/me/password", json=certo, headers=cab).status_code == 429


def test_excluir_a_conta_tambem_tem_limite():
    cab = _cabecalho("excluir-limite@example.com")
    for _ in range(limite.LIMIAR_CONTA):
        r = client.request("DELETE", "/api/v1/auth/me", json={"password": "errada"}, headers=cab)
        assert r.status_code == 401
    r = client.request("DELETE", "/api/v1/auth/me", json={"password": SENHA}, headers=cab)
    assert r.status_code == 429


# --- faxina --------------------------------------------------------------------


def _pendente(destino: str, vence: datetime) -> PendingSignup:
    return PendingSignup(
        destino=destino,
        canal="email",
        hashed_password="x",
        first_name="a",
        last_name="b",
        hashed_code="c",
        expires_at=vence,
    )


def test_a_faxina_apaga_o_cadastro_abandonado_e_deixa_o_recente():
    agora = datetime.now(UTC)
    with SessionLocal() as db:
        db.add(_pendente("velho@example.com", agora - timedelta(days=3)))
        db.add(_pendente("novo@example.com", agora + timedelta(minutes=5)))
        db.commit()
        apagados = faxina.limpar(db, agora)
        restantes = set(db.scalars(select(PendingSignup.destino)))
    assert apagados["cadastros"] == 1
    assert restantes == {"novo@example.com"}


def test_a_faxina_apaga_sessao_encerrada_ha_muito_tempo():
    criar_conta(client, email="sessoes@example.com")
    agora = datetime.now(UTC)
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == "sessoes@example.com"))
        velha = Sessao(
            id="sessao-velha",
            user_id=uid,
            aparelho="antigo",
            encerrada_em=agora - timedelta(days=40),
            ultimo_uso=agora - timedelta(days=40),
        )
        db.add(velha)
        db.commit()
        antes = db.scalar(select(Sessao.id).where(Sessao.aparelho == "antigo"))
        faxina.limpar(db, agora)
        assert db.get(Sessao, antes) is None
        # A sessão em uso, aberta pelo cadastro, continua.
        assert db.scalar(select(Sessao).where(Sessao.user_id == uid)) is not None


def test_com_a_trava_fechada_o_segredo_pendente_antigo_sai(monkeypatch):
    criar_conta(client, email="trava@example.com")
    agora = datetime.now(UTC)
    with SessionLocal() as db:
        uid = db.scalar(select(User.id).where(User.email == "trava@example.com"))
        db.add(
            Device(
                device_id="dev-antigo",
                user_id=uid,
                name="a",
                os="windows",
                hostname="a",
                agent_secret="b" * 64,
                agent_secret_pendente="texto",
                created_at=agora - timedelta(days=5),
            )
        )
        db.add(
            Device(
                device_id="dev-recem",
                user_id=uid,
                name="b",
                os="windows",
                hostname="b",
                agent_secret="c" * 64,
                agent_secret_pendente="texto2",
                created_at=agora,
            )
        )
        db.commit()

        faxina.limpar(db, agora)  # trava aberta: nada muda
        assert db.scalar(
            select(Device.agent_secret_pendente).where(Device.device_id == "dev-antigo")
        )

        monkeypatch.setattr(settings, "exigir_segredo_do_agente", True)
        faxina.limpar(db, agora)
        pendentes = dict(db.execute(select(Device.device_id, Device.agent_secret_pendente)).all())
    assert pendentes["dev-antigo"] is None
    # O pareamento de agora ainda vai entregar o segredo na próxima conexão.
    assert pendentes["dev-recem"] == "texto2"


def test_data_de_hoje_continua_conferindo_a_idade():
    """A idade continua conferida, mesmo sem guardar a data."""
    crianca = date.today().replace(year=date.today().year - 10).isoformat()
    resp = client.post("/api/v1/auth/signup/start", json=_formulario(birth_date=crianca))
    assert resp.status_code == 400


# --- incidente -----------------------------------------------------------------


def test_derrubar_sessoes_invalida_todo_token_sem_mexer_no_segredo():
    """Num incidente: todo mundo entra de novo, e o 2FA continua abrindo."""
    from app import incidente, vinculos

    cab = _cabecalho("incidente@example.com")
    assert client.get("/api/v1/auth/me", headers=cab).status_code == 200
    segredo_antes = settings.jwt_secret

    assert incidente.derrubar_sessoes() >= 1
    vinculos.esquecer_tudo()  # o que o `restart api` faz no servidor

    assert client.get("/api/v1/auth/me", headers=cab).status_code == 401
    assert settings.jwt_secret == segredo_antes
    with SessionLocal() as db:
        abertas = db.scalars(select(Sessao).where(Sessao.encerrada_em.is_(None))).all()
    assert abertas == []
