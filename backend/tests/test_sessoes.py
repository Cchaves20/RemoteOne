"""Cancelamento de sessões: trocar a senha derruba os tokens já emitidos.

O buraco que estes testes fecham era invisível porque **nada dava erro**. JWT é
uma assinatura que o servidor confere sozinho, sem consultar o banco — é o que o
torna barato, e é o que o torna impossível de cancelar. Consequência: quem
tivesse entrado na conta continuava dentro por 30 dias (o prazo do refresh)
mesmo depois de a senha ser trocada. E trocar a senha é exatamente o que se faz
quando se desconfia disso.

A conferência nova é uma chave sorteada por conta (`User.token_key`) que todo
token carrega. Aqui se exercita o efeito dela nos três lugares que importam: as
rotas HTTP, o refresh — que é o que mantinha a sessão viva — e o WebSocket da
tela, que é o que de fato dá teclado, mouse e imagem do computador.
"""

import time

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.connections import manager
from app.db import SessionLocal
from app.main import _authenticate_viewer, app
from app.models import Device, User

client = TestClient(app)

EMAIL = "sessao@example.com"
NOVA = "outraSenha456!"


def _headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _me(token: str) -> int:
    return client.get("/api/v1/auth/me", headers=_headers(token)).status_code


def _refresh(token: str) -> int:
    return client.post("/api/v1/auth/refresh", json={"refresh_token": token}).status_code


def _trocar_senha(token: str, atual: str = SENHA, nova: str = NOVA) -> dict:
    resp = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": atual, "new_password": nova},
        headers=_headers(token),
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _segundo_aparelho() -> dict:
    """Outro login na mesma conta — é o token dele que precisa morrer.

    Um login de verdade, e não o mesmo par reaproveitado: o recurso é sobre
    sessões **de outros aparelhos**, e reusar o token do primeiro testaria
    outra coisa.
    """
    resp = client.post("/api/v1/auth/login", json={"email": EMAIL, "password": SENHA})
    assert resp.status_code == 200, resp.text
    return resp.json()


# --- troca de senha autenticada ---------------------------------------------


def test_o_access_do_outro_aparelho_para_de_valer():
    dono = criar_conta(client, email=EMAIL)
    outro = _segundo_aparelho()

    assert _me(outro["access_token"]) == 200
    _trocar_senha(dono["access_token"])
    assert _me(outro["access_token"]) == 401


def test_o_refresh_do_outro_aparelho_para_de_valer():
    """O teste que justifica o recurso inteiro.

    O access token dura uma hora e expiraria sozinho — irritante, não perigoso.
    O refresh dura 30 dias e **renova** o access: era por ele que a sessão de
    um invasor sobrevivia à troca de senha, indefinidamente.
    """
    dono = criar_conta(client, email=EMAIL)
    outro = _segundo_aparelho()

    _trocar_senha(dono["access_token"])

    assert _refresh(outro["refresh_token"]) == 401


def test_quem_trocou_a_senha_continua_dentro():
    """A contrapartida, e o motivo de a rota devolver tokens em vez de 204.

    A troca cancela **todos** os tokens da conta, inclusive o de quem a fez. Sem
    devolver o substituto, a pessoa trocaria a senha e seria expulsa do próprio
    aparelho no instante seguinte — um recurso de segurança que parece um bug.
    """
    dono = criar_conta(client, email=EMAIL)
    novos = _trocar_senha(dono["access_token"])

    assert _me(dono["access_token"]) == 401
    assert _me(novos["access_token"]) == 200
    # E o refresh novo também vale: senão a sessão duraria só uma hora.
    assert _refresh(novos["refresh_token"]) == 200


def test_senha_atual_errada_nao_cancela_nada():
    """Cancelar antes de conferir daria a qualquer um com um token roubado o
    poder de deslogar o dono — e transformaria um erro de digitação em
    "todos os seus aparelhos foram desconectados"."""
    dono = criar_conta(client, email=EMAIL)
    resp = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": "erradaErrada1!", "new_password": NOVA},
        headers=_headers(dono["access_token"]),
    )
    assert resp.status_code == 401
    assert _me(dono["access_token"]) == 200


def test_trocar_email_ou_telefone_nao_derruba_ninguem(espiao):
    """O limite do recurso, escrito de propósito.

    Cancelar sessão a cada mexida na conta seria deslogar o usuário por trocar
    o e-mail — incômodo sem contrapartida, porque quem troca o contato já provou
    a senha atual. O corte é a **credencial de entrada**, e só ela.
    """
    dono = criar_conta(client, email=EMAIL)
    outro = _segundo_aparelho()

    inicio = client.post(
        "/api/v1/auth/me/contact/start",
        json={"current_password": SENHA, "email": "novo@example.com"},
        headers=_headers(dono["access_token"]),
    )
    assert inicio.status_code == 200, inicio.text
    fim = client.post(
        "/api/v1/auth/me/contact/verify",
        json={"code": espiao.ultimo_codigo("novo@example.com")},
        headers=_headers(dono["access_token"]),
    )
    assert fim.status_code == 200, fim.text
    assert _me(outro["access_token"]) == 200


# --- recuperação de senha ("esqueci minha senha") ----------------------------


def test_recuperar_a_senha_tambem_derruba_as_sessoes(espiao):
    """Aqui a derrubada vale ainda mais: quem usa "esqueci minha senha" ou
    perdeu o acesso ou desconfia que alguém o tem. Trocar a fechadura sem
    recolher a cópia da chave não resolveria nem um caso nem o outro."""
    invasor = criar_conta(client, email=EMAIL)

    assert client.post(
        "/api/v1/auth/password/forgot", json={"email": EMAIL}
    ).status_code == 200
    resp = client.post(
        "/api/v1/auth/password/reset",
        json={
            "destination": EMAIL,
            "code": espiao.ultimo_codigo(EMAIL),
            "password": NOVA,
            "password_confirm": NOVA,
        },
    )
    assert resp.status_code == 200

    assert _me(invasor["access_token"]) == 401
    assert _refresh(invasor["refresh_token"]) == 401
    # E quem recuperou entra com o par que a própria resposta trouxe.
    assert _me(resp.json()["access_token"]) == 200


# --- o canal que mais importa: a tela ----------------------------------------


class AgenteFalso:
    """Agente conectado, do ponto de vista do backend."""

    def __init__(self):
        self.enviados = []

    async def send_json(self, message):
        self.enviados.append(message)


def _parear(user_id: int, device_id: str) -> None:
    with SessionLocal() as db:
        db.add(
            Device(
                device_id=device_id,
                user_id=user_id,
                name="pc",
                os="windows",
                hostname="pc",
            )
        )
        db.commit()


def test_o_websocket_da_tela_recusa_o_token_cancelado():
    """O que não podia faltar.

    Fechar as rotas HTTP e deixar este canal aberto seria o pior resultado
    possível: é por ele que passam a imagem da tela, o teclado e o mouse. E ele
    **não** usa o `get_current_user` — tem autenticação própria, que precisava
    ganhar a mesma conferência.

    A metade de antes é integração de verdade (a oferta atravessa até o agente);
    a de depois chama o `_authenticate_viewer` direto, que é a função que o
    endpoint consulta antes de qualquer coisa. Não é preguiça: a primeira versão
    esperava o servidor fechar o socket, e quando a conferência falhava o
    servidor **não fechava** — o teste ficava pendurado no `receive_json()` até o
    tempo limite, em vez de acusar o defeito. Um teste que trava em vez de
    falhar é pior do que nenhum: não diz o que está errado.
    """
    dono = criar_conta(client, email=EMAIL)
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == EMAIL))
    _parear(user_id, "dev-sessao-1")

    agente = AgenteFalso()
    manager.register("dev-sessao-1", agente)
    try:
        # Antes da troca o token abre o canal: a oferta chega ao agente.
        with client.websocket_connect("/ws/viewer/dev-sessao-1") as ws:
            ws.send_json({"token": dono["access_token"]})
            ws.send_json({"type": "webrtc_offer", "sdp": "v=0"})
            ws.close()
        assert [m for m in agente.enviados if m.get("type") == "webrtc_offer"], (
            f"o canal devia estar aberto antes da troca; recebido: {agente.enviados}"
        )
        assert _authenticate_viewer(dono["access_token"], "dev-sessao-1")

        _trocar_senha(dono["access_token"])

        assert not _authenticate_viewer(dono["access_token"], "dev-sessao-1"), (
            "o token cancelado ainda abre a tela do computador"
        )
    finally:
        manager.unregister("dev-sessao-1", agente)


# --- id reaproveitado --------------------------------------------------------


def test_token_da_conta_excluida_nao_abre_a_conta_que_herdou_o_id():
    """A armadilha do SQLite, agora na forma de uma sessão.

    `INTEGER PRIMARY KEY` é reaproveitado: apagar a conta 1 faz a próxima nascer
    como 1, e o token da conta apagada tem o mesmo `sub`. Com um contador
    começando em zero, ele abriria a conta de **outra pessoa**; é por isso que a
    chave de sessão é sorteada. É a mesma raiz que já tinha feito perfis de uma
    conta excluída reaparecerem em outra.

    A primeira tentativa aqui usava o relógio (token emitido antes de a conta
    existir não é dela) e foi **este teste** que a derrubou: `iat` só tem
    segundos inteiros, e as duas contas nascem dentro do mesmo segundo.
    """
    antigo = criar_conta(client, email=EMAIL)
    assert client.request(
        "DELETE",
        "/api/v1/auth/me",
        json={"password": SENHA},
        headers=_headers(antigo["access_token"]),
    ).status_code == 204

    novo = criar_conta(client, email="outrodono@example.com")
    with SessionLocal() as db:
        ids = list(db.scalars(select(User.id)).all())
    assert ids == [1], "o teste só prova algo se o id tiver mesmo sido reaproveitado"

    assert _me(antigo["access_token"]) == 401
    assert _refresh(antigo["refresh_token"]) == 401
    # E o dono novo entra normalmente.
    assert _me(novo["access_token"]) == 200


# --- o sinal que o app usa para separar os 401 -------------------------------


def test_so_o_401_de_token_traz_o_cabecalho_www_authenticate(espiao):
    """O contrato de que o app depende, escrito aqui porque quem o cumpre é daqui.

    Três 401 convivem nesta API e só um deles é sobre a sessão:

    - token inválido ou cancelado  -> o app deve deslogar;
    - senha atual errada           -> o app deve dizer "senha errada";
    - código de verificação errado -> idem.

    Se o app tratasse os três igual, errar a digitação da senha atual expulsaria
    a pessoa da conta. Quem separa é o `WWW-Authenticate`, que só o
    `get_current_user` manda — é o que ele significa em HTTP: "suas credenciais
    estão ausentes ou não valem".

    Este teste existe porque o sinal é fácil de perder sem nada quebrar aqui: um
    `HTTPException(401)` a mais numa rota de conta, sem o cabeçalho, continua
    passando na suíte e some silenciosamente lá — o app volta a ficar preso numa
    sessão morta, ou passa a deslogar por erro de digitação.
    """
    dono = criar_conta(client, email=EMAIL)
    cabecalho = "www-authenticate"

    # 1. Token que não vale: com o cabeçalho.
    ruim = client.get("/api/v1/auth/me", headers=_headers("token-de-mentira"))
    assert ruim.status_code == 401
    assert cabecalho in ruim.headers

    # 2. Token cancelado pela troca de senha: idem — é o caso que motivou tudo.
    outro = _segundo_aparelho()
    _trocar_senha(dono["access_token"])
    cancelado = client.get("/api/v1/auth/me", headers=_headers(outro["access_token"]))
    assert cancelado.status_code == 401
    assert cabecalho in cancelado.headers

    # 3. Senha atual errada: **sem** o cabeçalho. O token está ótimo.
    novo = client.post(
        "/api/v1/auth/login", json={"email": EMAIL, "password": NOVA}
    ).json()
    senha_errada = client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": "naoEssa1!", "new_password": "terceira789!"},
        headers=_headers(novo["access_token"]),
    )
    assert senha_errada.status_code == 401
    assert cabecalho not in senha_errada.headers

    # 4. Código de verificação errado: **sem** o cabeçalho, pelo mesmo motivo.
    assert client.post(
        "/api/v1/auth/me/contact/start",
        json={"current_password": NOVA, "email": "outro@example.com"},
        headers=_headers(novo["access_token"]),
    ).status_code == 200
    codigo_errado = client.post(
        "/api/v1/auth/me/contact/verify",
        json={"code": "000000"},
        headers=_headers(novo["access_token"]),
    )
    assert codigo_errado.status_code == 401
    assert cabecalho not in codigo_errado.headers


def test_o_login_recusado_nao_traz_o_cabecalho():
    """Quem erra a senha no login não tem sessão para perder, e o app não deve
    tratar isso como "sua sessão acabou"."""
    criar_conta(client, email=EMAIL)
    resp = client.post(
        "/api/v1/auth/login", json={"email": EMAIL, "password": "erradA1!"}
    )
    assert resp.status_code == 401
    assert "www-authenticate" not in resp.headers


def test_a_sessao_de_tela_ja_aberta_cai_quando_a_senha_muda(monkeypatch):
    """O canal fecha **sozinho**, sem o app precisar mandar nada.

    O teste acima cobria a porta de entrada: com o token cancelado, o canal não
    abre mais. Faltava o caso que assusta — o canal que **já estava aberto**
    quando a senha mudou. Ele continuava de pé, porque a autenticação acontecia
    uma vez só, na conexão. Ou seja: alguém entrou na sua conta, você troca a
    senha para expulsar, e a sessão de controle dele segue mostrando a tela e
    aceitando teclado.

    E a expulsão não pode depender de o app mandar alguma coisa: os frames vão
    no sentido contrário, e um espectador pode passar minutos calado. Por isso o
    laço acorda sozinho — é isso que este teste exercita, ao não enviar nada
    depois da troca.
    """
    import threading

    from app import main

    monkeypatch.setattr(main, "REVALIDAR_VIEWER_SEGUNDOS", 0.2)

    dono = criar_conta(client, email="tela-viva@example.com")
    with SessionLocal() as db:
        user_id = db.scalar(select(User.id).where(User.email == "tela-viva@example.com"))
    _parear(user_id, "dev-tela-viva")

    agente = AgenteFalso()
    manager.register("dev-tela-viva", agente)
    try:
        with client.websocket_connect("/ws/viewer/dev-tela-viva") as ws:
            ws.send_json({"token": dono["access_token"]})
            # A oferta atravessa: o canal está mesmo aberto e autenticado.
            ws.send_json({"type": "webrtc_offer", "sdp": "v=0"})
            for _ in range(100):
                if any(m.get("type") == "webrtc_offer" for m in agente.enviados):
                    break
                time.sleep(0.01)
            assert any(m.get("type") == "webrtc_offer" for m in agente.enviados), (
                "o canal precisa estar aberto antes da troca de senha"
            )

            _trocar_senha(dono["access_token"])

            # Espera o servidor fechar — **num prazo**, e não num `receive()`
            # nu. Se a revalidação regredir, o teste falha dizendo o que houve;
            # sem o prazo, ele ficaria pendurado para sempre, e um teste que
            # trava é pior que nenhum: não diz o que está errado.
            recebido = {}

            def esperar_fechamento():
                recebido["pacote"] = ws.receive()

            # Thread **daemon**, e não um ThreadPoolExecutor: se o servidor não
            # fechar, esta thread fica presa no `receive()` para sempre, e um
            # executor esperaria por ela no fim do `with` — o teste travaria em
            # vez de falhar, que é exatamente o defeito que o prazo existe para
            # evitar. Daemon o interpretador abandona ao sair.
            leitor = threading.Thread(target=esperar_fechamento, daemon=True)
            leitor.start()
            leitor.join(timeout=10)
            if leitor.is_alive():
                raise AssertionError(
                    "a sessão de tela continuou aberta depois de a senha mudar"
                )
            fechamento = recebido["pacote"]
            assert fechamento["type"] == "websocket.close", fechamento
            assert fechamento.get("code") == 4401, fechamento
    finally:
        manager.unregister("dev-tela-viva", agente)
