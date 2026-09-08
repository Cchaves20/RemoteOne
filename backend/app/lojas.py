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

import logging
from datetime import UTC, datetime, timedelta

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
    """

    def __init__(self) -> None:
        self._bundle = settings.apple_bundle_id

    def verificar(self, comprovante: str) -> Compra:
        raise NotImplementedError(
            "a integração com a App Store Server API entra quando a conta Apple "
            "Developer existir; até lá o servidor roda com DeMentira e não "
            "distribui plano pago (ver o docstring deste módulo)"
        )

    def ler_notificacao(self, corpo: bytes) -> Compra:
        raise NotImplementedError(
            "App Store Server Notifications V2: conferir a cadeia x5c até a raiz "
            "da Apple antes de ler qualquer campo"
        )


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
    if loja is Loja.APPLE and settings.apple_key_id and settings.apple_issuer_id:
        return AppStore()
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
        "apple": bool(settings.apple_key_id and settings.apple_issuer_id),
        "google": bool(settings.google_service_account),
    }
