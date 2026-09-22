"""Perguntar à Apple e ao Google se uma compra é verdadeira.

Uma interface e três implementações, pelo mesmo motivo do `app/entrega.py`:
falar com as lojas de verdade custa uma conta paga, um contrato assinado e uma
chave privada. Sem a interface, o fluxo inteiro de assinatura ficaria parado
esperando os US$ 99 da Apple.

Com ela, tudo o que **não** é a chamada de rede — vincular a compra a uma conta,
recusar sandbox, revogar por reembolso, descartar notificação repetida — é
escrito e testado hoje, e a troca para a loja de verdade não muda uma linha
fora deste arquivo.

## A regra que não se negocia

**O aplicativo nunca decide se pagou.** Ele manda um comprovante opaco; quem
responde o que aquilo é vale é a loja. Todo caminho deste módulo termina numa
resposta da Apple ou do Google, ou numa recusa.

O motivo é que o aplicativo roda no aparelho de outra pessoa: um `POST` dizendo
`{"pago": true}` é trivial de forjar, e um servidor que acredite nisso não tem
plano pago — tem plano opcional.

## Configurar em produção

Apple (App Store Server API). A chave `.p8` é gerada no App Store Connect em
*Users and Access → Integrations → In-App Purchase*:

```
DESKSIDE_APPLE_ISSUER_ID=...
DESKSIDE_APPLE_KEY_ID=...
DESKSIDE_APPLE_KEY_P8=/run/secrets/apple.p8
DESKSIDE_APPLE_BUNDLE_ID=com.deskside.client
```

Google (Play Developer API), com uma conta de serviço com acesso ao app:

```
DESKSIDE_GOOGLE_PACKAGE=com.deskside.client
DESKSIDE_GOOGLE_SERVICE_ACCOUNT=/run/secrets/google.json
```

Nenhum destes vai para o repositório, e os dois arquivos ficam fora do backup —
são credenciais de cobrança, e valem tanto quanto o `DESKSIDE_JWT_SECRET`.
"""

from __future__ import annotations

import json
import logging
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

from cryptography import x509

from app import jws
from app.assinatura import Ambiente, Compra, Estado, Loja
from app.config import settings

logger = logging.getLogger("deskside")


class LojaError(Exception):
    """A loja recusou o comprovante, ou não deu para perguntar.

    Vira 402 quando o comprovante é inválido e 502 quando a loja não respondeu —
    e a diferença importa: no primeiro caso não adianta tentar de novo, no
    segundo adianta.
    """


class ComprovanteInvalido(LojaError):
    """A loja respondeu, e a resposta foi "isto não existe" ou "isto não é seu"."""


class Verificador:
    """Pergunta à loja o que é um comprovante. Uma implementação por loja."""

    def verificar(self, comprovante: str) -> Compra:  # pragma: no cover - interface
        raise NotImplementedError

    def ler_notificacao(self, corpo: bytes) -> Compra:  # pragma: no cover - interface
        """Lê uma notificação da loja, **conferindo a assinatura dela**.

        Separado do `verificar` porque a origem é outra: ali quem fala é o nosso
        aplicativo, autenticado pelo token da conta; aqui quem fala é um `POST`
        de qualquer lugar da internet, para um endereço que não pede senha. A
        única coisa que distingue a loja de um impostor é a assinatura
        criptográfica do corpo — e é por isso que ela é conferida **aqui**, e
        não em quem chama.
        """
        raise NotImplementedError


class DeMentira(Verificador):
    """O modo de desenvolvimento: qualquer comprovante vira uma compra de teste.

    Existe para o fluxo inteiro ser exercitado sem conta de loja — e é **só**
    isso. Repare no ambiente: toda compra que sai daqui é `SANDBOX`, e sandbox
    não vale como pago a menos que alguém ligue `DESKSIDE_ACEITAR_SANDBOX`
    explicitamente.

    Isso é deliberado e é a peça de segurança do arquivo: um servidor que suba
    em produção sem credencial de loja **não distribui plano pago de graça** —
    ele recusa tudo. O `/health` denuncia o modo, como já denuncia o de entrega.
    """

    #: Trinta dias, para o teste manual parecer uma assinatura mensal de
    #: verdade em vez de expirar antes de alguém conseguir olhar.
    DIAS = 30

    def verificar(self, comprovante: str) -> Compra:
        if not comprovante:
            raise ComprovanteInvalido("comprovante vazio")
        agora = datetime.now(UTC)
        return Compra(
            loja=Loja.APPLE,
            id_original=f"teste-{comprovante[:32]}",
            product_id=next(iter(_produtos_conhecidos())),
            estado=Estado.ATIVA,
            ambiente=Ambiente.SANDBOX,
            expira_em=agora + timedelta(days=self.DIAS),
            visto_em=agora,
        )

    def ler_notificacao(self, corpo: bytes) -> Compra:
        raise ComprovanteInvalido(
            "sem credencial de loja configurada, nenhuma notificação é aceita"
        )


def _produtos_conhecidos() -> frozenset[str]:
    from app.assinatura import PRODUTOS_PAGOS

    return PRODUTOS_PAGOS


class AppStore(Verificador):
    """App Store Server API (StoreKit 2).

    A Apple assina cada transação como um JWS. Verificar significa conferir a
    cadeia de certificados até a raiz da Apple — **não** apenas decodificar o
    conteúdo. Decodificar sem verificar é o erro clássico desta integração: a
    parte central de um JWS é base64 comum, lê-se sem chave nenhuma, e um
    comprovante forjado passa por qualquer leitura que se contente com isso.

    A criptografia mora em `app/jws.py`, sem rede e sem configuração, para
    poder ser exercitada com uma cadeia fabricada nos testes.

    **Não há chamada de rede aqui, e é de propósito.** A transação assinada já
    carrega tudo o que decide o plano — produto, validade, reembolso, ambiente
    — e a assinatura prova a origem. Consultar a App Store Server API traria um
    ponto de falha externo no caminho de quem acabou de pagar, para confirmar
    algo que a própria Apple já assinou.
    """

    def __init__(self, raiz: object | None = None) -> None:
        self._bundle = settings.apple_bundle_id
        self._raiz = raiz if raiz is not None else _raiz_da_apple()

    def _compra_de(self, transacao: dict) -> Compra:
        """Traduz uma transação assinada da Apple para o nosso vocabulário."""
        bundle = transacao.get("bundleId")
        if self._bundle and bundle != self._bundle:
            # Um comprovante legítimo **de outro aplicativo** é assinado pela
            # Apple e passa em toda a verificação criptográfica. O que o separa
            # do nosso é este campo.
            raise ComprovanteInvalido(
                f"comprovante é do aplicativo {bundle!r}, não do nosso"
            )

        produto = transacao.get("productId")
        if not produto:
            raise ComprovanteInvalido("transação sem productId")

        original = transacao.get("originalTransactionId")
        if not original:
            raise ComprovanteInvalido("transação sem originalTransactionId")

        ambiente = (
            Ambiente.PRODUCAO
            if str(transacao.get("environment", "")).lower() == "production"
            else Ambiente.SANDBOX
        )

        expira = _instante(transacao.get("expiresDate"))
        revogada = _instante(transacao.get("revocationDate"))
        agora = datetime.now(UTC)

        # A ordem importa: reembolso vence data. Uma assinatura reembolsada
        # pode ter `expiresDate` no futuro, e tratá-la como ativa daria plano
        # pago a quem pediu o dinheiro de volta.
        if revogada is not None:
            estado = Estado.REVOGADA
        elif expira is None or expira <= agora:
            estado = Estado.EXPIRADA
        else:
            estado = Estado.ATIVA

        return Compra(
            loja=Loja.APPLE,
            id_original=str(original),
            product_id=str(produto),
            estado=estado,
            ambiente=ambiente,
            expira_em=expira,
            visto_em=agora,
        )

    def verificar(self, comprovante: str) -> Compra:
        if not comprovante:
            raise ComprovanteInvalido("comprovante vazio")
        try:
            transacao = jws.verificar_jws(comprovante, self._raiz)
        except jws.JwsInvalido as e:
            raise ComprovanteInvalido(str(e)) from e
        return self._compra_de(transacao)

    def ler_notificacao(self, corpo: bytes) -> Compra:
        """App Store Server Notifications V2.

        São **dois** JWS, um dentro do outro: o corpo traz `signedPayload`, e
        dentro dele vem `data.signedTransactionInfo`. Os dois são conferidos —
        verificar só o de fora deixaria a transação, que é o que decide o
        plano, entrando sem prova.
        """
        try:
            envelope = json.loads(corpo)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            raise ComprovanteInvalido(f"notificação não é JSON: {e}") from e

        assinado = envelope.get("signedPayload")
        if not assinado:
            raise ComprovanteInvalido("notificação sem signedPayload")

        try:
            aviso = jws.verificar_jws(str(assinado), self._raiz)
            dados = aviso.get("data") or {}
            transacao_assinada = dados.get("signedTransactionInfo")
            if not transacao_assinada:
                raise ComprovanteInvalido("notificação sem signedTransactionInfo")
            transacao = jws.verificar_jws(str(transacao_assinada), self._raiz)
        except jws.JwsInvalido as e:
            raise ComprovanteInvalido(str(e)) from e

        compra = self._compra_de(transacao)
        return _com_estado_do_aviso(compra, aviso)


#: O que cada aviso da Apple diz sobre o estado, quando ele sabe mais que a
#: transação. Fora desta tabela, vale o que a transação disse.
#:
#: `DID_FAIL_TO_RENEW` é o caso que a transação não tem como expressar: a
#: assinatura não foi renovada por problema de cobrança e a Apple ainda está
#: tentando. Não é expirada (pode voltar sozinha) nem ativa (não pagou).
_ESTADO_POR_AVISO = {
    "REFUND": Estado.REVOGADA,
    "REVOKE": Estado.REVOGADA,
    "EXPIRED": Estado.EXPIRADA,
    "DID_FAIL_TO_RENEW": Estado.EM_ATRASO,
    "GRACE_PERIOD_EXPIRED": Estado.EXPIRADA,
}

#: Avisos em que o **subtipo** é quem carrega a informação.
#:
#: `DID_CHANGE_RENEWAL_STATUS` sozinho não diz nada: ele é mandado tanto quando
#: a pessoa desliga a renovação quanto quando religa. O que distingue os dois é
#: o subtipo, e sem ele o aviso teria de ser ignorado.
#:
#: Este é o único jeito de o servidor saber que alguém cancelou. A transação
#: continua idêntica — a pessoa pagou o mês e ele vale até o fim —, então nada
#: no comprovante muda. Sem esta linha, o app diria "faltam 22 dias para a
#: próxima cobrança" a quem acabou de pedir para não ser cobrado, até a
#: assinatura expirar de verdade.
_ESTADO_POR_SUBTIPO = {
    ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED"): Estado.CANCELADA,
    ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED"): Estado.ATIVA,
}


def _com_estado_do_aviso(compra: Compra, aviso: dict) -> Compra:
    tipo = str(aviso.get("notificationType", ""))
    subtipo = str(aviso.get("subtype", ""))
    # O subtipo primeiro: ele é mais específico, e quando existe uma regra para
    # o par, ela sabe mais que a do tipo sozinho.
    estado = _ESTADO_POR_SUBTIPO.get((tipo, subtipo)) or _ESTADO_POR_AVISO.get(tipo)
    if estado is None or estado is compra.estado:
        return compra
    return replace(compra, estado=estado)


def _instante(milissegundos: object) -> datetime | None:
    """Data da Apple (milissegundos desde 1970, UTC) para `datetime`.

    Milissegundos, e não segundos: tratar como segundos põe a validade no ano
    de 56 mil, e a assinatura nunca expira. O erro não aparece em teste que só
    olha "é uma data".
    """
    if milissegundos is None:
        return None
    try:
        return datetime.fromtimestamp(int(milissegundos) / 1000, tz=UTC)
    except (TypeError, ValueError, OSError, OverflowError):
        return None


def _raiz_da_apple():
    """Carrega o certificado raiz do caminho configurado.

    Devolve `None` quando não há caminho ou o arquivo não abre — e aí
    `_escolher` não usa o `AppStore`. Falhar fechado: sem raiz não há
    verificação possível, e verificação impossível não pode virar "aceita".
    """
    caminho = settings.apple_root_ca
    if not caminho:
        return None
    try:
        dados = Path(caminho).read_bytes()
    except OSError as e:
        logger.error("não consegui ler o certificado raiz da Apple em %s: %s", caminho, e)
        return None
    try:
        if b"-----BEGIN CERTIFICATE-----" in dados:
            return x509.load_pem_x509_certificate(dados)
        return x509.load_der_x509_certificate(dados)
    except ValueError as e:
        logger.error("o arquivo em %s não é um certificado: %s", caminho, e)
        return None


class PlayStore(Verificador):
    """Google Play Developer API (`purchases.subscriptionsv2.get`).

    O comprovante do Android é o *purchase token*, e ele é credencial: quem o
    tem consulta a assinatura. Por isso ele nunca é gravado — o banco guarda o
    resumo (ver `models.Assinatura`), e as notificações trazem o token de novo
    quando ele é necessário.
    """

    def __init__(self) -> None:
        self._package = settings.google_package

    def verificar(self, comprovante: str) -> Compra:
        raise NotImplementedError(
            "a integração com a Play Developer API entra quando a conta do Play "
            "Console existir"
        )

    def ler_notificacao(self, corpo: bytes) -> Compra:
        raise NotImplementedError(
            "Real-time developer notifications chegam por Pub/Sub; conferir o "
            "token OIDC do push antes de ler o corpo"
        )


def _escolher(loja: Loja) -> Verificador:
    # A condição mudou junto com a implementação, e vale dizer por quê: ela
    # pedia `apple_key_id` e `apple_issuer_id`, que são credenciais para
    # **chamar** a App Store Server API. A verificação não chama ninguém —
    # confere a assinatura da transação contra o certificado raiz. Então o que
    # decide se dá para verificar é ter a raiz, e não ter credencial de API.
    if loja is Loja.APPLE:
        raiz = _raiz_da_apple()
        if raiz is not None:
            return AppStore(raiz)
    if loja is Loja.GOOGLE and settings.google_service_account:
        return PlayStore()
    return DeMentira()


def verificador_de(loja: Loja) -> Verificador:
    """O verificador em uso para uma loja. Trocável nos testes."""
    return _escolher(loja)


def configurado() -> dict[str, bool]:
    """Quais lojas verificam de verdade. Vai no `/health`.

    Pelo mesmo motivo do `entrega.configurado()`: sem isto, "a assinatura não
    ativou" começaria por dedução. O servidor no ar pode ser mais antigo que o
    `.env`, o nome da variável pode estar errado, e nada disso aparece de fora.
    """
    return {
        "apple": _raiz_da_apple() is not None,
        "google": bool(settings.google_service_account),
    }
