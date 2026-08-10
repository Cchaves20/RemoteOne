"""Modelos de dados (tabelas)."""

from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


def _now() -> datetime:
    return datetime.now(UTC)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # Verificação em duas etapas (TOTP). O segredo fica pendente até o usuário
    # confirmar um código; só então `totp_enabled` vira verdadeiro.
    totp_secret: Mapped[str | None] = mapped_column(String(64), nullable=True)
    totp_enabled: Mapped[bool] = mapped_column(default=False)

    devices: Mapped[list["Device"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


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
