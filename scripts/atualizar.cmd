@echo off
REM Atalho para o atualizar.ps1.
REM
REM Existe por causa da politica de execucao do Windows, que bloqueia qualquer
REM .ps1 por padrao. Um .cmd nao passa por ela e chama o PowerShell ja com a
REM excecao — assim `scripts\atualizar` funciona em qualquer maquina, sem
REM precisar afrouxar a politica do sistema inteiro.
REM
REM Os argumentos passam adiante: scripts\atualizar -Agente -Rodar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0atualizar.ps1" %*
