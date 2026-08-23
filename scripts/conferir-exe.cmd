@echo off
REM Atalho para o conferir-exe.ps1.
REM
REM Existe pelo mesmo motivo do atualizar.cmd: a politica de execucao do Windows
REM bloqueia qualquer .ps1 por padrao, com a mensagem "a execucao de scripts foi
REM desabilitada neste sistema". Um .cmd nao passa por ela e chama o PowerShell
REM ja com a excecao - so para este arquivo, sem afrouxar a politica da maquina.
REM
REM Uso:
REM   scripts\conferir-exe deploy\site\baixar\Deskside.exe -Esperado x64
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0conferir-exe.ps1" %*
exit /b %ERRORLEVEL%
