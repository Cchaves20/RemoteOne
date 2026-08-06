@echo off
rem Instala o agente do Deskside: dois cliques, sem terminal, sem administrador.
rem
rem Existe para quem recebe só o executavel. Quem tem o codigo-fonte pode
rem chamar direto: deskside-agent.exe install
rem
rem Este .cmd procura o executavel ao lado dele e, se nao achar, na pasta de
rem compilacao do projeto - assim serve tanto ao pacote pronto quanto a arvore
rem de desenvolvimento, sem duas versoes do mesmo arquivo.

setlocal
set "EXE=%~dp0deskside-agent.exe"
if not exist "%EXE%" set "EXE=%~dp0..\target\release\deskside-agent.exe"

if not exist "%EXE%" (
  echo Nao encontrei o deskside-agent.exe.
  echo.
  echo Coloque este arquivo na mesma pasta do executavel, ou compile antes:
  echo   cargo build --release
  echo.
  pause
  exit /b 1
)

rem A URL do backend e opcional: sem ela, vale a que ja estiver configurada.
"%EXE%" install %*

echo.
pause
