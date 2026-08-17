"""Limite de tentativas nos caminhos abertos.

Duas metades. A primeira é a regra, testada direto no `Limitador` com o relógio
na mão — sem isso, verificar "a espera acaba em trinta segundos" exigiria um
teste que dorme trinta segundos, e um teste lento é um teste que alguém desliga.
A segunda é o caminho pelo HTTP, onde moram os erros que a regra sozinha não
pega: cobrar no lugar errado, ou cobrar de um jeito que devolve o oráculo de
quais contas existem.
"""

from conftest import SENHA, criar_conta
from fastapi.testclient import TestClient

from app import limite
from app.main import app

client = TestClient(app)


# --- a regra ------------------------------------------------------------------


def test_o_limiar_deixa_errar_algumas_vezes():
    """Errar a senha três ou quatro vezes é rotina de quem tem várias senhas
    parecidas. Punir isso seria punir o dono da conta."""
    lim = limite.Limitador(limiar=5)
    for _ in range(4):
        lim.registrar_falha("a@b.com", agora=100.0)
    assert lim.falta_esperar("a@b.com", agora=100.0) == 0


def test_a_espera_comeca_no_limiar_e_dobra():
    lim = limite.Limitador(limiar=5)
    for _ in range(5):
        lim.registrar_falha("a@b.com", agora=100.0)
    assert lim.falta_esperar("a@b.com", agora=100.0) == limite.ESPERA_INICIAL

    lim.registrar_falha("a@b.com", agora=100.0)
    assert lim.falta_esperar("a@b.com", agora=100.0) == limite.ESPERA_INICIAL * 2


def test_a_espera_tem_teto():
    """Sem teto, a espera cresceria até virar uma conta trancada na prática — que
    é exatamente o que este desenho existe para não fazer."""
    assert limite.espera_apos(falhas=100, limiar=5) == limite.ESPERA_MAXIMA


def test_a_espera_passa_com_o_tempo():
    lim = limite.Limitador(limiar=5)
    for _ in range(5):
        lim.registrar_falha("a@b.com", agora=100.0)
    assert lim.falta_esperar("a@b.com", agora=100.0 + limite.ESPERA_INICIAL - 1) == 1
    assert lim.falta_esperar("a@b.com", agora=100.0 + limite.ESPERA_INICIAL) == 0


def test_a_janela_esquece_tentativa_velha():
    """Sem esquecimento, um erro hoje somaria com um erro no mês que vem e a
    pessoa cairia em espera longa sem ter feito nada."""
    lim = limite.Limitador(limiar=5)
    for _ in range(5):
        lim.registrar_falha("a@b.com", agora=100.0)
    depois = 100.0 + limite.JANELA_SEGUNDOS + 1
    lim.registrar_falha("a@b.com", agora=depois)
    # A contagem recomeçou: uma falha só, longe do limiar.
    assert lim.falta_esperar("a@b.com", agora=depois) == 0


def test_acertar_zera_a_contagem():
    lim = limite.Limitador(limiar=5)
    for _ in range(6):
        lim.registrar_falha("a@b.com", agora=100.0)
    assert lim.falta_esperar("a@b.com", agora=100.0) > 0
    lim.registrar_acerto("a@b.com")
    assert lim.falta_esperar("a@b.com", agora=100.0) == 0


def test_uma_chave_nao_afeta_a_outra():
    """O ponto do limite por conta: trancar a sua não pode trancar a minha."""
    lim = limite.Limitador(limiar=5)
    for _ in range(10):
        lim.registrar_falha("vitima@b.com", agora=100.0)
    assert lim.falta_esperar("outro@b.com", agora=100.0) == 0


def test_o_teto_de_chaves_nao_deixa_a_memoria_crescer_sem_fim():
    """A chave vem de fora. Sem teto, mil e um e-mails inventados criariam mil e
    uma entradas, e o limite viraria um jeito de consumir a memória do
    servidor."""
    lim = limite.Limitador(limiar=5, max_chaves=10)
    for i in range(50):
        lim.registrar_falha(f"conta{i}@b.com", agora=100.0 + i)
    assert len(lim._contagens) <= 10
    # E o que sobrou é o mais recente, não o mais antigo.
    assert "conta49@b.com" in lim._contagens
    assert "conta0@b.com" not in lim._contagens


# --- o caminho pelo HTTP ------------------------------------------------------


def _errar_login(email: str, vezes: int) -> int:
    """Erra a senha `vezes` e devolve o último código HTTP."""
    codigo = 0
    for _ in range(vezes):
        codigo = client.post(
            "/api/v1/auth/login",
            json={"email": email, "password": "senhaErrada123!"},
        ).status_code
    return codigo


def test_senha_errada_demais_vira_429_com_retry_after():
    criar_conta(client, email="lim1@example.com")
    assert _errar_login("lim1@example.com", limite.LIMIAR_CONTA) == 401

    resp = client.post(
        "/api/v1/auth/login",
        json={"email": "lim1@example.com", "password": "senhaErrada123!"},
    )
    assert resp.status_code == 429
    # O cabeçalho é o que um cliente bem-educado obedece sozinho; o texto é o que
    # a pessoa lê. Sem o texto, o app mostraria "erro 429" e ninguém saberia que
    # basta esperar.
    assert int(resp.headers["retry-after"]) > 0
    assert "tentativas" in resp.json()["detail"].lower()


def test_a_senha_certa_ainda_e_recusada_durante_a_espera():
    """O que impede a varredura: passado o limiar, nem a senha certa passa. Sem
    isto, o limite seria só um atraso entre tentativas erradas — e quem estivesse
    varrendo continuaria a mesma velocidade ao acertar."""
    criar_conta(client, email="lim2@example.com")
    _errar_login("lim2@example.com", limite.LIMIAR_CONTA)

    resp = client.post(
        "/api/v1/auth/login",
        json={"email": "lim2@example.com", "password": SENHA},
    )
    assert resp.status_code == 429


def test_a_conta_de_outra_pessoa_continua_entrando():
    """O furo do limite só-por-IP invertido: com contagem por conta, ninguém
    tranca a conta alheia. Aqui as duas contas vêm do **mesmo IP** (o cliente de
    teste), então este teste também prova que o limite por conta não é, na
    verdade, um limite por IP disfarçado."""
    criar_conta(client, email="lim3@example.com")
    criar_conta(client, email="lim4@example.com")
    _errar_login("lim3@example.com", limite.LIMIAR_CONTA + 1)

    resp = client.post(
        "/api/v1/auth/login",
        json={"email": "lim4@example.com", "password": SENHA},
    )
    assert resp.status_code == 200, resp.text


def test_entrar_certo_limpa_o_que_foi_errado_antes():
    criar_conta(client, email="lim5@example.com")
    _errar_login("lim5@example.com", limite.LIMIAR_CONTA - 1)

    assert (
        client.post(
            "/api/v1/auth/login",
            json={"email": "lim5@example.com", "password": SENHA},
        ).status_code
        == 200
    )
    # Depois do acerto, o orçamento inteiro volta.
    assert _errar_login("lim5@example.com", limite.LIMIAR_CONTA - 1) == 401


def test_pedir_codigo_demais_do_mesmo_ip_vira_429():
    """Cada um destes pedidos gasta uma entrega. SMS custa dinheiro, e um laço
    aqui é ao mesmo tempo uma conta a pagar e uma máquina de encher o telefone de
    estranhos."""
    for i in range(limite.LIMIAR_IP_ENVIO):
        resp = client.post(
            "/api/v1/auth/password/forgot", json={"email": f"nao-existe{i}@example.com"}
        )
        assert resp.status_code == 200, f"pedido {i}: {resp.text}"

    resp = client.post(
        "/api/v1/auth/password/forgot", json={"email": "outro@example.com"}
    )
    assert resp.status_code == 429


def test_o_limite_de_envio_nao_delata_quais_contas_existem():
    """O erro que devolveria pela porta dos fundos o oráculo que `/password/forgot`
    foi escrita para fechar.

    Se a cobrança acontecesse **depois** de achar a conta, o 429 apareceria só
    nos endereços cadastrados — e bastaria comparar as respostas para listar quem
    tem conta no Deskside. Aqui as duas respostas são iguais.
    """
    criar_conta(client, email="existe@example.com")
    # Gasta o orçamento com endereços que não existem.
    for i in range(limite.LIMIAR_IP_ENVIO):
        client.post(
            "/api/v1/auth/password/forgot", json={"email": f"fantasma{i}@example.com"}
        )

    com_conta = client.post(
        "/api/v1/auth/password/forgot", json={"email": "existe@example.com"}
    )
    sem_conta = client.post(
        "/api/v1/auth/password/forgot", json={"email": "ninguem@example.com"}
    )
    assert com_conta.status_code == sem_conta.status_code == 429
    assert com_conta.json()["detail"] == sem_conta.json()["detail"]
