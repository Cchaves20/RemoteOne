"""A verificação do comprovante da Apple — com uma cadeia de certificados nossa.

## Por que dá para testar isto sem conta da Apple

A verificação não faz chamada de rede: ela prova que a transação foi assinada
por uma chave cuja cadeia de certificados termina na raiz em que confiamos.
Trocar "a raiz da Apple" por "uma raiz que este arquivo acabou de gerar" muda
**só quem é a autoridade**, e não o que o código faz.

Isso permite exercitar a parte que interessa, que não é aceitar o comprovante
verdadeiro — é **recusar o falso**. Um verificador que aceita tudo passa no
teste do caminho feliz.

## O que cada recusa aqui representa no mundo

- cadeia própria: alguém gera certificados, assina o que quiser e manda;
- conteúdo trocado: comprovante legítimo com a data de validade alterada;
- `alg` trocado: o ataque clássico de quem confia no cabeçalho do JWS;
- outro aplicativo: comprovante **de verdade**, assinado pela Apple, de outro
  app — passa em toda a criptografia e ainda assim não é nosso.
"""

from __future__ import annotations

import base64
import json
from datetime import UTC, datetime, timedelta

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

from app.assinatura import Ambiente, Estado, Loja
from app.lojas import AppStore, ComprovanteInvalido

BUNDLE = "com.deskside.desksideClient"
PRODUTO = "com.deskside.pro.mensal"


# --- fabricar uma autoridade certificadora de mentira -------------------------


def _par():
    chave = ec.generate_private_key(ec.SECP256R1())
    return chave, chave.public_key()


def _certificado(
    nome: str,
    chave_publica,
    assinante_chave,
    assinante_nome: str,
    *,
    ca: bool,
    de: datetime | None = None,
    ate: datetime | None = None,
) -> x509.Certificate:
    agora = datetime.now(UTC)
    sujeito = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, nome)])
    emissor = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, assinante_nome)])
    return (
        x509.CertificateBuilder()
        .subject_name(sujeito)
        .issuer_name(emissor)
        .public_key(chave_publica)
        .serial_number(x509.random_serial_number())
        .not_valid_before(de or agora - timedelta(days=1))
        .not_valid_after(ate or agora + timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .sign(assinante_chave, hashes.SHA256())
    )


class Autoridade:
    """Uma raiz, uma intermediária e uma folha — como a cadeia da Apple."""

    def __init__(self, *, folha_de=None, folha_ate=None):
        self.raiz_chave, raiz_pub = _par()
        self.raiz = _certificado(
            "Raiz de teste", raiz_pub, self.raiz_chave, "Raiz de teste", ca=True
        )

        meio_chave, meio_pub = _par()
        self.meio = _certificado("Meio", meio_pub, self.raiz_chave, "Raiz de teste", ca=True)

        self.folha_chave, folha_pub = _par()
        self.folha = _certificado(
            "Folha", folha_pub, meio_chave, "Meio", ca=False, de=folha_de, ate=folha_ate
        )

    def x5c(self) -> list[str]:
        der = serialization.Encoding.DER
        return [
            base64.b64encode(c.public_bytes(der)).decode()
            for c in (self.folha, self.meio, self.raiz)
        ]

    def assinar(self, conteudo: dict, *, alg: str = "ES256", x5c=None) -> str:
        def b64(dados: bytes) -> str:
            return base64.urlsafe_b64encode(dados).decode().rstrip("=")

        cabecalho = {"alg": alg, "x5c": self.x5c() if x5c is None else x5c}
        parte1 = b64(json.dumps(cabecalho).encode())
        parte2 = b64(json.dumps(conteudo).encode())
        der = self.folha_chave.sign(
            f"{parte1}.{parte2}".encode(), ec.ECDSA(hashes.SHA256())
        )
        r, s = decode_dss_signature(der)
        bruta = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return f"{parte1}.{parte2}.{b64(bruta)}"


def transacao(**mudancas) -> dict:
    base = {
        "bundleId": BUNDLE,
        "productId": PRODUTO,
        "originalTransactionId": "2000000900000001",
        "environment": "Production",
        "expiresDate": int(
            (datetime.now(UTC) + timedelta(days=30)).timestamp() * 1000
        ),
    }
    base.update(mudancas)
    return {k: v for k, v in base.items() if v is not None}


@pytest.fixture
def ca():
    return Autoridade()


@pytest.fixture
def loja(ca, monkeypatch):
    monkeypatch.setattr("app.lojas.settings.apple_bundle_id", BUNDLE)
    return AppStore(ca.raiz)


# --- o caminho que precisa funcionar ------------------------------------------


def test_comprovante_legitimo_vira_assinatura_ativa(ca, loja):
    compra = loja.verificar(ca.assinar(transacao()))

    assert compra.loja is Loja.APPLE
    assert compra.product_id == PRODUTO
    assert compra.id_original == "2000000900000001"
    assert compra.estado is Estado.ATIVA
    assert compra.ambiente is Ambiente.PRODUCAO
    assert compra.expira_em is not None and compra.expira_em > datetime.now(UTC)


def test_a_data_vem_em_milissegundos(ca, loja):
    """Ler como segundos põe a validade no ano 56 mil, e a assinatura nunca
    expira. O defeito não aparece num teste que só confere "é uma data"."""
    daqui_a_dez_dias = datetime.now(UTC) + timedelta(days=10)
    compra = loja.verificar(
        ca.assinar(transacao(expiresDate=int(daqui_a_dez_dias.timestamp() * 1000)))
    )
    assert abs((compra.expira_em - daqui_a_dez_dias).total_seconds()) < 2


def test_sandbox_e_reconhecido(ca, loja):
    compra = loja.verificar(ca.assinar(transacao(environment="Sandbox")))
    assert compra.ambiente is Ambiente.SANDBOX


# --- as recusas, que são o motivo de isto existir -----------------------------


def test_cadeia_de_outra_autoridade_e_recusada(loja):
    """O ataque real: alguém gera a própria cadeia, assina o que quiser, e a
    assinatura **confere** com o certificado que veio junto. O que separa o
    verdadeiro do falso é a cadeia terminar na raiz que confiamos."""
    impostor = Autoridade()
    with pytest.raises(ComprovanteInvalido, match="raiz"):
        loja.verificar(impostor.assinar(transacao()))


def test_conteudo_trocado_depois_de_assinado(ca, loja):
    """Comprovante legítimo com a validade esticada."""
    token = ca.assinar(transacao())
    cabecalho, _, assinatura = token.split(".")
    adulterado = base64.urlsafe_b64encode(
        json.dumps(
            transacao(
                expiresDate=int(
                    (datetime.now(UTC) + timedelta(days=3650)).timestamp() * 1000
                )
            )
        ).encode()
    ).decode().rstrip("=")

    with pytest.raises(ComprovanteInvalido, match="assinatura"):
        loja.verificar(f"{cabecalho}.{adulterado}.{assinatura}")


def test_algoritmo_trocado(ca, loja):
    with pytest.raises(ComprovanteInvalido, match="algoritmo"):
        loja.verificar(ca.assinar(transacao(), alg="none"))
    with pytest.raises(ComprovanteInvalido, match="algoritmo"):
        loja.verificar(ca.assinar(transacao(), alg="HS256"))


def test_sem_cadeia_no_cabecalho(ca, loja):
    with pytest.raises(ComprovanteInvalido, match="x5c"):
        loja.verificar(ca.assinar(transacao(), x5c=[]))


def test_certificado_fora_da_validade():
    """Cadeia certa, raiz certa, assinatura certa — e o certificado da folha
    venceu ontem."""
    vencida = Autoridade(
        folha_de=datetime.now(UTC) - timedelta(days=400),
        folha_ate=datetime.now(UTC) - timedelta(days=1),
    )
    loja = AppStore(vencida.raiz)
    with pytest.raises(ComprovanteInvalido, match="validade"):
        loja.verificar(vencida.assinar(transacao()))


def test_comprovante_de_outro_aplicativo(ca, loja):
    """Este é assinado pela Apple de verdade e passa em toda a criptografia.
    Só não é nosso."""
    with pytest.raises(ComprovanteInvalido, match="aplicativo"):
        loja.verificar(ca.assinar(transacao(bundleId="com.outra.empresa")))


def test_lixo_no_lugar_do_comprovante(loja):
    for entrada in ["", "nada", "a.b", "a.b.c.d", "...."]:
        with pytest.raises(ComprovanteInvalido):
            loja.verificar(entrada)


# --- o que decide o plano -----------------------------------------------------


def test_reembolso_vence_a_data(ca, loja):
    """Uma assinatura reembolsada pode ter validade no futuro. Tratá-la como
    ativa daria plano pago a quem pediu o dinheiro de volta."""
    compra = loja.verificar(
        ca.assinar(
            transacao(
                revocationDate=int(datetime.now(UTC).timestamp() * 1000),
                expiresDate=int(
                    (datetime.now(UTC) + timedelta(days=25)).timestamp() * 1000
                ),
            )
        )
    )
    assert compra.estado is Estado.REVOGADA


def test_validade_no_passado_e_expirada(ca, loja):
    compra = loja.verificar(
        ca.assinar(
            transacao(
                expiresDate=int(
                    (datetime.now(UTC) - timedelta(days=1)).timestamp() * 1000
                )
            )
        )
    )
    assert compra.estado is Estado.EXPIRADA


def test_sem_data_de_validade_nao_e_ativa(ca, loja):
    compra = loja.verificar(ca.assinar(transacao(expiresDate=None)))
    assert compra.estado is Estado.EXPIRADA


# --- notificações da Apple ----------------------------------------------------


def _notificacao(
    ca: Autoridade, tipo: str, subtipo: str | None = None, **mudancas
) -> bytes:
    dentro = ca.assinar(transacao(**mudancas))
    aviso = {"notificationType": tipo, "data": {"signedTransactionInfo": dentro}}
    if subtipo is not None:
        aviso["subtype"] = subtipo
    fora = ca.assinar(aviso)
    return json.dumps({"signedPayload": fora}).encode()


def test_notificacao_confere_os_dois_jws(ca, loja):
    compra = loja.verificar(ca.assinar(transacao()))
    aviso = loja.ler_notificacao(_notificacao(ca, "DID_RENEW"))
    assert aviso.id_original == compra.id_original
    assert aviso.estado is Estado.ATIVA


def test_notificacao_de_reembolso_revoga(ca, loja):
    aviso = loja.ler_notificacao(_notificacao(ca, "REFUND"))
    assert aviso.estado is Estado.REVOGADA


def test_falha_de_cobranca_nao_e_expirada_nem_ativa(ca, loja):
    """`DID_FAIL_TO_RENEW` é o estado que a transação não sabe expressar: a
    Apple ainda está tentando cobrar. Não é expirada (pode voltar sozinha) nem
    ativa (não pagou)."""
    aviso = loja.ler_notificacao(_notificacao(ca, "DID_FAIL_TO_RENEW"))
    assert aviso.estado is Estado.EM_ATRASO


def test_desligar_a_renovacao_marca_cancelada(ca, loja):
    """O único jeito de o servidor saber que alguém cancelou.

    A transação não muda: a pessoa pagou o mês e ele vale até o fim. Quem
    carrega a informação é o **subtipo** do aviso. Sem ele, o app diria "faltam
    22 dias para a próxima cobrança" a quem acabou de pedir para não ser
    cobrado, e só descobriria o engano quando a assinatura expirasse.
    """
    aviso = loja.ler_notificacao(
        _notificacao(ca, "DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED")
    )
    assert aviso.estado is Estado.CANCELADA


def test_cancelar_nao_corta_o_acesso_ja_pago(ca, loja):
    """Cancelada **não** é expirada: a validade continua no futuro.

    Cortar na hora do cancelamento é cobrar por um mês e não entregar — e a
    Apple devolve o dinheiro de quem reclama disso.
    """
    aviso = loja.ler_notificacao(
        _notificacao(ca, "DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED")
    )
    assert aviso.expira_em is not None
    assert aviso.expira_em > datetime.now(UTC)


def test_religar_a_renovacao_volta_a_ativa(ca, loja):
    aviso = loja.ler_notificacao(
        _notificacao(ca, "DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED")
    )
    assert aviso.estado is Estado.ATIVA


def test_mudanca_de_renovacao_sem_subtipo_nao_inventa_estado(ca, loja):
    """O aviso sozinho não diz nada: ele vem tanto para ligar quanto desligar.

    Sem subtipo reconhecido, o certo é não mexer no que a transação disse —
    chutar "cancelada" cortaria a cobrança de quem não pediu nada.
    """
    aviso = loja.ler_notificacao(_notificacao(ca, "DID_CHANGE_RENEWAL_STATUS"))
    assert aviso.estado is Estado.ATIVA


def test_subtipo_desconhecido_nao_derruba_nem_inventa(ca, loja):
    """A Apple acrescenta subtipos. Um que não conhecemos vale como nenhum."""
    aviso = loja.ler_notificacao(
        _notificacao(ca, "DID_CHANGE_RENEWAL_STATUS", "ALGO_QUE_NAO_EXISTE_AINDA")
    )
    assert aviso.estado is Estado.ATIVA


def test_subtipo_nao_atrapalha_o_aviso_que_decide_pelo_tipo(ca, loja):
    """`REFUND` continua revogando, com ou sem subtipo junto."""
    aviso = loja.ler_notificacao(_notificacao(ca, "REFUND", "QUALQUER_COISA"))
    assert aviso.estado is Estado.REVOGADA


def test_transacao_interna_de_outra_autoridade(ca, loja):
    """O envelope de fora vem certo e o de dentro é forjado. Verificar só o
    externo deixaria entrar a transação, que é o que decide o plano."""
    impostor = Autoridade()
    dentro = impostor.assinar(transacao())
    fora = ca.assinar({"notificationType": "DID_RENEW", "data": {"signedTransactionInfo": dentro}})
    corpo = json.dumps({"signedPayload": fora}).encode()

    with pytest.raises(ComprovanteInvalido, match="raiz"):
        loja.ler_notificacao(corpo)


def test_notificacao_malformada(loja):
    for corpo in [b"", b"{", b"{}", json.dumps({"signedPayload": ""}).encode()]:
        with pytest.raises(ComprovanteInvalido):
            loja.ler_notificacao(corpo)


# --- sem raiz configurada, nada é aceito --------------------------------------


def test_sem_certificado_raiz_o_verificador_nem_e_escolhido(monkeypatch):
    """Falhar fechado: sem raiz não há verificação possível, e verificação
    impossível não pode virar "aceita"."""
    from app import lojas

    monkeypatch.setattr("app.lojas.settings.apple_root_ca", "")
    assert lojas.configurado()["apple"] is False
    assert isinstance(lojas.verificador_de(Loja.APPLE), lojas.DeMentira)


def test_caminho_de_raiz_que_nao_existe(monkeypatch):
    from app import lojas

    monkeypatch.setattr("app.lojas.settings.apple_root_ca", "/nao/existe.cer")
    assert lojas.configurado()["apple"] is False
