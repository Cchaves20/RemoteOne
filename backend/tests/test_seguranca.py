"""Os defeitos que a revisão de segurança encontrou, virados em teste.

Cada um destes testes **falha** no código anterior à revisão. É a única forma
de saber que o conserto conserta: um teste de segurança que passaria de
qualquer jeito não vigia nada.

Ver `docs/revisao-de-seguranca.md`.
"""

import importlib

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from tests.conftest import SENHA, criar_conta

client = TestClient(app)


def _hello(device_id: str) -> dict:
    return {
        "type": "hello",
        "device_id": device_id,
        "hostname": "pc-da-vitima",
        "os": "windows",
        "agent_version": "0.1.0",
    }


def test_listagem_de_agentes_exige_login():
    """Sem token, a listagem não conta nada a ninguém.

    Era pública. Devolvia o `device_id` de todos os computadores conectados —
    e o `device_id` é a credencial do canal `/ws/agent`.
    """
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-da-vitima"))
        ws.receive_json()  # welcome
        ws.receive_json()  # pair_code

        resposta = client.get("/api/v1/agents")
        assert resposta.status_code in (401, 403), resposta.text
        assert "dev-da-vitima" not in resposta.text


def test_listagem_de_agentes_nao_mostra_computador_de_outra_conta():
    """Autenticar não basta: cada conta vê só o que é dela.

    Trocar "sem token" por "com qualquer token" moveria o problema em vez de
    resolvê-lo — bastaria criar uma conta grátis para ler os ids de todo mundo.
    """
    vitima = criar_conta(client, "vitima@example.com")["access_token"]
    bisbilhoteiro = criar_conta(client, "curioso@example.com")["access_token"]

    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-so-da-vitima"))
        ws.receive_json()
        intro = ws.receive_json()
        client.post(
            "/api/v1/pairing/claim",
            json={"code": intro["code"]},
            headers={"Authorization": f"Bearer {vitima}"},
        )

        do_dono = client.get(
            "/api/v1/agents", headers={"Authorization": f"Bearer {vitima}"}
        ).json()["agents"]
        assert any(a["device_id"] == "dev-so-da-vitima" for a in do_dono)

        do_outro = client.get(
            "/api/v1/agents", headers={"Authorization": f"Bearer {bisbilhoteiro}"}
        ).json()["agents"]
        assert do_outro == []


def test_segredo_publico_nunca_e_usado_para_assinar():
    """O padrão inseguro é recusado, e o servidor continua de pé.

    A versão anterior trazia `dev-insecure-secret-change-me` como padrão do
    `jwt_secret`. Esquecer a variável no `.env` de produção não quebrava nada
    visível — e passava a assinar tokens com uma senha escrita no repositório.
    """
    from app import config

    assert config._segredo_de_emergencia("") != ""
    assert config._segredo_de_emergencia("") != config._SEGREDO_ANTIGO
    assert config._segredo_de_emergencia(config._SEGREDO_ANTIGO) != config._SEGREDO_ANTIGO

    # Dois sorteios não coincidem: é sorteio, não uma segunda constante.
    assert config._segredo_de_emergencia("") != config._segredo_de_emergencia("")

    # E um segredo de verdade passa intacto.
    assert config._segredo_de_emergencia("um-segredo-de-verdade") == "um-segredo-de-verdade"


def test_segredo_ausente_nao_impede_o_servidor_de_subir():
    """Sortear em vez de recusar: o remédio não pode ser pior que a doença.

    Derrubar a subida por falta de variável trocaria um defeito silencioso por
    indisponibilidade total. O sorteio mantém o servidor no ar e transforma o
    esquecimento num sintoma que ninguém consegue ignorar — todo mundo cai a
    cada reinício.
    """
    modulo = importlib.import_module("app.config")
    assert modulo.settings.jwt_secret
    assert modulo.settings.jwt_secret != modulo._SEGREDO_ANTIGO


# --- S3: o canal do agente passa a exigir um segredo -------------------------


def _conectar(device_id: str, secret=...):
    """Abre `/ws/agent` e devolve o socket já com o hello mandado."""
    corpo = _hello(device_id)
    if secret is not ...:
        corpo["secret"] = secret
    ws = client.websocket_connect("/ws/agent").__enter__()
    ws.send_json(corpo)
    return ws


def _parear(device_id: str) -> tuple[str, str]:
    """Pareia um aparelho e devolve (token da conta, segredo entregue ao agente)."""
    token = criar_conta(client, f"{device_id}@example.com")["access_token"]
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json({**_hello(device_id), "secret": ""})
        ws.receive_json()  # welcome
        intro = ws.receive_json()  # pair_code
        resp = client.post(
            "/api/v1/pairing/claim",
            json={"code": intro["code"]},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 201, resp.text
        # O agente descobre o pareamento no heartbeat seguinte, e é aí que o
        # segredo chega.
        ws.send_json({"type": "heartbeat"})
        ws.receive_json()  # ack
        aviso = ws.receive_json()
        assert aviso["type"] == "paired", aviso
        assert aviso["secret"], "o segredo precisa vir junto do aviso de pareamento"
        return token, aviso["secret"]


def test_o_segredo_certo_entra_e_o_errado_nao():
    _, segredo = _parear("dev-com-segredo")

    ws = _conectar("dev-com-segredo", segredo)
    try:
        assert ws.receive_json()["type"] == "welcome"
    finally:
        ws.close()

    ws = _conectar("dev-com-segredo", "segredo-de-outra-pessoa")
    try:
        recusa = ws.receive_json()
        assert recusa["type"] == "error", recusa
    finally:
        ws.close()


def test_saber_o_device_id_deixou_de_bastar():
    """O defeito inteiro do S3, num teste.

    Antes, quem soubesse o `device_id` — do diário, de um backup, da listagem
    que era pública — abria o canal e passava a ser aquele computador.
    """
    _parear("dev-alheio")

    ws = _conectar("dev-alheio", "")
    try:
        resposta = ws.receive_json()
        assert resposta["type"] == "error", (
            f"só o device_id abriu o canal de um aparelho pareado: {resposta}"
        )
    finally:
        ws.close()


def test_agente_antigo_continua_entrando_e_nao_e_adotado():
    """Compatibilidade, e ela **não** é gentileza.

    Um agente antigo não conhece o campo `secret` e manda `None`. Emitir um
    segredo para ele o trancaria do lado de fora na reconexão seguinte: o
    computador ficaria offline para sempre, sem nada na tela explicando, e o
    dono não teria como adivinhar que precisa atualizar.
    """
    from app.db import SessionLocal
    from app.models import Device

    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-antigo"))  # sem o campo secret
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()

    token = criar_conta(client, "dono-antigo@example.com")["access_token"]
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-antigo"))
        ws.receive_json()
        intro = ws.receive_json()
        client.post(
            "/api/v1/pairing/claim",
            json={"code": intro["code"]},
            headers={"Authorization": f"Bearer {token}"},
        )

    # Pareado por um agente antigo: a linha ganha segredo (o claim sorteia),
    # mas o agente antigo continua entrando enquanto a trava estiver aberta.
    with client.websocket_connect("/ws/agent") as ws:
        ws.send_json(_hello("dev-antigo"))
        assert ws.receive_json()["type"] == "welcome"
        ws.receive_json()

    with SessionLocal() as db:
        linha = db.query(Device).filter_by(device_id="dev-antigo").one()
        assert linha.agent_secret, "o pareamento precisa sortear o segredo"


def test_a_trava_fecha_a_porta_dos_agentes_antigos():
    """Quando todos tiverem atualizado, uma variável fecha a compatibilidade."""
    from app.config import settings

    _parear("dev-trava")
    anterior = settings.exigir_segredo_do_agente
    settings.exigir_segredo_do_agente = True
    try:
        ws = _conectar("dev-trava")  # sem o campo, como um agente antigo
        try:
            assert ws.receive_json()["type"] == "error"
        finally:
            ws.close()
    finally:
        settings.exigir_segredo_do_agente = anterior


def test_quem_nao_pareou_nao_recebe_credencial_de_turn():
    """S4: o relay deixa de ser aberto.

    A credencial de TURN ia em todo `welcome`. Como o canal não autenticava,
    qualquer pessoa abria um socket com um id inventado e recebia relay válido
    por 12 horas — pago com a banda deste servidor.
    """
    ws = _conectar("dev-sem-par", "")
    try:
        welcome = ws.receive_json()
        assert welcome["type"] == "welcome"
        assert welcome["ice_servers"] == [], welcome
    finally:
        ws.close()


def test_quem_pareou_continua_recebendo_o_turn():
    """O contrapeso do teste acima, e ele é obrigatório.

    Cortar a credencial de quem não pareou só é um conserto se quem pareou
    continuar recebendo. Sem esta metade, a mesma suíte passaria com o TURN
    desligado para todo mundo — e o sintoma seria vídeo que não fecha no 4G,
    longe daqui, no celular de outra pessoa.
    """
    _, segredo = _parear("dev-com-turn")
    ws = _conectar("dev-com-turn", segredo)
    try:
        welcome = ws.receive_json()
        assert welcome["type"] == "welcome"
        assert welcome["ice_servers"], "o aparelho pareado precisa dos servidores ICE"
        assert welcome["ice_servers"][0]["urls"][0].startswith("stun:")
    finally:
        ws.close()


# --- S6: o segredo do 2FA deixa de ficar em texto puro no banco --------------


def test_o_segredo_do_2fa_nao_fica_legivel_no_banco():
    """Quem obtiver o banco não gera os códigos de ninguém.

    É o vazamento realista: a cópia diária sai da VM e vai parar num
    computador, numa nuvem, num pendrive. O `.env` com a chave não vai junto.
    """
    import pyotp

    from app import cofre
    from app.db import SessionLocal
    from app.models import User

    token = criar_conta(client, "com-2fa@example.com")["access_token"]
    cabecalho = {"Authorization": f"Bearer {token}"}
    setup = client.post("/api/v1/auth/2fa/setup", headers=cabecalho)
    assert setup.status_code == 200, setup.text
    segredo_real = setup.json()["secret"]

    with SessionLocal() as db:
        guardado = db.scalar(
            select(User.totp_secret).where(User.email == "com-2fa@example.com")
        )
    assert guardado, "o setup precisa guardar alguma coisa"
    assert segredo_real not in guardado, "o segredo do 2FA está legível no banco"
    assert cofre.esta_cifrado(guardado)
    assert cofre.abrir(guardado) == segredo_real

    # E continua funcionando de ponta a ponta: cifrar não pode quebrar o 2FA.
    ligar = client.post(
        "/api/v1/auth/2fa/enable",
        json={"code": pyotp.TOTP(segredo_real).now()},
        headers=cabecalho,
    )
    assert ligar.status_code in (200, 204), ligar.text


def test_acrescentar_uma_chave_propria_nao_tranca_quem_ja_tinha_2fa():
    """O erro que este desenho existe para evitar.

    Cifra com uma chave e depois trocá-la transforma todo segredo guardado em
    lixo — e quem usa 2FA não entra mais. Por isso a abertura tenta **todas**
    as chaves configuradas, e só a gravação usa a primeira.
    """
    from app import cofre
    from app.config import settings

    antigo = cofre.guardar("SEGREDOBASE32AAAA")

    anterior = settings.totp_key
    settings.totp_key = "uma-chave-propria-nova"
    try:
        assert cofre.abrir(antigo) == "SEGREDOBASE32AAAA", (
            "definir uma chave própria trancou quem já tinha 2FA"
        )
        # E o que se grava daqui em diante usa a chave nova.
        novo = cofre.guardar("OUTROSEGREDO")
        assert cofre.abrir(novo) == "OUTROSEGREDO"
    finally:
        settings.totp_key = anterior

    # Sem a chave nova, o que ela cifrou não abre — é o que se espera de cifra.
    assert cofre.abrir(novo) is None


def test_segredo_ilegivel_reprova_o_codigo_em_vez_de_liberar():
    """Falhar fechado.

    Se a chave se perder, o 2FA precisa **barrar**, não passar. Devolver o
    segredo vazio faria `verify_totp` reprovar; devolver "tudo bem" faria de uma
    chave perdida um contorno do segundo fator.
    """
    from app import cofre
    from app.security import verify_totp

    assert cofre.abrir(cofre.MARCA + "lixo-que-nao-decifra") is None
    assert not verify_totp(cofre.abrir(cofre.MARCA + "lixo") or "", "000000")


def test_texto_puro_de_antes_continua_sendo_lido():
    """A migração não pode ter um instante em que o 2FA de alguém para."""
    from app import cofre

    assert cofre.abrir("SEGREDOANTIGOEMTEXTOPURO") == "SEGREDOANTIGOEMTEXTOPURO"
    assert not cofre.esta_cifrado("SEGREDOANTIGOEMTEXTOPURO")
