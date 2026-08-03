@echo off
REM Atalho para o publicar-web.ps1 (a politica de execucao bloqueia .ps1 direto).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publicar-web.ps1" %*
