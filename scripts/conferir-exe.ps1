# Diz para qual processador um .exe foi compilado.
#
# ## Por que isto existe
#
# O MateBook é Windows **ARM64**. O `cargo build` sem `--target` compila para a
# arquitetura da máquina que compila, então o `.exe` gerado ali só roda em ARM.
# Num PC Intel — que é quase todo PC — o Windows responde "Este aplicativo não
# pode ser executado em seu PC" e mais nada: não diz que é arquitetura, não diz
# qual é a certa, não diz onde procurar.
#
# Um `.exe` da arquitetura errada é indistinguível de um certo por qualquer meio
# que não seja abrir o cabeçalho. Tem o mesmo nome, tamanho parecido, roda na
# máquina de quem compilou. O erro só aparece no computador de outra pessoa.
#
# ## Uso
#
#     .\scripts\conferir-exe.cmd deploy\site\baixar\Deskside.exe -Esperado x64
#
# Sai com código 1 quando não bate com o esperado, para poder entrar numa
# corrente de comandos antes de publicar.

param(
    [Parameter(Mandatory = $true)][string]$Caminho,
    # O que se espera. x64 é o certo para publicar: o Windows ARM **emula** x64,
    # então um binário x64 roda nas duas arquiteturas, enquanto o ARM64 só roda
    # numa. Um executável serve todo mundo.
    [string]$Esperado = 'x64'
)

. (Join-Path $PSScriptRoot "lib-arquitetura.ps1")

if (-not (Test-Path $Caminho)) {
    Write-Host "não achei $Caminho" -ForegroundColor Red
    exit 1
}

$nome = ArquiteturaDoExe $Caminho
if (-not $nome) {
    Write-Host "$Caminho não parece um executável do Windows." -ForegroundColor Red
    exit 1
}

$item = Get-Item $Caminho
$tamanho = [math]::Round($item.Length / 1MB, 1)

# --- O runtime C++ da Microsoft vem junto, ou é esperado na máquina? --------
#
# Mesma família do defeito de arquitetura, e igualmente invisível de dentro: um
# .exe ligado dinamicamente ao runtime roda aqui e morre no computador de quem
# não tem o Visual Studio instalado, com
#
#     A execução de código não pode continuar porque VCRUNTIME140.dll não foi
#     encontrado.
#
# antes da primeira linha do nosso código — não há mensagem nossa possível.
#
# A detecção é por busca de texto, e não por leitura da tabela de importação:
# o nome da DLL importada fica no arquivo como texto puro, então achá-lo basta
# e não exige interpretar o formato PE. Ver agent/.cargo/config.toml.
$conteudo = [System.Text.Encoding]::ASCII.GetString(
    [System.IO.File]::ReadAllBytes($Caminho))
$dinamicas = @('VCRUNTIME140.dll', 'MSVCP140.dll') |
    Where-Object { $conteudo.Contains($_) }

if ($dinamicas) {
    Write-Host "ERRADO: $Caminho depende de $($dinamicas -join ', ')." -ForegroundColor Red
    Write-Host "  Esse .exe funciona aqui e falha em Windows sem o runtime C++" -ForegroundColor DarkGray
    Write-Host "  da Microsoft instalado, que é o caso de uma máquina recém-formatada." -ForegroundColor DarkGray
    Write-Host "  Confira se agent/.cargo/config.toml existe e traz +crt-static," -ForegroundColor DarkGray
    Write-Host "  e recompile do zero (cargo clean antes)." -ForegroundColor DarkGray
    exit 1
}

if ($nome -eq $Esperado) {
    Write-Host "ok: $Caminho é $nome, $tamanho MB, de $($item.LastWriteTime)" -ForegroundColor Green
    exit 0
}

Write-Host "ERRADO: $Caminho é $nome, e o esperado era $Esperado." -ForegroundColor Red
if ($nome -eq 'ARM64') {
    Write-Host "  Foi compilado sem --target numa máquina ARM64 (o MateBook)." -ForegroundColor DarkGray
    Write-Host "  Num PC Intel isso vira 'Este aplicativo não pode ser executado em seu PC'." -ForegroundColor DarkGray
    Write-Host "  O x86-64 precisa ser compilado num PC Intel: o audiopus_sys não" -ForegroundColor DarkGray
    Write-Host "  compila com host ARM64, então não há compilação cruzada." -ForegroundColor DarkGray
}
exit 1
