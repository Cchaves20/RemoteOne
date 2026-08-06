@echo off
rem Remove o agente do Deskside do inicio automatico e apaga o executavel
rem instalado. A configuracao e o device_id ficam, para que reinstalar nao
rem obrigue a parear o computador de novo.

setlocal
set "EXE=%LOCALAPPDATA%\Programs\Deskside\deskside-agent.exe"
if not exist "%EXE%" set "EXE=%~dp0deskside-agent.exe"
if not exist "%EXE%" set "EXE=%~dp0..\target\release\deskside-agent.exe"

if not exist "%EXE%" (
  echo O Deskside nao parece estar instalado.
  echo.
  pause
  exit /b 0
)

"%EXE%" uninstall

echo.
pause
