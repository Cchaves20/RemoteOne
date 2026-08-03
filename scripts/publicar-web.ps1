<#
.SINOPSE
    Compila o app para a web e publica no VPS, no mesmo dominio da API.

.DESCRICAO
    O app passa a abrir em https://SEU_DOMINIO no navegador de qualquer
    maquina - inclusive as que nao tem loja de aplicativos, como o HarmonyOS
    do MateBook.

    Curto de proposito: dois comandos com uma troca de pasta atomica no fim.
    O equivalente a mao esta em docs/app-no-navegador.md, para o caso de este
    script atrapalhar em vez de ajudar.

.EXEMPLO
    .\scripts\publicar-web.ps1
#>
# ATENCAO ao editar: UTF-8 COM BOM, sem travessao, e nenhuma variavel com o
# nome de um parametro (Servidor, ChaveSsh, Dominio). Ver o cabecalho do
# atualizar.ps1: as tres armadilhas ja custaram horas neste projeto.
[CmdletBinding()]
param(
    [string]$Dominio = "caio-remoteone.duckdns.org",
    [string]$Servidor = "ubuntu@147.15.45.45",
    [string]$ChaveSsh = ""
)

$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot

if ($ChaveSsh -eq "") {
    $chaves = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter "*.key" -ErrorAction SilentlyContinue
    $achada = $chaves | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($achada) { $ChaveSsh = $achada.FullName }
}
if ($ChaveSsh -eq "" -or -not (Test-Path $ChaveSsh)) {
    Write-Host "Nao achei a chave SSH. Rode com -ChaveSsh C:\caminho\sua-chave.key" -ForegroundColor Red
    exit 1
}

$cliente = Join-Path $raiz "client"

# Este repositorio nao versiona pastas de plataforma: elas sao geradas na hora
# do build. O Codemagic faz o mesmo com a `ios/`. Sem este passo o Flutter
# recusa com "This project is not configured for the web".
#
# `flutter create` num projeto que ja existe so acrescenta o que falta: nao
# toca em `lib/` nem no `pubspec.yaml`.
if (-not (Test-Path (Join-Path $cliente "web\index.html"))) {
    Write-Host ""
    Write-Host "=== Gerando a pasta web/ (primeira vez) ===" -ForegroundColor Cyan
    Push-Location $cliente
    try {
        & flutter create --org com.remoteone --project-name remoteone_client --platforms=web .
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Nao consegui gerar a pasta web/." -ForegroundColor Red
        exit 1
    }

    # O `flutter create` poe o nome do pacote no titulo da aba. Trocar aqui
    # evita versionar a pasta inteira so por causa de uma linha.
    $indice = Join-Path $cliente "web\index.html"
    $texto = Get-Content $indice -Raw
    $texto = $texto -replace "<title>[^<]*</title>", "<title>RemoteOne</title>"
    $texto = $texto -replace 'content="remoteone_client"', 'content="RemoteOne"'
    Set-Content -Path $indice -Value $texto -Encoding UTF8
}

Write-Host ""
Write-Host "=== Compilando o app para a web ===" -ForegroundColor Cyan
Push-Location $cliente
try {
    & flutter build web --release
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Falha no build. Nada foi publicado." -ForegroundColor Red
    exit 1
}

$saida = Join-Path $cliente "build\web"
if (-not (Test-Path (Join-Path $saida "index.html"))) {
    Write-Host "  O build terminou mas nao gerou index.html em $saida" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Enviando ao VPS ===" -ForegroundColor Cyan

# Envia para um nome novo e so entao troca. Copiar por cima deixaria o app
# quebrado durante o envio - meia dezena de arquivos novos convivendo com os
# antigos e um `main.dart.js` que nao casa com o `index.html`.
& scp -r -i $ChaveSsh $saida "${Servidor}:~/RemoteOne/deploy/app-novo"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Falha ao enviar. O app no ar continua o de antes." -ForegroundColor Red
    exit 1
}

& ssh -i $ChaveSsh $Servidor "rm -rf ~/RemoteOne/deploy/app && mv ~/RemoteOne/deploy/app-novo ~/RemoteOne/deploy/app"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Enviei, mas nao consegui trocar a pasta no servidor." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Publicado: https://$Dominio" -ForegroundColor Green
Write-Host "  O Caddy le os arquivos do disco: nao precisa reiniciar nada." -ForegroundColor DarkGray
