# Instala o backend do Deskside como servico do Windows (sobe no BOOT, ANTES
# do login, sem Docker e sem Postgres/Redis — usa SQLite).
#
# Roda como conta SYSTEM via Tarefa Agendada com gatilho "Ao iniciar". Um
# servidor de rede nao precisa do desktop, entao a Sessao 0 (sem login) serve.
#
# PRECISA de PowerShell como ADMINISTRADOR (servico = privilegio de sistema).
#
# Uso (PowerShell "Executar como administrador", na pasta do projeto):
#   powershell -ExecutionPolicy Bypass -File backend\scripts\install-backend-service-windows.ps1
#
# O app passa a alcancar o backend em http://IP_DO_PC:8000 mesmo com o PC
# apenas ligado (sem ninguem logado).

$ErrorActionPreference = "Stop"

# --- exige administrador -----------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Abra o PowerShell como Administrador e rode de novo (o servico exige isso)."
}

# backend/scripts -> backend
$backendDir = Split-Path -Parent $PSScriptRoot
$taskName = "DesksideBackend"
$dataDir = "C:\ProgramData\Deskside"
$secretFile = Join-Path $dataDir "jwt-secret.txt"
$dbFile = Join-Path $dataDir "deskside.db"
$launcher = Join-Path $dataDir "run-backend.cmd"

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

# --- ambiente Python (venv) --------------------------------------------------
$venv = Join-Path $backendDir ".venv"
$py = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $py)) {
    Write-Host "Criando ambiente Python em $venv ..."
    python -m venv $venv
}
Write-Host "Instalando dependencias do backend (pode demorar na 1a vez)..."
& $py -m pip install --upgrade pip | Out-Null
& $py -m pip install -e $backendDir | Out-Null

# --- segredo JWT persistente (mantem os logins entre reinstalacoes) ----------
if (-not (Test-Path $secretFile)) {
    $secret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ })
    Set-Content -Path $secretFile -Value $secret -Encoding ASCII -NoNewline
    Write-Host "Segredo JWT gerado em $secretFile"
}

# --- launcher que o servico executa ------------------------------------------
# SQLite com barras normais na URL. Le o segredo do arquivo (nao fica no .cmd).
$dbUrl = "sqlite:///" + ($dbFile -replace '\\', '/')
@"
@echo off
for /f "usebackq delims=" %%s in ("$secretFile") do set DESKSIDE_JWT_SECRET=%%s
set DESKSIDE_DATABASE_URL=$dbUrl
cd /d "$backendDir"
"$py" -m uvicorn app.main:app --host 0.0.0.0 --port 8000
"@ | Set-Content -Encoding ASCII $launcher

# --- libera a porta 8000 no Firewall (senao o celular da timeout) ------------
if (-not (Get-NetFirewallRule -DisplayName "Deskside backend 8000" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Deskside backend 8000" -Direction Inbound `
        -LocalPort 8000 -Protocol TCP -Action Allow | Out-Null
    Write-Host "Regra de Firewall criada (TCP 8000 liberada)."
}

# --- tarefa agendada como SYSTEM, no boot ------------------------------------
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$launcher`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Backend do Deskside (servico, sem login)" -Force | Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host ""
Write-Host "Pronto! O backend roda como servico e sobe no boot, sem login."
Write-Host "Teste em: http://localhost:8000/health"
Write-Host ""
Write-Host "IMPORTANTE: este servico usa um banco SQLite novo (nao o do Docker)."
Write-Host "Cadastre a conta uma vez no app e refaca o pareamento."
Write-Host ""
Write-Host "Para remover:"
Write-Host "  backend\scripts\uninstall-backend-service-windows.ps1  (como admin)"
