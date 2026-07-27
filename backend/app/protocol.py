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
    # MAC da placa de rede local (para Wake-on-LAN). Opcional: agentes antigos
    # ou máquinas sem MAC resolvido não enviam.
    mac: str | None = None


class Heartbeat(BaseModel):
    """Sinal periódico de que o agente continua vivo."""

    type: Literal["heartbeat"] = "heartbeat"


class AppInfo(BaseModel):
    """Um aplicativo: `id` é o caminho do atalho (instalado) ou o PID (aberto).

    `icon` é o ícone real do programa (PNG em base64), quando o agente
    conseguiu extrair.
    """

    id: str
    name: str
    icon: str | None = None


class AppList(BaseModel):
    """Resposta do agente a um `list_apps`, com o `request_id` do pedido."""

    type: Literal["app_list"] = "app_list"
    request_id: str
    apps: list[AppInfo] = []


class WebrtcAnswer(BaseModel):
    """Resposta SDP do agente à oferta de um app (negociação de vídeo)."""

    type: Literal["webrtc_answer"] = "webrtc_answer"
    session_id: str
    sdp: str


class WebrtcIce(BaseModel):
    """Um candidato ICE. Trafega nos dois sentidos, com o mesmo formato.

    `candidate` vazio é o sinal de "acabaram os candidatos" e é válido.
    """

    type: Literal["webrtc_ice"] = "webrtc_ice"
    session_id: str
    candidate: str
    sdp_mid: str | None = None
    sdp_mline_index: int | None = None


ClientMessage = Annotated[
    Hello | Heartbeat | AppList | WebrtcAnswer | WebrtcIce,
    Field(discriminator="type"),
]
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


class PairCode(BaseModel):
    """Código de pareamento a ser exibido pelo agente (dispositivo não pareado)."""

    type: Literal["pair_code"] = "pair_code"
    code: str
    expires_in_seconds: int


class Paired(BaseModel):
    """Notifica o agente de que foi vinculado a uma conta."""

    type: Literal["paired"] = "paired"
    user_email: str


def parse_client_message(raw: dict) -> ClientMessage:
    """Interpreta um dict cru como mensagem do agente.

    Lança `ValueError` (com a `ValidationError` original encadeada) se a
    mensagem não corresponder a nenhum tipo conhecido.
    """
    try:
        return _client_adapter.validate_python(raw)
    except ValidationError as exc:
        raise ValueError(f"mensagem de agente inválida: {raw!r}") from exc
