# Remove o agente do RemoteOne do inicio automatico do Windows.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File agent\scripts\uninstall-agent-windows.ps1

$ErrorActionPreference = "SilentlyContinue"

$taskName = "RemoteOneAgent"

# Para e remove a tarefa agendada.
Stop-ScheduledTask -TaskName $taskName
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

# Encerra o processo que porventura ainda esteja rodando.
Get-Process -Name "remoteone-agent" | Stop-Process -Force

# Remove a variavel de ambiente do backend (se foi definida na instalacao).
[Environment]::SetEnvironmentVariable("REMOTEONE_BACKEND_URL", $null, "User")

# Remove o launcher oculto.
$agentDir = Split-Path -Parent $PSScriptRoot
Remove-Item (Join-Path $agentDir "start-agent-hidden.vbs") -ErrorAction SilentlyContinue

Write-Host "Agente removido do inicio automatico."
