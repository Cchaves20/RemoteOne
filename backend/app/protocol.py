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


class MonitorInfo(BaseModel):
    """Uma tela do computador."""

    #: Identificador do sistema. É por ele que o app escolhe, e não pela posição
    #: na lista: a ordem muda quando alguém liga ou desliga um monitor.
    id: int
    name: str
    width: int = 0
    height: int = 0
    primary: bool = False


class MonitorList(BaseModel):
    """Resposta do agente a um `list_monitors`."""

    type: Literal["monitor_list"] = "monitor_list"
    request_id: str
    monitors: list[MonitorInfo] = []
    #: Qual está sendo capturada. Ausente = ninguém escolheu, vale o principal.
    selected: int | None = None


class SystemSnapshot(BaseModel):
    """Métricas do computador, em bytes e porcentagem.

    Bytes crus de propósito: quem transforma em "7,8 GB" é o app, que sabe o
    idioma do usuário.
    """

    cpu_percent: float = Field(ge=0, le=100)
    memory_used: int = Field(ge=0)
    memory_total: int = Field(ge=0)
    disk_used: int = Field(ge=0)
    disk_total: int = Field(ge=0)
    disk_name: str = ""
    uptime_seconds: int = Field(ge=0)


class SystemStats(BaseModel):
    """Resposta do agente a um `system_info`, com o `request_id` do pedido."""

    type: Literal["system_stats"] = "system_stats"
    request_id: str
    stats: SystemSnapshot


class ForegroundApp(BaseModel):
    """O programa em primeiro plano no computador, com o ícone dele."""

    name: str = ""
    #: Executável em minúsculas ("powerpnt.exe"). É a chave de comparação do
    #: app: o nome legível muda com o idioma do Windows, o executável não.
    exe: str
    #: PNG em base64. Ausente quando não deu para extrair.
    icon: str | None = None


class Foreground(BaseModel):
    """Resposta do agente a um `foreground_info`.

    `app` vem nulo quando não deu para descobrir (nenhuma janela em foco, ou o
    processo sumiu no meio) - situação normal, não erro.
    """

    type: Literal["foreground_app"] = "foreground_app"
    request_id: str
    app: ForegroundApp | None = None


class KeepAwakeState(BaseModel):
    """Resposta do agente a um `keep_awake_info`.

    São três informações e não uma. "Desligado" e "ligado, mas solto agora"
    são estados diferentes: um notebook na bateria com a opção ligada não está
    segurando nada, e mostrar só a chave ligada prometeria ao usuário um
    computador alcançável que vai dormir na próxima pausa.
    """

    type: Literal["keep_awake_state"] = "keep_awake_state"
    request_id: str
    #: O que o usuário escolheu.
    enabled: bool
    #: Se o pedido ao sistema está de pé neste instante.
    holding: bool
    #: De onde vem a energia: "ac", "battery" ou "unknown".
    source: Literal["ac", "battery", "unknown"]


class LaunchResult(BaseModel):
    """O que aconteceu com um programa do "abrir todos"."""

    id: str
    ok: bool
    #: Por que não abriu. Ausente quando abriu.
    error: str | None = None


class LaunchManyResult(BaseModel):
    """Resposta do agente a um `launch_many`.

    A lista volta na **mesma ordem** do pedido, e cada item carrega o
    identificador que veio - é o que permite ao app dizer *qual* dos quatro não
    abriu, em vez de "algo falhou".
    """

    type: Literal["launch_many_result"] = "launch_many_result"
    request_id: str
    results: list[LaunchResult] = []


class BrightnessState(BaseModel):
    """Resposta do agente a um `brightness`: o brilho depois do ajuste.

    Tem resposta, e as teclas de mídia não têm, porque as duas falham de jeitos
    diferentes. Volume mexe no sistema e funciona em qualquer máquina; brilho
    por software só alcança o **painel embutido** de um notebook. Num
    computador de mesa com monitor externo não há o que ajustar, e sem resposta
    o toque simplesmente não faria nada - o pior tipo de falha, a que não deixa
    rastro.

    Exatamente um dos dois vem preenchido.
    """

    type: Literal["brightness_state"] = "brightness_state"
    request_id: str
    #: Nível resultante, de 0 a 100. Ausente quando não deu.
    level: int | None = None
    #: Por que não deu, quando não deu.
    error: str | None = None


class ClipboardChanged(BaseModel):
    """Aviso de que alguém copiou algo novo no computador.

    Chega sem pedido, e só enquanto a sincronia automática está ligada. O teto
    de tamanho é o mesmo do agente: copiar um log inteiro é comum, e isso não
    pode virar uma mensagem de megabytes.
    """

    type: Literal["clipboard_changed"] = "clipboard_changed"
    text: str = Field(max_length=64 * 1024)


class FileEntry(BaseModel):
    """Um item de uma pasta do computador."""

    name: str
    path: str
    is_dir: bool
    size: int = 0


class Listing(BaseModel):
    """O conteúdo de uma pasta, com o caminho de voltar (ausente na raiz)."""

    path: str
    parent: str | None = None
    entries: list[FileEntry] = []
    #: Atalhos para as pastas conhecidas (Área de Trabalho, Downloads...). Só
    #: vêm preenchidos na raiz, que é onde eles servem para alguma coisa.
    shortcuts: list[FileEntry] = []


class Clipboard(BaseModel):
    """Resposta do agente a um `clipboard_get`."""

    type: Literal["clipboard"] = "clipboard"
    request_id: str
    text: str = ""
    #: Arquivos copiados no computador. Copiar um vídeo no Explorer põe o
    #: **caminho** dele aqui, não os bytes - e quem busca por caminho é a
    #: transferência de arquivos, que já existe.
    files: list[FileEntry] = []
    #: Quantos caminhos foram recusados por estarem fora da pasta do usuário.
    #: Agente antigo não manda o campo, e zero é a leitura certa para ele.
    ignored: int = 0
    #: A imagem copiada, em base64. Vem só na resposta a um pedido, nunca no
    #: aviso automático de cópia: texto custa quilobytes e uma captura de tela
    #: custa megabytes.
    image: str | None = None
    #: "image/png" ou "image/jpeg" - o app precisa saber o que gravar quando a
    #: pessoa manda o arquivo para outro aplicativo.
    image_mime: str | None = None
    image_width: int | None = None
    image_height: int | None = None



class FileList(BaseModel):
    """Resposta do agente a um `list_files`: o conteúdo **ou** o motivo da falha.

    Uma pasta sem permissão não pode chegar ao app como pasta vazia — são
    coisas diferentes para quem está procurando um arquivo.
    """

    type: Literal["file_list"] = "file_list"
    request_id: str
    listing: Listing | None = None
    error: str | None = None


class FileChunk(BaseModel):
    """Um pedaço de arquivo vindo do computador. `data` é base64."""

    type: Literal["file_chunk"] = "file_chunk"
    transfer_id: str
    seq: int = Field(ge=0)
    data: str


class FileDone(BaseModel):
    """Fim de uma transferência, nos dois sentidos."""

    type: Literal["file_done"] = "file_done"
    transfer_id: str
    ok: bool
    detail: str | None = None
    size: int | None = None


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
    Hello
    | Heartbeat
    | AppList
    | MonitorList
    | SystemStats
    | Foreground
    | Clipboard
    | ClipboardChanged
    | KeepAwakeState
    | BrightnessState
    | LaunchManyResult
    | FileList
    | FileChunk
    | FileDone
    | WebrtcAnswer
    | WebrtcIce,
    Field(discriminator="type"),
]
_client_adapter: TypeAdapter[ClientMessage] = TypeAdapter(ClientMessage)


# --- Mensagens enviadas pelo backend (servidor) -------------------------------


class Welcome(BaseModel):
    """Resposta ao hello, confirmando o registro.

    Leva junto os servidores ICE: o agente precisa dos mesmos que o app, e as
    credenciais do TURN são temporárias - fixá-las na configuração do agente
    obrigaria a reinstalar a cada rodízio.
    """

    type: Literal["welcome"] = "welcome"
    server_version: str
    ice_servers: list[dict] = []


class Ack(BaseModel):
    """Confirmação de heartbeat."""

    type: Literal["ack"] = "ack"


class Error(BaseModel):
    """Mensagem inesperada ou inválida recebida do agente."""

    type: Literal["error"] = "error"
    message: str


class KeepAwake(BaseModel):
    """Liga ou desliga o "manter o computador pronto para controle remoto"."""

    type: Literal["keep_awake"] = "keep_awake"
    enabled: bool


class KeepAwakeInfo(BaseModel):
    """Pergunta ao agente se o computador está sendo mantido pronto."""

    type: Literal["keep_awake_info"] = "keep_awake_info"
    request_id: str


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
