# Remove o agente do RemoteOne do inicio automatico do Windows.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File agent\scripts\uninstall-agent-windows.ps1

$ErrorActionPreference = "SilentlyContinue"

# Remove o launcher da pasta Inicializar.
$startup = [Environment]::GetFolderPath("Startup")
Remove-Item (Join-Path $startup "RemoteOneAgent.vbs") -Force

# Remove uma eventual Tarefa Agendada de versoes anteriores do instalador.
Unregister-ScheduledTask -TaskName "RemoteOneAgent" -Confirm:$false

# Encerra o processo que porventura ainda esteja rodando.
Get-Process -Name "remoteone-agent" | Stop-Process -Force

# Remove a variavel de ambiente do backend (se foi definida na instalacao).
[Environment]::SetEnvironmentVariable("REMOTEONE_BACKEND_URL", $null, "User")

# Remove o launcher oculto da pasta do projeto.
$agentDir = Split-Path -Parent $PSScriptRoot
Remove-Item (Join-Path $agentDir "start-agent-hidden.vbs") -Force

Write-Host "Agente removido do inicio automatico."
