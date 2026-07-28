# Instala o agente do RemoteOne para iniciar em segundo plano no Windows.
#
# Usa a pasta "Inicializar" do usuário (NÃO exige administrador). Depois disso
# o agente:
#   - inicia sozinho toda vez que você faz login no Windows;
#   - roda oculto (sem janela de terminal);
#   - se reconecta sozinho e volta após um Wake-on-LAN / reinício.
#
# Uso (PowerShell na pasta do projeto):
#   powershell -ExecutionPolicy Bypass -File agent\scripts\install-agent-windows.ps1
#
# Opcional, se o backend NÃO estiver no mesmo PC do agente:
#   ... -BackendUrl ws://IP_DO_BACKEND:8000/ws/agent
# (o padrão é ws://127.0.0.1:8000/ws/agent, que serve quando o backend roda
#  na mesma máquina do agente.)

param(
    [string]$BackendUrl = ""
)

$ErrorActionPreference = "Stop"

# scripts/ -> agent/
$agentDir = Split-Path -Parent $PSScriptRoot

Write-Host "Compilando o agente em modo release (pode demorar na 1a vez)..."
Push-Location $agentDir
try {
    cargo build --release
} finally {
    Pop-Location
}

$exe = Join-Path $agentDir "target\release\remoteone-agent.exe"
if (-not (Test-Path $exe)) {
    throw "Executavel nao encontrado: $exe"
}

# URL do backend (opcional) como variavel de ambiente do usuario.
if ($BackendUrl -ne "") {
    [Environment]::SetEnvironmentVariable("REMOTEONE_BACKEND_URL", $BackendUrl, "User")
    $env:REMOTEONE_BACKEND_URL = $BackendUrl   # tambem para o start imediato abaixo
    Write-Host "Backend definido como $BackendUrl"
}

# Launcher .vbs: roda o .exe OCULTO (janela 0), sem piscar console, na sessao
# interativa (necessario para capturar a tela e injetar mouse/teclado).
$vbs = Join-Path $agentDir "start-agent-hidden.vbs"
@"
Set sh = CreateObject("WScript.Shell")
sh.Run """$exe""", 0, False
"@ | Set-Content -Encoding ASCII $vbs

# Coloca o launcher na pasta Inicializar do usuario (roda no logon, sem admin).
$startup = [Environment]::GetFolderPath("Startup")
$startupVbs = Join-Path $startup "RemoteOneAgent.vbs"
Copy-Item $vbs $startupVbs -Force

# Encerra instancia anterior (se houver) e inicia agora, sem esperar o logon.
Get-Process -Name "remoteone-agent" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process "wscript.exe" -ArgumentList "`"$startupVbs`""

Write-Host ""
Write-Host "Pronto! O agente roda em segundo plano e inicia com o Windows."
Write-Host "O codigo de pareamento aparece numa janelinha e tambem em:"
Write-Host "  %APPDATA%\remoteone\pairing-code.txt"
Write-Host ""
Write-Host "Para remover do inicio automatico:"
Write-Host "  powershell -ExecutionPolicy Bypass -File agent\scripts\uninstall-agent-windows.ps1"
