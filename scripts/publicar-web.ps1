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

$ssh = @("-i", $ChaveSsh, "-o", "StrictHostKeyChecking=accept-new")

# Limpa um envio interrompido antes de comecar. Se `app-novo` ja existir, o
# `scp -r` nao substitui: ele deposita a pasta DENTRO dela, virando
# `app-novo/web`. O deploy terminaria "com sucesso" servindo 404 em tudo.
& ssh @ssh $Servidor "rm -rf RemoteOne/deploy/app-novo"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Nao consegui limpar o envio anterior no servidor." -ForegroundColor Red
    exit 1
}

# Envia para um nome novo. Copiar por cima da pasta no ar deixaria o app
# quebrado durante o envio - arquivos novos convivendo com os antigos e um
# `main.dart.js` que nao casa com o `index.html`. Sem `~` no destino: o scp
# moderno fala SFTP, e o til nao e expandido; o caminho relativo ja sai do
# diretorio do usuario nos dois modos.
& scp -r -i $ChaveSsh -o StrictHostKeyChecking=accept-new $saida "${Servidor}:RemoteOne/deploy/app-novo"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Falha ao enviar. O app no ar continua o de antes." -ForegroundColor Red
    exit 1
}

# A troca substitui o CONTEUDO da pasta, e nao a pasta.
#
# `deploy/app` esta montada no contedor do Caddy (`./app:/srv/app:ro`), e um
# bind mount prende o contedor ao **inode**. Um `rm -rf app && mv app-novo app`
# cria um inode novo: o disco do VPS teria o app atualizado e o Caddy seguiria
# servindo o antigo - ou uma pasta vazia - para sempre, sem erro nenhum. E a
# mesma armadilha que ja custou uma tarde com o Caddyfile montado como arquivo
# solto (ver docker-compose.lite.yml).
#
# O `chown` existe porque quem cria a pasta na primeira subida e o Docker, como
# root; sem ele o `find` abaixo bate em "permission denied".
#
# Ha uma janela de fracao de segundo entre apagar e copiar em que o site
# responde 404. E um envio manual de uma pessoa so; nao vale a complexidade de
# um esquema de duas pastas com link simbolico para fecha-la.
$troca = @(
    'cd RemoteOne/deploy',
    'sudo mkdir -p app',
    'sudo chown -R $(id -u):$(id -g) app',
    'find app -mindepth 1 -delete',
    'cp -a app-novo/. app/',
    'rm -rf app-novo'
) -join ' && '

& ssh @ssh $Servidor $troca
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Enviei, mas nao consegui trocar os arquivos no servidor." -ForegroundColor Red
    exit 1
}

# Conferencia: quem responde na raiz tem que ser o app, e nao a API nem um 404.
#
# Procura por "flutter" no HTML, e nao por um arquivo especifico: o nome do
# carregador mudou entre versoes do Flutter (`flutter.js`, depois
# `flutter_bootstrap.js`), e a conferencia nao pode quebrar por causa disso.
# Buscar um asset pela URL tambem nao serve: com o `try_files` do Caddy, um
# `main.dart.js` ausente responde o index.html com 200.
& ssh @ssh $Servidor "curl -sf https://$Dominio/ | grep -qi flutter"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Publiquei, mas a pagina no ar nao parece o app Flutter." -ForegroundColor Red
    Write-Host "  Confira o roteamento do Caddy (deploy/caddy/Caddyfile)." -ForegroundColor DarkGray
    exit 1
}

Write-Host ""
Write-Host "  Publicado: https://$Dominio" -ForegroundColor Green
Write-Host "  O Caddy le os arquivos do disco: nao precisa reiniciar nada." -ForegroundColor DarkGray
