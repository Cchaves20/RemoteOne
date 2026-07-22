# Instala o agente do RemoteOne como tarefa em segundo plano no Windows.
#
# Depois disso o agente:
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
$taskName = "RemoteOneAgent"

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
    Write-Host "Backend definido como $BackendUrl"
}

# Launcher .vbs: roda o .exe OCULTO (janela 0), sem piscar console, na sessao
# interativa (necessario para capturar a tela e injetar mouse/teclado).
$vbs = Join-Path $agentDir "start-agent-hidden.vbs"
@"
Set sh = CreateObject("WScript.Shell")
sh.Run """$exe""", 0, False
"@ | Set-Content -Encoding ASCII $vbs

# Tarefa agendada: dispara no logon, reinicia se cair, sem limite de tempo.
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "Agente do RemoteOne (segundo plano)" -Force | Out-Null

# Inicia agora, sem esperar o proximo logon.
Start-ScheduledTask -TaskName $taskName

Write-Host ""
Write-Host "Pronto! O agente roda em segundo plano e inicia com o Windows."
Write-Host "O codigo de pareamento aparece numa janelinha e tambem em:"
Write-Host "  %APPDATA%\remoteone\pairing-code.txt"
Write-Host ""
Write-Host "Para remover do inicio automatico:"
Write-Host "  powershell -ExecutionPolicy Bypass -File agent\scripts\uninstall-agent-windows.ps1"
