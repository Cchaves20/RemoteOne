"""Como o código de verificação chega até a pessoa: e-mail e SMS.

Uma interface e três implementações, e a razão de existir a interface é
concreta: **enviar de verdade custa um provedor**, com conta, credencial e — no
caso do SMS — dinheiro por mensagem. Sem a interface, o cadastro inteiro ficaria
parado esperando isso.

Com ela, o cadastro funciona hoje: sem credencial configurada, o código vai para
o **diário do servidor**. Não é um placebo — é o modo em que se testa o fluxo
inteiro (validação, expiração, tentativas, criação da conta) antes de gastar o
primeiro centavo. E deixa de valer no instante em que as credenciais aparecerem
no `.env`, sem uma linha de código mudar.

**O que este módulo deliberadamente não faz:** nada assíncrono, nada de fila,
nada de repetição automática. Um envio que falha vira erro para quem pediu, e a
pessoa toca em "reenviar". Uma fila de reenvio é a coisa certa quando houver
volume; hoje seria maquinário para um problema que ainda não existe.

## Configurar em produção

E-mail, por SMTP — serve para Gmail com senha de app, Resend, Brevo, qualquer um:

```
DESKSIDE_SMTP_HOST=smtp.resend.com
DESKSIDE_SMTP_PORT=587
DESKSIDE_SMTP_USER=resend
DESKSIDE_SMTP_PASSWORD=...
DESKSIDE_SMTP_FROM=Deskside <conta@seu-dominio>
```

SMS, pela API da Twilio (sem SDK: é um POST de formulário):

```
DESKSIDE_TWILIO_SID=AC...
DESKSIDE_TWILIO_TOKEN=...
DESKSIDE_TWILIO_FROM=+15551234567
```
"""

import base64
import smtplib
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage

from app.config import settings


class EntregaError(Exception):
    """O provedor recusou ou não respondeu.

    Vira 502 para quem pediu, e não 500: a falha é de um serviço de fora, e a
    diferença importa para quem lê o log seis meses depois.
    """


class Entregador:
    """Manda o código. Uma implementação por caminho de chegada."""

    def email(self, destino: str, codigo: str) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def sms(self, destino: str, codigo: str) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def aviso(  # pragma: no cover - interface
        self, destino: str, assunto: str, corpo: str
    ) -> None:
        """Um e-mail que não é código de verificação.

        Separado do `email` de propósito. Aquele tem um contrato estreito — um
        código, um assunto fixo, dez minutos de validade — e alargá-lo para
        caber qualquer mensagem faria o caminho mais sensível do sistema aceitar
        texto arbitrário. São dois usos, e usos diferentes merecem portas
        diferentes.
        """
        raise NotImplementedError


class NoDiario(Entregador):
    """O modo de teste: o código vai para a saída do servidor.

    Existe para o fluxo inteiro poder ser exercitado sem provedor nenhum, e é
    **só** isso: qualquer pessoa com acesso ao log vê o código. Por isso o
    `/health` denuncia quando o servidor está neste modo — um servidor que
    aceita cadastros assim, sem ninguém perceber, seria pior do que um que não
    aceita cadastro nenhum.
    """

    def email(self, destino: str, codigo: str) -> None:
        print(f"[verificação] e-mail para {destino}: {codigo}")

    def sms(self, destino: str, codigo: str) -> None:
        print(f"[verificação] SMS para {destino}: {codigo}")

    def aviso(self, destino: str, assunto: str, corpo: str) -> None:
        print(f"[aviso] e-mail para {destino}: {assunto}")


class PorSmtp(Entregador):
    """E-mail por SMTP. Provedor-agnóstico de propósito."""

    #: Curto porque quem está cadastrando está esperando na tela. Um servidor de
    #: e-mail que demora quinze segundos já falhou para este uso.
    TIMEOUT = 15

    def email(self, destino: str, codigo: str) -> None:
        msg = EmailMessage()
        msg["Subject"] = f"{codigo} é o seu código do Deskside"
        msg["From"] = settings.smtp_from or settings.smtp_user
        msg["To"] = destino
        msg.set_content(
            f"Seu código de verificação é {codigo}.\n\n"
            "Ele vale por 10 minutos e serve para uma coisa só: terminar de "
            "criar a sua conta no Deskside.\n\n"
            "Se não foi você quem pediu, ignore esta mensagem — nenhuma conta "
            "foi criada."
        )
        try:
            with smtplib.SMTP(
                settings.smtp_host, settings.smtp_port, timeout=self.TIMEOUT
            ) as servidor:
                servidor.starttls()
                if settings.smtp_user:
                    servidor.login(settings.smtp_user, settings.smtp_password)
                servidor.send_message(msg)
        except (OSError, smtplib.SMTPException) as exc:
            raise EntregaError(f"não consegui enviar o e-mail: {exc}") from exc

    def aviso(self, destino: str, assunto: str, corpo: str) -> None:
        msg = EmailMessage()
        msg["Subject"] = assunto
        msg["From"] = settings.smtp_from or settings.smtp_user
        msg["To"] = destino
        msg.set_content(corpo)
        try:
            with smtplib.SMTP(
                settings.smtp_host, settings.smtp_port, timeout=self.TIMEOUT
            ) as servidor:
                servidor.starttls()
                if settings.smtp_user:
                    servidor.login(settings.smtp_user, settings.smtp_password)
                servidor.send_message(msg)
        except (OSError, smtplib.SMTPException) as exc:
            raise EntregaError(f"não consegui enviar o aviso: {exc}") from exc


class PorTwilio(Entregador):
    """SMS pela API da Twilio, com `urllib` em vez do SDK.

    O SDK traria uma dependência inteira para fazer um POST de formulário
    autenticado. A API de mensagens da Twilio é essa única chamada, e ela não
    muda — o que se ganharia em conveniência se pagaria em superfície.
    """

    TIMEOUT = 15
    URL = "https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json"

    def sms(self, destino: str, codigo: str) -> None:
        dados = urllib.parse.urlencode(
            {
                "To": destino,
                "From": settings.twilio_from,
                "Body": (
                    f"{codigo} é o seu código do Deskside. "
                    "Vale por 10 minutos. Se não foi você, ignore."
                ),
            }
        ).encode()
        pedido = urllib.request.Request(
            self.URL.format(sid=settings.twilio_sid), data=dados
        )
        credencial = base64.b64encode(
            f"{settings.twilio_sid}:{settings.twilio_token}".encode()
        ).decode()
        pedido.add_header("Authorization", f"Basic {credencial}")
        try:
            with urllib.request.urlopen(pedido, timeout=self.TIMEOUT) as resposta:
                resposta.read()
        except urllib.error.HTTPError as exc:
            # O corpo do erro da Twilio diz o motivo ("número não verificado",
            # "sem saldo"). Perdê-lo transformaria toda falha em "deu erro".
            corpo = exc.read().decode("utf-8", "replace")[:300]
            raise EntregaError(f"a operadora recusou ({exc.code}): {corpo}") from exc
        except OSError as exc:
            raise EntregaError(f"não consegui falar com a operadora: {exc}") from exc


class Composto(Entregador):
    """Um caminho para o e-mail, outro para o SMS.

    Os dois se configuram separadamente, e o objeto reflete isso. Um servidor
    com SMTP pronto e Twilio ainda não contratado continua aceitando cadastro
    por telefone — com o código indo para o diário — em vez de recusar metade
    do formulário por causa de uma credencial que falta.
    """

    def __init__(self, por_email: Entregador, por_sms: Entregador) -> None:
        self._email = por_email
        self._sms = por_sms

    def email(self, destino: str, codigo: str) -> None:
        self._email.email(destino, codigo)

    def sms(self, destino: str, codigo: str) -> None:
        self._sms.sms(destino, codigo)


def _escolher() -> Entregador:
    diario = NoDiario()
    tem_twilio = bool(
        settings.twilio_sid and settings.twilio_token and settings.twilio_from
    )
    return Composto(
        PorSmtp() if settings.smtp_host else diario,
        PorTwilio() if tem_twilio else diario,
    )


#: O entregador em uso. Trocável nos testes.
entregador: Entregador = _escolher()


def configurado() -> dict[str, bool]:
    """Quais caminhos entregam de verdade. Vai no `/health`.

    Sem isto, "o código não chegou" começaria por dedução: o servidor no ar
    pode ser mais antigo que o `.env`, o `.env` pode ter um nome de variável
    errado, e nada disso aparece de fora. Aqui aparece.
    """
    return {
        "email": bool(settings.smtp_host),
        "sms": bool(
            settings.twilio_sid and settings.twilio_token and settings.twilio_from
        ),
    }
