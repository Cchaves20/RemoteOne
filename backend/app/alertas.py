"""Avisos de segurança: contar ao dono o que aconteceu na conta dele.

Num produto que controla computadores, o pior cenário não é alguém entrar na
conta — é alguém entrar e **ninguém perceber**. Cada evento abaixo é um passo
que um invasor daria, e a mensagem chega ao contato da conta com o que fazer se
não foi a própria pessoa:

- um login novo;
- um computador novo pareado (a partir daí ele pode ser controlado);
- a senha trocada ou redefinida;
- a verificação em duas etapas ligada ou desligada, códigos de recuperação
  novos ou usados;
- o contato trocado — e esse aviso vai para o contato **antigo**, que é o único
  que o dono legítimo ainda lê se foi ele quem perdeu a conta;
- uma sessão encerrada porque o acesso dela foi copiado (ver `app/sessoes.py`).

## Nunca atrapalha o pedido

O envio roda depois da resposta (`BackgroundTasks` do FastAPI) e engole as
próprias falhas: um provedor de e-mail fora do ar não pode impedir ninguém de
entrar na própria conta. A falha vai para o diário.

## Por que não um link "não fui eu"

Um link que desconecta tudo com um clique seria o mais cômodo — e é exatamente
o que os antivírus de e-mail abrem sozinhos para inspecionar, desconectando a
pessoa sem ela ter clicado. A saída indicada é redefinir a senha, que já derruba
todas as sessões e, com a verificação ligada, exige o segundo fator.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone

from app import entrega
from app.config import settings
from app.models import User

logger = logging.getLogger("deskside")

#: Horário de Brasília. Fixo em -3: o Brasil não tem horário de verão desde
#: 2019, e um fuso fixo dispensa o banco de fusos horários na imagem do servidor.
_BRASILIA = timezone(timedelta(hours=-3))

_SE_NAO_FOI_VOCE = (
    "Se não foi você, alguém pode ter a sua senha. No app, toque em Entrar › "
    "Esqueci a senha e crie uma nova: isso desconecta todos os aparelhos na "
    "hora. Depois, ligue a verificação em duas etapas em Configurações."
)


@dataclass(frozen=True)
class Alerta:
    destino: str
    canal: str  # "email" ou "sms"
    assunto: str
    corpo: str
    #: A versão curta, para SMS: cabe em uma ou duas mensagens.
    curto: str


def _quando(agora: datetime | None) -> str:
    agora = (agora or datetime.now(UTC)).astimezone(_BRASILIA)
    return agora.strftime("%d/%m/%Y às %H:%M")


def _ola(user: User) -> str:
    return f"Olá, {user.first_name}." if user.first_name else "Olá."


def mascarar(contato: str) -> str:
    """O contato reconhecível por quem é dono dele, e inútil para os outros.

    `caio@gmail.com` → `c***@gmail.com`; `+5511987654321` → `+55 •••• 4321`.
    Vai no aviso de troca de contato, que sai para o endereço **antigo**: se a
    troca foi de um invasor, o endereço novo é dele, e escrevê-lo inteiro num
    e-mail é um dado a mais circulando.
    """
    if "@" in contato:
        nome, dominio = contato.split("@", 1)
        return f"{nome[:1]}***@{dominio}"
    if len(contato) > 6:
        return f"{contato[:3]} •••• {contato[-4:]}"
    return "••••"


def para(user: User) -> tuple[str, str] | None:
    """Por onde avisar esta conta: o e-mail se houver, senão o telefone."""
    if user.email:
        return user.email, "email"
    if user.phone:
        return user.phone, "sms"
    return None


def montar(
    user: User,
    evento: str,
    *,
    ip: str | None = None,
    detalhe: str = "",
    destino: tuple[str, str] | None = None,
    agora: datetime | None = None,
) -> Alerta | None:
    """O aviso de `evento` para esta conta, ou `None` se não há por onde avisar.

    `destino` troca para onde vai (a troca de contato avisa o antigo).
    """
    alvo = destino or para(user)
    if alvo is None:
        return None
    quando = _quando(agora)
    de_onde = f", a partir do endereço {ip}" if ip else ""

    if evento == "login":
        assunto = "Novo acesso à sua conta Deskside"
        pelo = f" pelo aparelho \"{detalhe}\"" if detalhe else ""
        texto = (
            f"Sua conta Deskside foi acessada{pelo} em {quando} (horário de Brasília)"
            f"{de_onde}.\n\nSe foi você, não precisa fazer nada.\n\n{_SE_NAO_FOI_VOCE}"
        )
        curto = (
            f"Deskside: novo acesso à sua conta em {quando}. Não foi você? Redefina "
            "a senha no app (Esqueci a senha) para desconectar todos."
        )
    elif evento == "computador":
        assunto = "Computador novo na sua conta Deskside"
        texto = (
            f"O computador \"{detalhe}\" foi adicionado à sua conta em {quando} "
            "(horário de Brasília) e já pode ser controlado por ela.\n\n"
            "Se não foi você, remova-o no app (Computadores › ⋮ › Remover) e "
            f"redefina a senha.\n\n{_SE_NAO_FOI_VOCE}"
        )
        curto = (
            f"Deskside: o computador \"{detalhe}\" entrou na sua conta em {quando}. "
            "Não foi você? Remova-o no app e redefina a senha."
        )
    elif evento in ("senha_trocada", "senha_redefinida"):
        como = "trocada" if evento == "senha_trocada" else "redefinida (Esqueci a senha)"
        assunto = "A senha da sua conta Deskside mudou"
        texto = (
            f"A senha da sua conta Deskside foi {como} em {quando} (horário de "
            f"Brasília){de_onde}. Os outros aparelhos conectados foram "
            f"desconectados.\n\n{_SE_NAO_FOI_VOCE}"
        )
        curto = (
            f"Deskside: a senha da sua conta mudou em {quando}. Não foi você? "
            "Redefina-a no app (Esqueci a senha)."
        )
    elif evento == "2fa_ligado":
        assunto = "Verificação em duas etapas ligada"
        texto = (
            f"A verificação em duas etapas foi ligada na sua conta Deskside em "
            f"{quando} (horário de Brasília). A partir de agora, entrar pede também "
            "o código do app autenticador.\n\nGuarde os códigos de recuperação num "
            "lugar seguro: são eles que abrem a conta se você perder o celular."
        )
        curto = f"Deskside: verificação em duas etapas ligada em {quando}."
    elif evento == "2fa_desligado":
        assunto = "Verificação em duas etapas desligada"
        texto = (
            f"A verificação em duas etapas foi desligada na sua conta Deskside em "
            f"{quando} (horário de Brasília){de_onde}.\n\n{_SE_NAO_FOI_VOCE}"
        )
        curto = (
            f"Deskside: a verificação em duas etapas foi desligada em {quando}. Não "
            "foi você? Redefina a senha no app."
        )
    elif evento == "codigos_novos":
        assunto = "Novos códigos de recuperação"
        texto = (
            f"Códigos de recuperação novos foram gerados para a sua conta Deskside "
            f"em {quando} (horário de Brasília). Os anteriores pararam de valer."
            f"\n\n{_SE_NAO_FOI_VOCE}"
        )
        curto = f"Deskside: novos códigos de recuperação gerados em {quando}."
    elif evento == "codigo_usado":
        assunto = "Um código de recuperação foi usado"
        texto = (
            f"Um código de recuperação da sua conta Deskside foi usado em {quando} "
            f"(horário de Brasília){de_onde}. {detalhe}\n\n{_SE_NAO_FOI_VOCE}"
        )
        curto = (
            f"Deskside: um código de recuperação foi usado em {quando}. Não foi você? "
            "Redefina a senha no app."
        )
    elif evento == "contato_trocado":
        suporte = (
            f" Fale com o suporte: {settings.suporte}." if settings.suporte else
            " Procure o suporte do Deskside."
        )
        assunto = "O contato da sua conta Deskside foi trocado"
        texto = (
            f"Em {quando} (horário de Brasília), o contato da sua conta Deskside "
            f"passou a ser {detalhe}. Este endereço não entra mais na conta.\n\n"
            "Se foi você, não precisa fazer nada.\n\nSe não foi, alguém tomou a sua "
            f"conta e os computadores ligados a ela.{suporte}"
        )
        curto = (
            f"Deskside: o contato da sua conta passou a ser {detalhe} em {quando}. "
            f"Não foi você?{suporte}"
        )
    elif evento == "sessao_copiada":
        qual = f" do aparelho \"{detalhe}\"" if detalhe else ""
        assunto = "Encerramos um acesso à sua conta Deskside"
        texto = (
            f"Em {quando} (horário de Brasília), o acesso{qual} à sua conta foi "
            f"usado de dois lugares ao mesmo tempo{de_onde}. Isso indica que ele "
            "foi copiado, então o encerramos: nesse aparelho, entre de novo.\n\n"
            f"{_SE_NAO_FOI_VOCE}"
        )
        curto = (
            f"Deskside: encerramos um acesso à sua conta em {quando} por suspeita de "
            "cópia. Entre de novo no app; se estranhar, redefina a senha."
        )
    else:  # pragma: no cover - evento novo sem texto é defeito de quem chamou
        raise ValueError(f"evento sem aviso: {evento}")

    return Alerta(
        destino=alvo[0],
        canal=alvo[1],
        assunto=assunto,
        corpo=f"{_ola(user)}\n\n{texto}\n\n— Deskside",
        curto=curto,
    )


def enviar(alerta: Alerta | None) -> None:
    """Manda o aviso. Nunca lança: roda depois da resposta, e falhar aqui não
    pode desfazer nada do que a pessoa acabou de fazer."""
    if alerta is None:
        return
    try:
        if alerta.canal == "email":
            entrega.entregador.aviso(alerta.destino, alerta.assunto, alerta.corpo)
        else:
            entrega.entregador.aviso_sms(alerta.destino, alerta.curto)
    except Exception as exc:  # noqa: BLE001 - qualquer falha vira diário
        logger.error("aviso de segurança não saiu (%s): %s", alerta.assunto, exc)
