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
# ## O que ele lê
#
# O cabeçalho PE. No byte 0x3C de todo executável do Windows há um número que
# aponta para a assinatura "PE\0\0"; quatro bytes depois vem o campo `Machine`,
# de dois bytes, e é ele que decide se o programa roda.
#
# ## Uso
#
#     .\scripts\conferir-exe.ps1 deploy\site\baixar\Deskside.exe
#
# Sai com código 1 quando não é x86-64, para poder entrar numa corrente de
# comandos antes de publicar.

param(
    [Parameter(Mandatory = $true)][string]$Caminho,
    # O que se espera. x64 é o certo para publicar: o Windows ARM **emula** x64,
    # então um binário x64 roda nas duas arquiteturas, enquanto o ARM64 só roda
    # numa. Um executável serve todo mundo.
    [string]$Esperado = 'x64'
)

$conhecidos = @{
    0x014C = 'x86'
    0x8664 = 'x64'
    0xAA64 = 'ARM64'
    0x01C4 = 'ARM'
}

if (-not (Test-Path $Caminho)) {
    Write-Host "não achei $Caminho" -ForegroundColor Red
    exit 1
}

$fluxo = [IO.File]::OpenRead((Resolve-Path $Caminho))
try {
    $leitor = New-Object IO.BinaryReader($fluxo)
    $fluxo.Position = 0x3C
    $inicioPe = $leitor.ReadInt32()
    $fluxo.Position = $inicioPe
    $assinatura = $leitor.ReadUInt32()
    if ($assinatura -ne 0x00004550) {   # "PE\0\0" em little-endian
        Write-Host "$Caminho não parece um executável do Windows." -ForegroundColor Red
        exit 1
    }
    $maquina = $leitor.ReadUInt16()
}
finally {
    $fluxo.Close()
}

$nome = $conhecidos[[int]$maquina]
if (-not $nome) { $nome = ('desconhecido (0x{0:X4})' -f $maquina) }

$tamanho = [math]::Round((Get-Item $Caminho).Length / 1MB, 1)
$data = (Get-Item $Caminho).LastWriteTime

if ($nome -eq $Esperado) {
    Write-Host "ok: $Caminho é $nome, $tamanho MB, de $data" -ForegroundColor Green
    exit 0
}

Write-Host "ERRADO: $Caminho é $nome, e o esperado era $Esperado." -ForegroundColor Red
if ($nome -eq 'ARM64') {
    Write-Host "  Foi compilado sem --target numa máquina ARM64 (o MateBook)." -ForegroundColor DarkGray
    Write-Host "  Num PC Intel isso vira 'Este aplicativo não pode ser executado em seu PC'." -ForegroundColor DarkGray
    Write-Host "  Compile com: cargo build --release --target x86_64-pc-windows-msvc" -ForegroundColor DarkGray
}
exit 1
