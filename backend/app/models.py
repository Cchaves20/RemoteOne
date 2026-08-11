"""Modelos de dados (tabelas)."""

from datetime import UTC, date, datetime

from sqlalchemy import Date, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.security import nova_chave_de_sessao


def _now() -> datetime:
    return datetime.now(UTC)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    #: **Um dos dois** identifica a conta: e-mail ou telefone. Por isso os dois
    #: são nulos no banco, e a regra "exatamente um" vive no cadastro em vez de
    #: numa restrição da tabela — a alternativa seria um `CHECK` que o SQLite e
    #: o Postgres escrevem diferente, para dizer o que o único caminho de
    #: criação já garante.
    #:
    #: Únicos, e por um motivo que não é organização: são eles que se digita
    #: para entrar. Dois cadastros com o mesmo e-mail seriam duas contas que a
    #: mesma pessoa não conseguiria distinguir na hora de logar.
    email: Mapped[str | None] = mapped_column(
        String(320), unique=True, index=True, nullable=True
    )
    #: Guardado em E.164 (`+5511987654321`), nunca como foi digitado. Sem isso,
    #: "(11) 98765-4321" e "11987654321" seriam duas contas.
    phone: Mapped[str | None] = mapped_column(
        String(20), unique=True, index=True, nullable=True
    )
    hashed_password: Mapped[str] = mapped_column(String(255))
    first_name: Mapped[str] = mapped_column(String(80), default="")
    last_name: Mapped[str] = mapped_column(String(80), default="")
    #: `Date` e não `DateTime`: uma data de nascimento não tem hora, e guardar
    #: uma inventaria um fuso que faria a data mudar de dia conforme quem lê.
    birth_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # Verificação em duas etapas (TOTP). O segredo fica pendente até o usuário
    # confirmar um código; só então `totp_enabled` vira verdadeiro.
    totp_secret: Mapped[str | None] = mapped_column(String(64), nullable=True)
    totp_enabled: Mapped[bool] = mapped_column(default=False)
    #: Chave de sessão. Todo token carrega a que valia quando foi emitido, e só
    #: vale enquanto for igual a esta. Trocar a senha sorteia outra, e **todo
    #: token já emitido morre na mesma hora**.
    #:
    #: Existe porque JWT não tem como ser cancelado: ele é uma assinatura que o
    #: servidor confere sozinho, sem consultar nada — é justamente isso que o
    #: torna barato. Sem esta chave, o refresh token dura os 30 dias
    #: configurados **mesmo depois** de a senha ter sido trocada, e quem tivesse
    #: entrado na conta continuaria dentro por um mês. Trocar a senha é o que se
    #: faz exatamente quando se suspeita disso, e era o único gesto que não
    #: resolvia.
    #:
    #: Uma chave por conta, e não uma lista de tokens revogados: a lista
    #: cresceria para sempre e custaria uma consulta a mais por requisição. Aqui
    #: a conferência é um campo da mesma linha que a rota já carregou.
    #:
    #: Sorteada, e não um contador a partir de zero — ver a explicação em
    #: `security.nova_chave_de_sessao`. É a mesma armadilha de id reaproveitado
    #: que as cascatas acima resolvem para os dados, agora para a sessão.
    token_key: Mapped[str] = mapped_column(String(32), default=nova_chave_de_sessao)

    # Tudo o que pertence à conta sai junto com ela. **Todas** as coleções
    # precisam estar aqui, e a que faltar não vira uma linha esquecida e
    # inofensiva no banco — vira a linha que aparece na conta seguinte.
    #
    # O SQLite reaproveita o identificador: com uma coluna `INTEGER PRIMARY
    # KEY`, apagar a conta 1 faz a próxima nascer como 1 de novo. O que ficou
    # para trás com `user_id = 1` passa a pertencer a outra pessoa, sem nada
    # avisar. Foi assim que perfis e computadores pareados de uma conta
    # excluída reapareceram numa conta recém-criada.
    #
    # Nada disso depende de chave estrangeira do banco: o SQLite não as força
    # por padrão, e quem apaga é o SQLAlchemy, por causa destas declarações.
    devices: Mapped[list["Device"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )
    profiles: Mapped[list["ControlProfile"]] = relationship(
        cascade="all, delete-orphan"
    )
    automations: Mapped[list["Automation"]] = relationship(
        cascade="all, delete-orphan"
    )
    profile_layout: Mapped["ProfileLayout | None"] = relationship(
        cascade="all, delete-orphan"
    )
    password_resets: Mapped[list["PasswordReset"]] = relationship(
        cascade="all, delete-orphan"
    )


class PendingSignup(Base):
    """Um cadastro preenchido e ainda não confirmado pelo código.

    **A conta só nasce depois do código**, e é por isso que esta tabela existe
    em vez de um campo `verificado` no `User`. Duas razões, e a segunda decide:

    - Um `User` não verificado ocuparia o e-mail na restrição de unicidade. Bastaria
      alguém digitar o endereço de outra pessoa para **bloquear o cadastro dela**
      — sem nunca provar que o endereço é seu.
    - Uma conta pela metade é uma conta: apareceria em contagens, em consultas,
      e um dia em algum lugar que não esperava o `None`.

    A senha já vem com hash: entre o preenchimento e a confirmação passam
    minutos, e guardar a senha em claro nesse intervalo seria guardar em claro.
    """

    __tablename__ = "pending_signups"

    id: Mapped[int] = mapped_column(primary_key=True)
    #: O que a pessoa recebe o código: e-mail ou E.164. É a chave do fluxo, e
    #: por isso é único — dois cadastros pendentes para o mesmo destino
    #: significariam dois códigos válidos, e o segundo confundiria quem esperava
    #: o primeiro. Recomeçar substitui o anterior.
    destino: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    #: "email" ou "phone". Diz por onde mandar e em qual coluna gravar no fim.
    canal: Mapped[str] = mapped_column(String(8))
    hashed_password: Mapped[str] = mapped_column(String(255))
    first_name: Mapped[str] = mapped_column(String(80))
    last_name: Mapped[str] = mapped_column(String(80))
    birth_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    #: O código também com hash. Contra quem lê o banco, um hash de seis
    #: dígitos vale pouco — são um milhão de tentativas. Vale mesmo assim: o
    #: custo é zero e tira o código de qualquer despejo acidental de tabela.
    hashed_code: Mapped[str] = mapped_column(String(255))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    #: Tentativas erradas. Sem este contador, seis dígitos são adivinháveis por
    #: força bruta em minutos.
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    #: Quando o último código saiu. Segura o "reenviar" apertado repetidamente,
    #: que em SMS é dinheiro indo embora.
    last_sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class PasswordReset(Base):
    """Um pedido de "esqueci minha senha" esperando o código.

    Tabela própria, e não o `PendingSignup` reaproveitado, por um motivo
    concreto: lá o `destino` é único, e uma pessoa que pede recuperação enquanto
    existe um cadastro pendente para o mesmo endereço derrubaria o cadastro do
    outro. São dois fluxos que podem coexistir no mesmo contato.

    Aponta para o `user_id` e não para o contato: se a pessoa trocar o e-mail
    entre pedir o código e usá-lo, o pedido continua valendo para **a conta**,
    que é o que ela quis recuperar.
    """

    __tablename__ = "password_resets"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    #: Para onde o código foi. Guardado para a tela poder mostrar e para o
    #: `reset` achar o pedido sem expor o `user_id` ao app.
    destino: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    canal: Mapped[str] = mapped_column(String(8))
    hashed_code: Mapped[str] = mapped_column(String(255))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Device(Base):
    """Computador pareado, vinculado a uma conta de usuário (Etapa 5)."""

    __tablename__ = "devices"

    id: Mapped[int] = mapped_column(primary_key=True)
    device_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    name: Mapped[str] = mapped_column(String(120))
    os: Mapped[str] = mapped_column(String(32))
    hostname: Mapped[str] = mapped_column(String(120))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # Wake-on-LAN: MAC da máquina e o último IP público visto (agrupa quem está
    # na mesma rede local, para escolher um "peer" ligado que envie o pacote).
    mac_address: Mapped[str | None] = mapped_column(String(32), nullable=True)
    last_public_ip: Mapped[str | None] = mapped_column(String(64), nullable=True)

    user: Mapped[User] = relationship(back_populates="devices")


class PairingRequest(Base):
    """Código de pareamento pendente, ligado a um device_id até ser reivindicado."""

    __tablename__ = "pairing_requests"

    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str] = mapped_column(String(16), unique=True, index=True)
    device_id: Mapped[str] = mapped_column(String(64), index=True)
    hostname: Mapped[str] = mapped_column(String(120))
    os: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ControlProfile(Base):
    """Um perfil de controle montado pelo usuário.

    Os cinco perfis que vêm com o app continuam no app: eles são código
    (atalhos de teclado), não dado. O que mora aqui são os que o usuário criou,
    e o que eles guardam é uma lista de programas para abrir.

    Fica no servidor, e não no telefone, por duas razões concretas: a conta é
    usada em mais de um aparelho (iPhone e iPad veem a mesma lista), e o app
    instalado por sideload é reinstalado com frequência — perfil guardado só no
    aparelho seria perdido junto.
    """

    __tablename__ = "control_profiles"

    id: Mapped[int] = mapped_column(primary_key=True)
    #: Identificador que o app usa. Gerado no servidor, estável para sempre.
    profile_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(60))
    #: Chave de um ícone do app ("movie", "work"). Só chave: o desenho é do app,
    #: que sabe o tema e a densidade da tela.
    icon: Mapped[str] = mapped_column(String(32), default="tune")
    position: Mapped[int] = mapped_column(Integer, default=0)
    #: Programas a abrir, em JSON: `[{"name": ..., "path": ...}]`.
    #:
    #: JSON e não tabela filha porque isto é uma lista curta que só se lê
    #: inteira, nunca consultada por campo. Uma tabela custaria um join e uma
    #: migração para não ganhar nada.
    apps: Mapped[str] = mapped_column(Text, default="[]")
    #: Computadores a que o perfil se aplica, em JSON. Lista vazia = todos.
    devices: Mapped[str] = mapped_column(Text, default="[]")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Automation(Base):
    """Uma automação: a sequência de passos que um toque executa.

    Mora ao lado do `ControlProfile` e **não** dentro dele, apesar de as duas
    coisas se parecerem no editor. A diferença é uma só e aparece no uso: num
    perfil a ordem não significa nada (são botões lado a lado, e você toca no
    que quiser), enquanto numa automação a ordem é o recurso inteiro.

    Guardar as duas no mesmo objeto faria todo perfil carregar uma sequência que
    talvez não queira ter, e obrigaria o editor a explicar a diferença antes de
    servir para alguma coisa.
    """

    __tablename__ = "automations"

    id: Mapped[int] = mapped_column(primary_key=True)
    #: Identificador que o app usa. Gerado no servidor, estável para sempre.
    automation_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(60))
    icon: Mapped[str] = mapped_column(String(32), default="tune")
    position: Mapped[int] = mapped_column(Integer, default=0)
    #: Os passos, em JSON. Mesmo raciocínio dos programas de um perfil: é uma
    #: lista curta que só se lê inteira, nunca consultada por campo. Uma tabela
    #: filha custaria um join e uma migração para não ganhar nada - e este
    #: projeto ainda não tem Alembic.
    steps: Mapped[str] = mapped_column(Text, default="[]")
    #: Em qual computador ela roda. Vazio = pergunta na hora.
    #:
    #: Singular, ao contrário do perfil: um perfil é um punhado de atalhos que
    #: vale em várias máquinas, mas uma automação abre programas *daquele*
    #: computador e pode terminar suspendendo *aquela* máquina.
    device_id: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ProfileLayout(Base):
    """A ordem dos perfis na barra, escolhida pelo usuário.

    Guarda a lista inteira de identificadores — os de fábrica junto com os
    criados —, porque a ordem é uma só. Guardar apenas a posição dos criados
    não diria onde eles entram no meio dos outros.
    """

    __tablename__ = "profile_layouts"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    #: JSON com a lista de ids, na ordem.
    order: Mapped[str] = mapped_column(Text, default="[]")
