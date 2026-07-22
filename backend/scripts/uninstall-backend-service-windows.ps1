# Remove o servico do backend do RemoteOne. Rode como ADMINISTRADOR.
#
# Mantem os dados (banco SQLite e segredo em C:\ProgramData\RemoteOne). Para
# apagar tudo, remova essa pasta manualmente depois.
#
# Uso (PowerShell como administrador):
#   powershell -ExecutionPolicy Bypass -File backend\scripts\uninstall-backend-service-windows.ps1

$ErrorActionPreference = "SilentlyContinue"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Abra o PowerShell como Administrador e rode de novo."
    return
}

# Para e remove a tarefa/servico.
Stop-ScheduledTask -TaskName "RemoteOneBackend"
Unregister-ScheduledTask -TaskName "RemoteOneBackend" -Confirm:$false

# Encerra o uvicorn que porventura ainda esteja rodando.
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like "*uvicorn app.main:app*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# Remove a regra de Firewall.
Remove-NetFirewallRule -DisplayName "RemoteOne backend 8000"

Write-Host "Servico do backend removido. Os dados em C:\ProgramData\RemoteOne foram mantidos."
