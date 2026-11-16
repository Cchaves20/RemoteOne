@echo off
REM Atalho para o atualizar.ps1.
REM
REM Existe por causa da politica de execucao do Windows, que bloqueia qualquer
REM .ps1 por padrao. Um .cmd nao passa por ela e chama o PowerShell ja com a
REM excecao - assim `scripts\atualizar` funciona em qualquer maquina, sem
REM precisar afrouxar a politica do sistema inteiro.
REM
REM Os argumentos passam adiante: scripts\atualizar -Agente -Rodar
REM
REM `enabledelayedexpansion` nao e enfeite: dentro de um bloco `if (...)` o
REM `%VAR%` e substituido quando o bloco e LIDO, nao quando roda. O `set RAMO`
REM la embaixo viraria `git pull origin` sem ramo nenhum. Com `!RAMO!` o valor
REM e lido na hora.
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------------------
REM Rede de seguranca: o atualizar.ps1 se atualiza sozinho, mas nao consegue se
REM consertar sozinho.
REM
REM O PowerShell analisa o ARQUIVO INTEIRO antes de executar a primeira linha.
REM Se um erro de sintaxe chegar pelo `git pull`, a proxima execucao morre no
REM parser - antes do `git pull` que traria a correcao. O script fica preso num
REM estado em que a unica saida e o usuario saber rodar `git pull` a mao, e a
REM mensagem que ele ve nao sugere isso: fala de um token inesperado.
REM
REM Aqui isso e um impasse resolvido em tres linhas: se o arquivo nao compila,
REM busca a versao nova antes de tentar rodar. So nesse caso - no fluxo normal
REM quem cuida do codigo continua sendo o proprio .ps1, num lugar so.
REM ---------------------------------------------------------------------------
call :compila "%~dp0atualizar.ps1"
if errorlevel 1 (
    echo.
    echo   O atualizar.ps1 tem erro de sintaxe e nao roda. Buscando a versao nova.
    for /f %%b in ('git -C "%~dp0.." rev-parse --abbrev-ref HEAD') do set RAMO=%%b
    git -C "%~dp0.." pull origin !RAMO!
    call :compila "%~dp0atualizar.ps1"
    if errorlevel 1 (
        echo.
        echo   Continua sem compilar. O conserto ainda nao chegou ao repositorio.
        exit /b 1
    )
    echo   Corrigido. Seguindo.
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0atualizar.ps1" %*
exit /b %ERRORLEVEL%

REM Devolve 1 se o arquivo nao passa pelo analisador do PowerShell. Nao executa
REM nada dele: so le e analisa.
:compila
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('%~1', [ref]$null, [ref]$e); if ($e) { exit 1 } else { exit 0 }"
exit /b %ERRORLEVEL%
