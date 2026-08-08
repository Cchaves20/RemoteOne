"""Schemas de entrada e saída da API de autenticação."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field, model_validator


class Credentials(BaseModel):
    """Dados de cadastro/login. A senha é limitada a 72 bytes (limite do bcrypt).

    `totp_code` só é usado no login quando a conta tem 2FA ativo; no cadastro é
    ignorado.
    """

    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    totp_code: str | None = Field(default=None, max_length=10)


class TwoFactorSetupOut(BaseModel):
    """Segredo e URI (para QR Code) ao iniciar a configuração do 2FA."""

    secret: str
    otpauth_uri: str


class TwoFactorEnableRequest(BaseModel):
    """Confirma a ativação do 2FA com um código do autenticador."""

    code: str = Field(min_length=6, max_length=10)


class TwoFactorDisableRequest(BaseModel):
    """Desativa o 2FA (exige a senha atual)."""

    password: str = Field(min_length=1, max_length=72)


class UpdateEmailRequest(BaseModel):
    """Troca de e-mail: exige a senha atual para confirmar a identidade."""

    current_password: str = Field(min_length=1, max_length=72)
    new_email: EmailStr


class UpdatePasswordRequest(BaseModel):
    """Troca de senha: exige a senha atual e a nova (mesmo limite do bcrypt)."""

    current_password: str = Field(min_length=1, max_length=72)
    new_password: str = Field(min_length=8, max_length=72)


class DeleteAccountRequest(BaseModel):
    """Exclusão de conta: exige a senha atual como confirmação."""

    password: str = Field(min_length=1, max_length=72)


class RefreshRequest(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class AccessToken(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(BaseModel):
    id: int
    email: EmailStr
    created_at: datetime
    totp_enabled: bool = False

    model_config = {"from_attributes": True}


class ClaimRequest(BaseModel):
    code: str = Field(min_length=1, max_length=16)


class RenameDeviceRequest(BaseModel):
    """Novo apelido do computador na conta."""

    name: str = Field(min_length=1, max_length=120)


class PowerRequest(BaseModel):
    """Ação de energia a ser executada no computador pareado."""

    action: Literal["shutdown", "restart", "suspend"]


class MediaRequest(BaseModel):
    """Tecla de mídia a acionar no computador pareado.

    São as teclas globais de um teclado multimídia: valem para quem estiver
    tocando som, sem precisar deixar o player em foco.
    """

    action: Literal["play_pause", "next", "previous", "volume_up", "volume_down", "mute"]


class SystemStatsOut(BaseModel):
    """Métricas do computador: CPU em %, o resto em bytes.

    Os campos opcionais são as medidas que **não existem em toda máquina**:
    desktop não tem bateria, máquina virtual não tem GPU dedicada e, no Windows,
    a temperatura em geral só sai com driver do fabricante. `None` é resposta
    legítima e diferente de zero — o app esconde a medida ausente em vez de
    mostrar 0, que se leria como "GPU parada" ou "bateria acabando".

    Todos têm padrão para que um agente antigo, que ainda não manda estes
    campos, continue funcionando sem erro de validação.
    """

    cpu_percent: float
    memory_used: int
    memory_total: int
    disk_used: int
    disk_total: int
    disk_name: str
    uptime_seconds: int
    gpu_percent: float | None = None
    gpu_name: str | None = None
    temperature_celsius: float | None = None
    #: Bytes por segundo, somando todas as interfaces de rede.
    network_rx_bps: int = 0
    network_tx_bps: int = 0
    battery_percent: int | None = None
    on_battery: bool | None = None


class BrightnessRequest(BaseModel):
    """Ajuste de brilho: um valor absoluto **ou** um passo relativo.

    O passo existe para a barra de perfis, que tem botões de mais e menos, e é
    resolvido no computador. Fazer o telefone ler, somar e escrever custaria
    duas idas e voltas por toque - e dois toques rápidos se atropelariam,
    porque os dois leriam o mesmo valor antigo e o segundo desfaria o primeiro.
    """

    level: int | None = Field(default=None, ge=0, le=100)
    #: Teto de 100 nos dois sentidos: é a faixa inteira, e nada além disso faz
    #: sentido num ajuste relativo.
    delta: int | None = Field(default=None, ge=-100, le=100)

    @model_validator(mode="after")
    def exatamente_um(self) -> "BrightnessRequest":
        if (self.level is None) == (self.delta is None):
            raise ValueError("mande level ou delta, e apenas um dos dois")
        return self


class BrightnessOut(BaseModel):
    """O brilho depois do ajuste, de 0 a 100."""

    level: int


class AudioRequest(BaseModel):
    """Liga ou desliga o envio do som do computador, e com qual ganho.

    O ganho existe para um jeito específico de usar: deixar o computador quase
    mudo (volume no mínimo, sem silenciar) e recuperar o volume no telefone. O
    teto de 32x é o mesmo do agente - acima disso o que se amplifica já é mais
    ruído do que som.
    """

    enabled: bool
    gain: float = Field(1.0, ge=0.0, le=32.0)


class ClipboardIn(BaseModel):
    """Texto a colocar na área de transferência do computador."""

    text: str = Field(max_length=64 * 1024)


class ClipboardSyncRequest(BaseModel):
    """Liga/desliga o aviso automático de cópia nova no computador."""

    enabled: bool


class ForegroundAppOut(BaseModel):
    """O programa em primeiro plano no computador.

    `app` nulo é resposta normal (nenhuma janela em foco, ou um sistema sem
    sessão gráfica): o app simplesmente fica com os ícones genéricos.
    """

    name: str = ""
    exe: str
    icon: str | None = None


class ForegroundOut(BaseModel):
    app: ForegroundAppOut | None = None


class KeepAwakeOut(BaseModel):
    """Se o computador está sendo mantido pronto para controle remoto.

    Os três campos dizem coisas diferentes e o app precisa dos três: `enabled`
    é a escolha do usuário, `holding` é o que está valendo agora, e `source`
    explica a diferença entre os dois quando ela existe - na bateria, ligado
    não significa segurando.
    """

    enabled: bool
    holding: bool
    source: Literal["ac", "battery", "unknown"]


class KeepAwakeRequest(BaseModel):
    """Liga ou desliga o "manter pronto" no computador."""

    enabled: bool


class FileEntryOut(BaseModel):
    """Um item de uma pasta do computador."""

    name: str
    path: str
    is_dir: bool
    size: int = 0



class ClipboardOut(BaseModel):
    """O que está na área de transferência do computador.

    `files` são os **caminhos** que o Windows guarda quando se copia um arquivo
    no Explorer - copiar um vídeo não põe o vídeo na área de transferência, põe
    a referência a ele. Baixar é com a transferência de arquivos, que já sabe
    fazer isso por caminho.
    """

    text: str = ""
    files: list[FileEntryOut] = []
    #: Quantos caminhos copiados o agente recusou por estarem fora da pasta do
    #: usuário. Separa "não copiei nada" de "copiei de um disco que o agente
    #: não alcança" - que chegam iguais aqui se ninguém contar.
    ignored: int = 0
    #: A imagem copiada, em base64, quando há uma. Diferente dos arquivos: aqui
    #: vêm os **bytes**, porque uma imagem copiada não tem caminho em disco -
    #: ela existe só na área de transferência.
    image: str | None = None
    #: "image/png" ou "image/jpeg".
    image_mime: str | None = None
    image_width: int | None = None
    image_height: int | None = None


class MonitorOut(BaseModel):
    """Uma tela do computador, como o app a mostra na lista."""

    id: int
    name: str
    width: int = 0
    height: int = 0
    primary: bool = False


class MonitorsOut(BaseModel):
    """As telas do computador e qual delas está sendo capturada."""

    monitors: list[MonitorOut] = []
    selected: int | None = None


class MonitorIn(BaseModel):
    """Qual tela capturar. `None` volta ao monitor principal."""

    monitor: int | None = None


class ListingOut(BaseModel):
    """O conteúdo de uma pasta. `parent` ausente = já é a raiz permitida."""

    path: str
    parent: str | None = None
    entries: list[FileEntryOut] = []
    #: Atalhos para as pastas conhecidas do usuário (Área de Trabalho,
    #: Downloads...), preenchidos só na raiz.
    shortcuts: list[FileEntryOut] = []


class AppOut(BaseModel):
    """Um aplicativo do computador. `id` = caminho do atalho ou PID.

    `icon`: ícone real do programa em PNG base64 (quando disponível).
    """

    id: str
    name: str
    icon: str | None = None


class AppActionRequest(BaseModel):
    """Abrir (id = caminho do atalho) ou encerrar (id = PID) um aplicativo."""

    id: str = Field(min_length=1, max_length=1024)


class ProfileAppIn(BaseModel):
    """Um programa que um perfil abre.

    Guarda o **nome** além do caminho porque o mesmo perfil pode valer para mais
    de um computador, e o caminho de um não existe no outro — o Spotify de uma
    máquina mora em `AppData`, o da outra em `Program Files`. O que sobrevive à
    troca de máquina é o nome, e é por ele que o agente procura quando o
    caminho falha.
    """

    name: str = Field(min_length=1, max_length=120)
    path: str = Field(min_length=1, max_length=1024)


class ProfileIn(BaseModel):
    """Um perfil criado pelo usuário."""

    name: str = Field(min_length=1, max_length=60)
    #: Chave de um ícone do app ("movie", "work"). Só a chave: o desenho é do
    #: app, que sabe o tema e a densidade da tela.
    icon: str = Field(default="tune", max_length=32)
    #: Doze programas é mais do que cabe na barra sem virar rolagem.
    apps: list[ProfileAppIn] = Field(default_factory=list, max_length=12)
    #: Computadores a que o perfil se aplica. Vazio = todos.
    devices: list[str] = Field(default_factory=list, max_length=32)


class ProfileOut(ProfileIn):
    """O mesmo, com o identificador que o servidor gerou."""

    id: str


class ProfilesOut(BaseModel):
    """Os perfis da conta e a ordem da barra.

    `order` traz a fila inteira, com os identificadores dos perfis de fábrica
    junto: a barra é uma só, e dizer onde um perfil criado entra exige saber
    onde estão os outros. Vazia = ninguém reordenou ainda.
    """

    profiles: list[ProfileOut] = []
    order: list[str] = []


class ProfileOrderIn(BaseModel):
    """A nova ordem da barra, de fábrica e criados na mesma lista."""

    ids: list[str] = Field(default_factory=list, max_length=64)


class DeviceOut(BaseModel):
    device_id: str
    name: str
    os: str
    hostname: str
    created_at: datetime
    # Preenchido pela rota a partir das conexões vivas (não vem do banco).
    online: bool = False

    model_config = {"from_attributes": True}
