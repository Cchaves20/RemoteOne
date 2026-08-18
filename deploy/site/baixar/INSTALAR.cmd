@echo off
rem ============================================================================
rem  Deskside - instalador
rem
rem  Duplo clique neste arquivo instala o Deskside neste computador.
rem
rem  SEM ACENTOS, de proposito. O cmd.exe do Windows em portugues abre .cmd na
rem  pagina de codigo 850, e nao em UTF-8: um "instalacao" com cedilha sai como
rem  "instala‡Æo" na tela. Um instalador que parece corrompido nao inspira quem
rem  ja esta desconfiado do aviso do SmartScreen.
rem
rem  %~dp0 e a pasta DESTE arquivo, com a barra no fim. Sem ela, o duplo clique
rem  a partir de um .zip aberto pelo Explorer rodaria com o diretorio atual em
rem  C:\Windows\system32 - e o .exe ao lado nao seria encontrado.
rem ============================================================================

setlocal
set "AQUI=%~dp0"
set "AGENTE=%AQUI%deskside-agent.exe"

echo.
echo   Deskside - instalando neste computador
echo   ======================================
echo.

if not exist "%AGENTE%" (
  echo   ERRO: nao encontrei o deskside-agent.exe nesta pasta.
  echo.
  echo   Se voce baixou um .zip, e provavel que tenha aberto o INSTALAR.cmd
  echo   de dentro dele. O Windows abre o .zip como se fosse uma pasta, mas os
  echo   arquivos ainda estao comprimidos e nao veem uns aos outros.
  echo.
  echo   Extraia o .zip primeiro ^(clique com o direito ^> Extrair Tudo^) e
  echo   rode o INSTALAR.cmd de dentro da pasta extraida.
  echo.
  pause
  exit /b 1
)

rem Nao precisa de administrador: a instalacao e da conta do usuario. Pedir
rem elevacao seria um passo a mais que assusta, sem ganho nenhum.
"%AGENTE%" install
set CODIGO=%ERRORLEVEL%

echo.
if "%CODIGO%"=="0" (
  echo   Pronto. O Deskside sobe junto com o Windows, oculto.
  echo.
  echo   O codigo de pareamento aparece numa janelinha e no icone ao lado do
  echo   relogio. Digite-o no aplicativo do celular para ligar os dois.
) else (
  echo   A instalacao nao terminou ^(codigo %CODIGO%^).
  echo   A mensagem acima diz o motivo. Se precisar de ajuda, escreva para
  echo   contato@deskside.com.br e mande essa mensagem junto.
)

echo.
rem `pause` porque o duplo clique fecha a janela ao terminar. Sem ele, tanto o
rem "pronto" quanto o motivo do erro apareceriam por um piscar de olhos.
pause
endlocal
