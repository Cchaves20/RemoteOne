"""Protocolo de mensagens trocadas pelo WebSocket agente ↔ backend.

O formato de fio (JSON com campo discriminador `type`) é espelhado no agente
Rust em `agent/src/protocol.rs`. Qualquer mudança aqui precisa ser refletida
lá — os testes dos dois lados fixam o mesmo formato.
"""

from typing import Annotated, Literal

from pydantic import BaseModel, Field, TypeAdapter, ValidationError

# --- Mensagens enviadas pelo agente (cliente) ---------------------------------


class Hello(BaseModel):
    """Primeira mensagem: o agente se identifica ao conectar."""

    type: Literal["hello"] = "hello"
    device_id: str
    hostname: str
    os: str
    agent_version: str


class Heartbeat(BaseModel):
    """Sinal periódico de que o agente continua vivo."""

    type: Literal["heartbeat"] = "heartbeat"


ClientMessage = Annotated[Hello | Heartbeat, Field(discriminator="type")]
_client_adapter: TypeAdapter[ClientMessage] = TypeAdapter(ClientMessage)


# --- Mensagens enviadas pelo backend (servidor) -------------------------------


class Welcome(BaseModel):
    """Resposta ao hello, confirmando o registro."""

    type: Literal["welcome"] = "welcome"
    server_version: str


class Ack(BaseModel):
    """Confirmação de heartbeat."""

    type: Literal["ack"] = "ack"


class Error(BaseModel):
    """Mensagem inesperada ou inválida recebida do agente."""

    type: Literal["error"] = "error"
    message: str


def parse_client_message(raw: dict) -> ClientMessage:
    """Interpreta um dict cru como mensagem do agente.

    Lança `ValueError` (com a `ValidationError` original encadeada) se a
    mensagem não corresponder a nenhum tipo conhecido.
    """
    try:
        return _client_adapter.validate_python(raw)
    except ValidationError as exc:
        raise ValueError(f"mensagem de agente inválida: {raw!r}") from exc
