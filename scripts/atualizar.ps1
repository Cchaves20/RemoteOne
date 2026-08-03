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
# ATENÇÃO ao editar: salve sempre como UTF-8 COM BOM, e não use travessão.
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
    [string]$ChaveSsh = ""
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

# --- código ------------------------------------------------------------------

Titulo "Código"
Passo "git pull ($Branch)"
if (-not (Executar "git" @("pull", "origin", $Branch) $raiz)) {
    Write-Host "  Não consegui atualizar o código. Resolva o git e rode de novo." -ForegroundColor Red
    exit 1
}

# --- agente ------------------------------------------------------------------

if ($Agente) {
    Titulo "Agente (Rust)"
    # O agente rodando segura o próprio .exe, e o build falha com
    # "Acesso negado (os error 5)". Parar antes evita isso.
    $vivos = Get-Process remoteone-agent -ErrorAction SilentlyContinue
    if ($vivos) {
        Passo "parando $($vivos.Count) instância(s) em execução"
        $vivos | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }

    Passo "cargo build --release"
    if (Executar "cargo" @("build", "--release") (Join-Path $raiz "agent")) {
        Write-Host "  Agente compilado." -ForegroundColor Green
    } else {
        $falhas += "agente"
        Write-Host "  Falha ao compilar o agente." -ForegroundColor Red
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
        Passo "flutter analyze"
        if (Executar "flutter" @("analyze") $cliente) {
            Write-Host "  App sem apontamentos." -ForegroundColor Green
        } else {
            # O Codemagic falha em qualquer apontamento, inclusive os "info".
            $falhas += "app (analyze)"
            Write-Host "  O analyze apontou algo - corrija antes de gastar build do Codemagic." -ForegroundColor Red
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
            "sudo docker compose -f docker-compose.lite.yml up -d --build"
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

# O que este código espera do servidor. Quando um recurso novo entra, o nome
# dele entra aqui - e o script passa a acusar servidor velho sozinho.
$esperado = @(
    "pairing", "input", "screen-jpeg", "apps", "wake-on-lan", "totp",
    "webrtc-signaling", "system-stats", "media-keys", "file-transfer"
)

Titulo "Conferência"
# Com paciência: o "docker compose up" volta quando o contêiner **inicia**, não
# quando a aplicação está pronta para responder. Perguntar na mesma hora acusa
# um servidor fora do ar que na verdade está só levantando.
$saude = $null
$tentativas = 6
for ($n = 1; $n -le $tentativas; $n++) {
    try {
        $saude = Invoke-RestMethod "https://$Dominio/health" -TimeoutSec 10
        break
    } catch {
        if ($n -lt $tentativas) {
            Passo "servidor ainda subindo, tentando de novo ($n/$tentativas)"
            Start-Sleep -Seconds 5
        }
    }
}

if ($null -eq $saude) {
    Write-Host "  Não consegui falar com https://$Dominio/health" -ForegroundColor Red
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
