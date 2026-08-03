<#
.SINOPSE
    Atualiza as três pontas do RemoteOne de um terminal só: o agente no
    Windows, o app Flutter e o backend no VPS.

.DESCRIÇÃO
    Sem isto são três terminais (PowerShell do agente, PowerShell do app e SSH
    do servidor) e a chance de esquecer um deles - que foi a causa de metade
    dos defeitos que investigamos: componente velho conversando com componente
    novo.

    No fim, o script pergunta ao /health o que o servidor realmente tem, e
    compara com o que este código espera. É a checagem que responde "qual peça
    está desatualizada?" sem SSH nenhum.

.EXEMPLO
    .\scripts\atualizar.ps1
    Atualiza tudo (agente, app e VPS).

.EXEMPLO
    .\scripts\atualizar.ps1 -Agente -Rodar
    Só o agente, e o deixa rodando à vista neste terminal.

.EXEMPLO
    .\scripts\atualizar.ps1 -Vps
    Só o servidor.
#>
# ATENÇÃO ao editar: salve sempre como UTF-8 COM BOM, não use travessão, e não
# crie variável com o nome de um parâmetro.
#
# E `\"` NÃO escapa aspas no PowerShell: o escape é `""` (ou a crase). Uma
# linha como `"... '\"features\"'"` não compila, e o erro aponta para o token
# seguinte. Quando o texto precisar de aspas, prefira reescrever para não
# precisar delas - foi o que se fez no `grep` da conferência do deploy.
#
# Nomes de variável no PowerShell são insensíveis a maiúsculas: `$agente` **é**
# o parâmetro `[switch]$Agente`. Uma linha inocente como
# `$agente = Join-Path $raiz "agent"` põe um texto dentro de um switch e derruba
# o script com "não é possível converter System.String no tipo
# SwitchParameter" - um erro que aponta para o próprio arquivo e não diz qual
# linha. Custou quatro rodadas de depuração. Os nomes tomados hoje são:
# Agente, App, Vps, Rodar, Ocultar, Branch, Dominio, Servidor, ChaveSsh, NoPull.
#
# O PowerShell 5.1 lê .ps1 sem BOM como ANSI. Nessa leitura, o travessão vira
# a aspa curva ", que ele aceita como delimitador de string - e uma aspa solta
# no meio de um comentário quebra o arquivo inteiro, com erros que apontam
# para linhas que não têm nada de errado.
[CmdletBinding()]
param(
    # Sem nenhuma destas três, o script faz tudo.
    [switch]$Agente,
    [switch]$App,
    [switch]$Vps,

    # Deixa o agente rodando à vista no fim, para acompanhar as mensagens.
    [switch]$Rodar,

    # Instala o agente para subir sozinho (oculto) no logon, em vez de rodar
    # à vista. Não combina com -Rodar.
    [switch]$Ocultar,

    [string]$Branch = "claude/testing-strategy-multiplatform-0nztwm",
    [string]$Dominio = "caio-remoteone.duckdns.org",

    # Servidor e chave do SSH. O padrão pega a chave mais recente em Downloads;
    # passe -ChaveSsh se a sua estiver noutro lugar.
    [string]$Servidor = "ubuntu@147.15.45.45",
    [string]$ChaveSsh = "",

    # Uso interno: pula o `git pull`. O script se reinicia sozinho quando o
    # pull traz uma versão nova dele mesmo, e a segunda passada não deve
    # puxar de novo - nem poder virar laço.
    [switch]$NoPull
)

$ErrorActionPreference = "Stop"

# Nenhuma etapa escolhida = todas.
if (-not ($Agente -or $App -or $Vps)) {
    $Agente = $true; $App = $true; $Vps = $true
}

$raiz = Split-Path -Parent $PSScriptRoot
$falhas = @()

function Titulo($texto) {
    Write-Host ""
    Write-Host "=== $texto ===" -ForegroundColor Cyan
}

function Passo($texto) { Write-Host "  $texto" -ForegroundColor DarkGray }

# Roda um programa externo e devolve $false se ele falhar, sem derrubar o
# script: uma etapa quebrada não deve impedir as outras de rodarem.
function Executar($programa, $argumentos, $onde) {
    Push-Location $onde
    try {
        & $programa @argumentos
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

# Encerra qualquer agente em execução.
#
# `-ErrorAction SilentlyContinue` nos dois: não haver agente rodando é o caso
# normal, e sem isso o script inteiro cairia por causa dele.
function PararAgente {
    $vivos = Get-Process remoteone-agent -ErrorAction SilentlyContinue
    if ($vivos) {
        Passo "parando $($vivos.Count) agente(s) em execução"
        $vivos | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
}

# Diz quem tem o arquivo aberto, quando dá para descobrir sem ferramenta extra.
#
# Existe porque "Acesso negado" sozinho não é diagnóstico: manda a pessoa
# adivinhar entre antivírus, Explorer, uma cópia do agente rodando e um build
# anterior travado.
function QuemSegura($caminho) {
    if (-not (Test-Path $caminho)) {
        Write-Host "  (o executável nem existe ainda: $caminho)" -ForegroundColor DarkGray
        return
    }
    $donos = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path -ieq $caminho
    }
    if ($donos) {
        foreach ($d in $donos) {
            Write-Host "  Rodando: $($d.ProcessName) (PID $($d.Id))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Nenhum processo com esse executável - provavelmente o antivírus." -ForegroundColor DarkGray
    }
}

# Reinstala o agente com o binário recém-compilado, se ele estava instalado.
#
# Sem isto, atualizar **derruba** o agente e não o levanta: o `PararAgente` o
# encerra para liberar o .exe, e o instalado só voltaria no próximo login. O
# sintoma seria o computador sumir do app depois de cada atualização, sem nada
# explicando - e mexer no `atualizar` é justamente o que ninguém associa a isso.
#
# `install` sem URL preserva o backend já configurado: atualizar não é hora de
# reescrever configuração.
#
# Não faz nada com `-Ocultar` (que já instala, logo abaixo) nem com `-Rodar`
# (que quer o agente à vista neste terminal): nos dois casos o usuário pediu
# outra coisa, e subir um segundo agente oculto disputaria o mesmo device_id.
function ReinstalarSeInstalado($pasta) {
    if ($Ocultar -or $Rodar) { return }

    $jaInstalado = Join-Path $env:LOCALAPPDATA "Programs\RemoteOne\remoteone-agent.exe"
    if (-not (Test-Path $jaInstalado)) {
        Passo "agente não está instalado: nada a reiniciar"
        return
    }

    Passo "reinstalando com o binário novo"
    $recem = Join-Path $pasta "target\release\remoteone-agent.exe"
    if (Executar $recem @("install") $pasta) {
        Write-Host "  Agente reinstalado e rodando." -ForegroundColor Green
    } else {
        $script:falhas += "agente (reinstalar)"
        Write-Host "  Compilou, mas não reinstalou. Rode a mão:" -ForegroundColor Red
        Write-Host "    $recem install" -ForegroundColor Red
    }
}

# --- código ------------------------------------------------------------------

Titulo "Código"

# O PowerShell lê o arquivo inteiro na memória antes de executar a primeira
# linha. Como o `git pull` abaixo pode trazer uma versão nova **deste script**,
# a execução em curso continuaria sendo a antiga - e qualquer correção feita
# aqui só valeria na próxima vez, sem nada dizendo isso.
#
# Aconteceu de verdade: uma correção no relatório do `flutter analyze` foi
# baixada e a mesma execução imprimiu a mensagem errada, como se a correção não
# tivesse funcionado.
$eu = $PSCommandPath
$antes = (Get-FileHash $eu -Algorithm SHA256).Hash

if ($NoPull) {
    Passo "código já atualizado nesta rodada"
} else {
    Passo "git pull ($Branch)"
    if (-not (Executar "git" @("pull", "origin", $Branch) $raiz)) {
        Write-Host "  Não consegui atualizar o código. Resolva o git e rode de novo." -ForegroundColor Red
        exit 1
    }
}

if (-not $NoPull -and (Get-FileHash $eu -Algorithm SHA256).Hash -ne $antes) {
    Write-Host "  O próprio script mudou. Recomeçando com a versão nova." -ForegroundColor Yellow

    # **Processo novo**, e não `& $eu` no mesmo processo. Duas razões:
    #
    # - Só um processo novo garante que o arquivo seja lido do disco de novo.
    #   Reinvocar aqui dentro reaproveita a árvore já carregada em memória, que
    #   é justamente o que se quer trocar.
    # - Os argumentos vão como **texto**, montados um a um, e não por splat de
    #   `$PSBoundParameters`. O splat parece equivalente e não é: a ligação de
    #   parâmetros por `-File` é posicional e por texto, e a primeira versão
    #   disto morreu com "não é possível converter System.String em
    #   SwitchParameter" - um erro que não diz nada a quem só queria atualizar.
    $passar = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $passar += "-$($kv.Key)" }
        } else {
            $passar += "-$($kv.Key)"
            $passar += [string]$kv.Value
        }
    }
    # `-NoPull` para a segunda passada não repetir o pull (que agora não traria
    # nada) e, sobretudo, para não haver como isto virar laço.
    $passar += "-NoPull"

    & powershell -NoProfile -ExecutionPolicy Bypass -File $eu @passar
    exit $LASTEXITCODE
}

# --- agente ------------------------------------------------------------------

if ($Agente) {
    Titulo "Agente (Rust)"
    # O agente rodando segura o próprio .exe, e o build falha com
    # "Acesso negado (os error 5)". Parar antes evita isso.
    PararAgente

    $pastaAgente = Join-Path $raiz "agent"
    Passo "cargo build --release"
    if (Executar "cargo" @("build", "--release") $pastaAgente) {
        Write-Host "  Agente compilado." -ForegroundColor Green
        ReinstalarSeInstalado $pastaAgente
    } else {
        # "Acesso negado" quase nunca é erro de código: é alguém segurando o
        # arquivo. Costuma ser o antivírus terminando de examinar o .exe recém
        # gravado, e nesse caso esperar resolve. Uma segunda tentativa custa
        # segundos e evita mandar o usuário caçar um problema que não existe.
        Write-Host "  Falhou. Vendo quem está segurando o executável..." -ForegroundColor Yellow
        QuemSegura (Join-Path $pastaAgente "target\release\remoteone-agent.exe")
        PararAgente
        Start-Sleep -Seconds 3
        Passo "cargo build --release (segunda tentativa)"
        if (Executar "cargo" @("build", "--release") $pastaAgente) {
            Write-Host "  Agente compilado." -ForegroundColor Green
            ReinstalarSeInstalado $pastaAgente
        } else {
            $falhas += "agente"
            Write-Host "  Falha ao compilar o agente." -ForegroundColor Red
            Write-Host "  Se disse 'Acesso negado', o .exe está preso por outro programa." -ForegroundColor Red
            Write-Host "  Feche o Explorer nessa pasta, ou reinicie e rode de novo." -ForegroundColor Red
        }
    }
}

# --- app ---------------------------------------------------------------------

if ($App) {
    Titulo "App (Flutter)"
    $cliente = Join-Path $raiz "client"
    Passo "flutter pub get"
    if (-not (Executar "flutter" @("pub", "get") $cliente)) {
        $falhas += "app (pub get)"
    } else {
        # `--fatal-infos`: sem isto o `flutter analyze` **sai com sucesso**
        # quando só há apontamentos de nível "info", e este script dizia "App
        # sem apontamentos" com três problemas impressos logo acima. Um
        # verificador que não distingue "passou" de "passou mas reclamou" é
        # pior do que não ter verificador: ele ensina a ignorar a saída.
        Passo "flutter analyze --fatal-infos"
        if (Executar "flutter" @("analyze", "--fatal-infos") $cliente) {
            Write-Host "  App sem apontamentos." -ForegroundColor Green
        } else {
            $falhas += "app (analyze)"
            Write-Host "  O analyze apontou algo - a lista está logo acima." -ForegroundColor Red
            Write-Host "  Corrija antes de gastar build do Codemagic." -ForegroundColor Red
        }
    }
}

# --- vps ---------------------------------------------------------------------

if ($Vps) {
    Titulo "Backend (VPS)"
    if ($ChaveSsh -eq "") {
        # A chave da Oracle costuma estar em Downloads; pega a mais recente.
        $chaves = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter "*.key" -ErrorAction SilentlyContinue
        $achada = $chaves | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($achada) { $ChaveSsh = $achada.FullName }
    }

    if ($ChaveSsh -eq "" -or -not (Test-Path $ChaveSsh)) {
        $falhas += "vps (chave SSH não encontrada)"
        Write-Host "  Não achei a chave SSH. Rode com -ChaveSsh C:\caminho\sua-chave.key" -ForegroundColor Red
    } else {
        Passo "ssh $Servidor (git + docker compose)"
        # Encadeado com && porque cada "ssh" abre uma sessão nova: em chamadas
        # separadas, o "cd" da primeira não valeria para a segunda. O "&&" aqui
        # é texto dentro de uma string - quem o executa é o shell do Linux, não
        # o PowerShell (que nem o suporta na versão 5.1).
        $passos = @(
            "cd ~/RemoteOne",
            "git fetch origin $Branch",
            "git checkout $Branch",
            "git reset --hard origin/$Branch",
            "cd deploy",
            "sudo docker compose -f docker-compose.lite.yml up -d --build",
            # O Caddyfile entra por volume: mudá-lo no disco não muda nada no
            # Caddy que já está rodando, e o `up -d` não recria o contêiner
            # porque, do ponto de vista dele, o serviço não mudou. O resultado
            # foi um proxy quebrado no ar com a correção parada no disco.
            #
            # `caddy reload` troca a configuração **sem derrubar** conexão
            # nenhuma - e, se a configuração nova estiver errada, ele recusa e
            # mantém a antiga de pé. Ou seja, também serve de validação.
            "sudo docker compose -f docker-compose.lite.yml exec -T caddy caddy reload --config /etc/caddy/Caddyfile",
            # Prova, do próprio servidor, que o proxy leva /health à API e não
            # ao app web. Sem isto o deploy termina "com sucesso" tendo posto
            # um roteamento quebrado no ar - foi exatamente o que aconteceu, e
            # o erro só apareceu na conferência, apontando para o lado errado.
            "curl -sf https://$Dominio/health | grep -q webrtc-signaling"
        )
        $remoto = $passos -join " && "
        & ssh -i $ChaveSsh -o StrictHostKeyChecking=accept-new $Servidor $remoto
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Backend atualizado." -ForegroundColor Green
        } else {
            $falhas += "vps"
            Write-Host "  Falha ao atualizar o VPS." -ForegroundColor Red
        }
    }
}

# --- conferência -------------------------------------------------------------

# O que este código espera do servidor. Precisa espelhar a lista FEATURES do
# `backend/app/main.py`: quando um recurso novo entra lá, o nome dele entra
# aqui, e o script passa a acusar servidor velho sozinho.
#
# Ficou seis recursos atrasada sem ninguém notar - e uma conferência que não
# confere o que existe hoje é a mesma armadilha do `flutter analyze` que saía
# com sucesso: parece verificação, e não é.
$esperado = @(
    "pairing", "input", "screen-jpeg", "apps",
    "wake-on-lan", "totp", "webrtc-signaling", "system-stats",
    "media-keys", "file-transfer", "foreground-app", "audio-stream",
    "ice-servers", "clipboard", "monitors", "control-profiles"
)

Titulo "Conferência"
# Com paciência: o "docker compose up" volta quando o contêiner **inicia**, não
# quando a aplicação está pronta para responder. Perguntar na mesma hora acusa
# um servidor fora do ar que na verdade está só levantando.
$saude = $null
$bruto = ""
$tentativas = 6
for ($n = 1; $n -le $tentativas; $n++) {
    try {
        # `Invoke-WebRequest` e não `Invoke-RestMethod`: guardar o texto cru é
        # o que permite **mostrar** o que chegou quando a conferência reprova.
        # Sem isso, uma resposta 200 que não seja o JSON esperado - a página do
        # app, por exemplo, quando o proxy está mal roteado - vira "servidor
        # desatualizado", e o diagnóstico sai pelo lado errado. Aconteceu.
        $resposta = Invoke-WebRequest "https://$Dominio/health" -TimeoutSec 10 -UseBasicParsing
        $bruto = $resposta.Content
        $saude = $bruto | ConvertFrom-Json
    } catch {
        $saude = $null
        if ($bruto -eq "") { $bruto = $_.Exception.Message }
    }

    # Só para de tentar quando a resposta tem cara de saúde. Um 200 sem
    # `features` costuma ser o servidor ainda subindo - ou o proxy entregando
    # outra coisa -, e desistir na primeira vez perde os dois casos.
    if ($null -ne $saude -and $null -ne $saude.features) { break }
    if ($n -lt $tentativas) {
        Passo "servidor ainda subindo, tentando de novo ($n/$tentativas)"
        Start-Sleep -Seconds 5
    }
}

if ($null -eq $saude -or $null -eq $saude.features) {
    Write-Host "  https://$Dominio/health não respondeu o que se espera." -ForegroundColor Red
    $recorte = $bruto
    if ($recorte.Length -gt 300) { $recorte = $recorte.Substring(0, 300) + "..." }
    Write-Host "  Recebido: $recorte" -ForegroundColor DarkGray
    Write-Host "  Se veio HTML, o proxy está mandando /health para o app web." -ForegroundColor DarkGray
    $falhas += "health"
} else {
    $faltando = $esperado | Where-Object { $saude.features -notcontains $_ }
    if ($faltando) {
        Write-Host "  O servidor não tem: $($faltando -join ', ')" -ForegroundColor Red
        Write-Host "  (é ele que está velho, não o app nem o agente)" -ForegroundColor DarkGray
        $falhas += "vps (desatualizado)"
    } else {
        Write-Host "  Servidor com tudo o que este código espera." -ForegroundColor Green
    }
}

# --- resumo ------------------------------------------------------------------

Titulo "Resumo"
if ($falhas.Count -eq 0) {
    Write-Host "  Tudo atualizado." -ForegroundColor Green
} else {
    Write-Host "  Pendências: $($falhas -join ', ')" -ForegroundColor Yellow
}

if ($Ocultar) {
    Titulo "Agente oculto"
    # Quem instala agora é o próprio executável: um `.ps1` não entra na
    # verificação cruzada para Windows nem tem teste, e este projeto já pagou
    # caro por código que ninguém verifica.
    & (Join-Path $raiz "agent\target\release\remoteone-agent.exe") install "wss://$Dominio/ws/agent"
} elseif ($Rodar) {
    Titulo "Agente (Ctrl+C para sair)"
    & (Join-Path $raiz "agent\target\release\remoteone-agent.exe")
}
