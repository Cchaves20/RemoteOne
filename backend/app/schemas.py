"""Schemas de entrada e saída da API de autenticação."""

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field, model_validator


class Credentials(BaseModel):
    """Dados de login: e-mail **ou** telefone, mais a senha.

    Um campo por forma, e não um campo só que aceita as duas, porque o telefone
    precisa do país junto — `987654321` não identifica ninguém sem saber de onde
    é. E um "identificador" que às vezes carrega um país e às vezes não é um
    campo que significa duas coisas.

    `totp_code` só é usado quando a conta tem 2FA ativo.
    """

    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=32)
    #: ISO do país do telefone ("BR"). Ignorado quando se entra por e-mail.
    country: str | None = Field(default=None, max_length=2)
    #: Sem `min_length` aqui, ao contrário do cadastro: as senhas antigas
    #: existem, e um login que recusasse a senha certa por ser curta trancaria
    #: a pessoa fora da própria conta em nome de uma regra que só vale para
    #: senhas novas.
    password: str = Field(min_length=1, max_length=72)
    totp_code: str | None = Field(default=None, max_length=10)

    @model_validator(mode="after")
    def um_identificador(self) -> "Credentials":
        if (self.email is None) == (self.phone is None):
            raise ValueError("mande e-mail ou telefone, e apenas um dos dois")
        if self.phone is not None and not self.country:
            raise ValueError("telefone precisa do país")
        return self


class SignupStart(BaseModel):
    """O formulário de criação de conta, antes da verificação.

    Chega inteiro numa vez só, e a verificação vem depois, porque é isso que
    permite recusar o que estiver errado **antes** de gastar um SMS: senha
    fraca, telefone impossível, idade abaixo do mínimo. Verificar primeiro e
    validar depois faria a pessoa receber um código para então descobrir que a
    senha não serve.
    """

    first_name: str = Field(min_length=1, max_length=80)
    last_name: str = Field(min_length=1, max_length=80)
    birth_date: date
    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=32)
    country: str | None = Field(default=None, max_length=2)
    #: A política das cinco regras é conferida no endpoint, e não aqui, para a
    #: resposta poder listar **o que falta** em vez de um "senha inválida".
    password: str = Field(min_length=1, max_length=72)
    password_confirm: str = Field(min_length=1, max_length=72)

    @model_validator(mode="after")
    def coerente(self) -> "SignupStart":
        if (self.email is None) == (self.phone is None):
            raise ValueError("mande e-mail ou telefone, e apenas um dos dois")
        if self.phone is not None and not self.country:
            raise ValueError("telefone precisa do país")
        if self.password != self.password_confirm:
            raise ValueError("as senhas não conferem")
        return self


class SignupPending(BaseModel):
    """Resposta do início do cadastro: para onde o código foi, e quando pode ir de novo.

    `destination` volta **normalizado** — o telefone em E.164, o e-mail em
    minúsculas. É o que a tela de verificação manda de volta, e devolvê-lo daqui
    evita que o app tenha de repetir a normalização e errar de um jeito
    diferente.
    """

    destination: str
    channel: Literal["email", "phone"]
    #: Quanto falta para o botão de reenviar valer. A tela mostra a contagem em
    #: vez de deixar a pessoa tocar e receber um erro.
    resend_in_seconds: int
    #: Falso quando o servidor não tem provedor configurado e o código foi para
    #: o diário. O app avisa em vez de deixar a pessoa esperando um SMS que
    #: nunca vai chegar.
    delivered: bool = True


class SignupVerify(BaseModel):
    """O código digitado, com o destino a que ele pertence."""

    destination: str = Field(min_length=1, max_length=320)
    code: str = Field(min_length=1, max_length=10)


class SignupResend(BaseModel):
    destination: str = Field(min_length=1, max_length=320)


class ForgotPasswordRequest(BaseModel):
    """Quem esqueceu a senha, identificado como no login."""

    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=32)
    country: str | None = Field(default=None, max_length=2)

    @model_validator(mode="after")
    def um_identificador(self) -> "ForgotPasswordRequest":
        if (self.email is None) == (self.phone is None):
            raise ValueError("mande e-mail ou telefone, e apenas um dos dois")
        if self.phone is not None and not self.country:
            raise ValueError("telefone precisa do país")
        return self


class ResetPasswordRequest(BaseModel):
    """O código recebido e a senha nova."""

    destination: str = Field(min_length=1, max_length=320)
    code: str = Field(min_length=1, max_length=10)
    #: A política das cinco regras é conferida no endpoint, para a resposta
    #: poder listar o que falta — igual ao cadastro.
    password: str = Field(min_length=1, max_length=72)
    password_confirm: str = Field(min_length=1, max_length=72)

    @model_validator(mode="after")
    def senhas_conferem(self) -> "ResetPasswordRequest":
        if self.password != self.password_confirm:
            raise ValueError("as senhas não conferem")
        return self


class CountryOut(BaseModel):
    """Um país no seletor de telefone."""

    iso: str
    name: str
    dial_code: str
    flag: str


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


class ContactChangeStart(BaseModel):
    """Início da troca de contato: a senha atual e o contato novo.

    Um só schema para e-mail e telefone, ao contrário dos dois pedidos que
    havia antes. A troca virou um fluxo de duas etapas com código, e duas rotas
    quase iguais significariam dois caminhos para manter em sincronia — cada um
    com sua chance de esquecer a conferência que o outro faz.

    O país acompanha o telefone, como em toda parte que aceita número:
    `987654321` não identifica ninguém sem saber de onde é.
    """

    current_password: str = Field(min_length=1, max_length=72)
    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=32)
    country: str | None = Field(default=None, max_length=2)

    @model_validator(mode="after")
    def um_identificador(self) -> "ContactChangeStart":
        if (self.email is None) == (self.phone is None):
            raise ValueError("mande e-mail ou telefone, e apenas um dos dois")
        if self.phone is not None and not self.country:
            raise ValueError("telefone precisa do país")
        return self


class ContactChangeVerify(BaseModel):
    """Só o código.

    Sem `destination`, ao contrário do cadastro: aqui quem confirma já está
    autenticado, e a troca pendente se acha pelo token. Pedir o destino no corpo
    seria deixar o cliente escolher **qual** troca confirmar — informação que o
    servidor já tem e que ele não deveria aceitar de fora.
    """

    code: str = Field(min_length=1, max_length=10)


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
    #: Um dos dois vem preenchido — é o que identifica a conta.
    email: EmailStr | None = None
    phone: str | None = None
    first_name: str = ""
    last_name: str = ""
    birth_date: date | None = None
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


class ZoneIn(BaseModel):
    """Onde a janela de um programa deve ficar, em células de uma grade.

    Células, e não frações: um layout de três colunas em frações seria 0,333
    cada, e três vezes 0,333 não fecha 1 - sobraria uma fresta entre as janelas
    ou elas se sobreporiam. Com a grade, a borda direita de uma zona sai da
    mesma conta que a borda esquerda da seguinte.

    O backend **não** conhece os layouts (metades, três colunas, 2x2): quem tem
    o catálogo é o app, que precisa dele para desenhar o seletor. Aqui só chega
    a grade e a célula.
    """

    cols: int = Field(ge=1, le=6)
    rows: int = Field(ge=1, le=6)
    col: int = Field(ge=0, le=5)
    row: int = Field(ge=0, le=5)
    colspan: int = Field(default=1, ge=1, le=6)
    rowspan: int = Field(default=1, ge=1, le=6)

    @model_validator(mode="after")
    def cabe_na_grade(self) -> "ZoneIn":
        if self.col + self.colspan > self.cols or self.row + self.rowspan > self.rows:
            raise ValueError("a zona não cabe na grade que ela declara")
        return self


class LaunchManyRequest(BaseModel):
    """Os programas a abrir de uma vez - o "abrir todos" de um perfil.

    O teto de 16 é o mesmo do agente. Ele não está aqui para a interface: um
    perfil com dezesseis programas já é exagero, e o limite existe para o caso
    de uma mensagem adulterada mandar o computador abrir mil janelas.

    `zones` é **paralelo** a `apps`, e essa escolha é deliberada: um agente
    antigo não conhece o campo, ignora e abre os programas como sempre - a
    degradação certa, porque "abriu sem posicionar" é exatamente o comportamento
    anterior. Uma lista de objetos no lugar de `apps` quebraria o "abrir todos"
    em todo computador que ainda não tivesse atualizado.
    """

    apps: list[str] = Field(min_length=1, max_length=16)
    #: Uma entrada por programa, ou nada. `None` numa posição = aquele programa
    #: abre onde o Windows quiser.
    zones: list[ZoneIn | None] | None = None

    @model_validator(mode="after")
    def uma_zona_por_programa(self) -> "LaunchManyRequest":
        # Listas de tamanhos diferentes emparelhariam a zona do navegador com o
        # terminal. Nada falha, tudo abre, e a tela fica errada - o tipo de
        # defeito que não deixa rastro.
        if self.zones is not None and len(self.zones) != len(self.apps):
            raise ValueError("zones precisa ter uma entrada por programa")
        return self


class LaunchResultOut(BaseModel):
    """O que aconteceu com um programa da lista."""

    id: str
    ok: bool
    error: str | None = None


class LaunchManyOut(BaseModel):
    """O resultado de cada programa, na ordem em que foram pedidos.

    Devolve a lista inteira, e não um "deu certo": abrir quatro e não dizer que
    um falhou é o mesmo que falhar em silêncio. O app mostra *qual* não abriu.
    """

    results: list[LaunchResultOut] = []


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
    #: Onde a janela deste programa fica quando se abre todos de uma vez.
    #: `None` = abre onde o Windows quiser, que é o comportamento de sempre.
    #:
    #: Não há coluna nova no banco: os programas de um perfil já são guardados
    #: como JSON, então a zona entra junto. Num projeto sem Alembic, evitar uma
    #: migração é evitar um remendo à mão em `db.py`.
    #:
    #: A grade (`cols`/`rows`) viaja dentro de cada zona, e não no perfil: assim
    #: o layout escolhido é dedutível do que está guardado, sem um campo a mais
    #: que pudesse discordar das zonas.
    zone: ZoneIn | None = None


#: As teclas de mídia e os comandos de energia que o agente conhece.
#:
#: Duplicar aqui um catálogo que já existe no Rust normalmente não valeria a
#: pena - e vale, para estes dois, porque são fechados, curtos e escritos à mão
#: pelo app. Um `"sleep"` no lugar de `"suspend"` passaria batido, e a automação
#: só falharia no computador, no último passo, com uma mensagem sobre um comando
#: desconhecido. (Foi exatamente o erro que apareceu ao montar os testes deste
#: módulo.) O `input` continua sem validação: é uma estrutura aninhada grande, e
#: copiá-la criaria a segunda fonte de verdade que estes dois conjuntos não
#: criam.
MEDIA_ACTIONS = frozenset(
    {"play_pause", "next", "previous", "volume_up", "volume_down", "mute"}
)
POWER_ACTIONS = frozenset({"shutdown", "restart", "suspend"})


class StepIn(BaseModel):
    """Um passo de automação.

    O `kind` decide quais campos importam; os demais vêm nulos. Um modelo por
    tipo daria validação mais apertada, e custaria seis classes com um campo
    cada - o agente já valida o que sabe executar, e o que não reconhecer vira
    um passo que falha com motivo, não um comando estranho.

    `wait_ms` é a pausa **depois** deste passo. Abrir um programa e mandar um
    atalho no instante seguinte não funciona: o programa ainda não existe para
    receber a tecla.
    """

    #: `close_all` não leva campo nenhum: ele pergunta ao computador o que está
    #: aberto na hora de rodar. Uma lista escrita à mão envelheceria - o que
    #: está aberto hoje não é o que estava ontem.
    kind: Literal[
        "launch", "close", "close_all", "input", "media", "brightness", "power"
    ]
    #: Pausa depois do passo. O teto de 10 s é o mesmo do agente.
    wait_ms: int | None = Field(default=None, ge=0, le=10_000)

    #: `launch`: caminho do atalho, e onde a janela vai.
    id: str | None = Field(default=None, max_length=1024)
    zone: ZoneIn | None = None
    #: `close`: nome do processo ("slack", "outlook").
    name: str | None = Field(default=None, max_length=120)
    #: `input`: a ação de teclado, no mesmo formato do controle remoto.
    action: dict | str | None = None
    #: `brightness`: um ou outro, como no endpoint de brilho.
    level: int | None = Field(default=None, ge=0, le=100)
    delta: int | None = Field(default=None, ge=-100, le=100)

    @model_validator(mode="after")
    def campos_do_tipo(self) -> "StepIn":
        # Sem isto, um passo `launch` sem caminho chegaria ao computador e
        # falharia lá - longe de quem montou a automação, e com uma mensagem
        # sobre um programa vazio em vez de "faltou escolher o programa".
        faltando = {
            "launch": self.id,
            "close": self.name,
            "input": self.action,
            "media": self.action,
            "power": self.action,
        }.get(self.kind, "ok")
        if faltando is None:
            raise ValueError(f"passo {self.kind} está sem o campo obrigatório")
        if self.kind == "brightness" and (self.level is None) == (self.delta is None):
            raise ValueError("brilho: mande level ou delta, e apenas um dos dois")
        catalogo = {"media": MEDIA_ACTIONS, "power": POWER_ACTIONS}.get(self.kind)
        if catalogo is not None and self.action not in catalogo:
            raise ValueError(
                f"{self.kind}: {self.action!r} não é um comando conhecido "
                f"({', '.join(sorted(catalogo))})"
            )
        return self


class AutomationIn(BaseModel):
    """Uma automação criada pelo usuário."""

    name: str = Field(min_length=1, max_length=60)
    icon: str = Field(default="tune", max_length=32)
    #: O teto de 24 é o mesmo do agente, e não está aqui para a interface: é
    #: para o caso de uma mensagem adulterada mandar o computador fazer mil
    #: coisas.
    steps: list[StepIn] = Field(default_factory=list, max_length=24)
    #: Em qual computador ela roda. Vazio = escolher na hora.
    device_id: str = Field(default="", max_length=64)


class AutomationOut(AutomationIn):
    """O mesmo, com o identificador que o servidor gerou."""

    id: str


class AutomationsOut(BaseModel):
    automations: list[AutomationOut] = []


class StepResultOut(BaseModel):
    """O que aconteceu com um passo.

    Identificado pelo **índice**: dois passos podem ser idênticos ("baixar o
    volume" duas vezes), e o app precisa saber qual dos dois falhou.
    """

    index: int
    ok: bool
    error: str | None = None


class AutomationRunOut(BaseModel):
    """O resultado de cada passo, na ordem em que foram executados."""

    results: list[StepResultOut] = []


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
