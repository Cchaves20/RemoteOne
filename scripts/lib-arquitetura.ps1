# Para qual processador um .exe do Windows foi compilado.
#
# Fica num arquivo próprio porque dois scripts precisam da mesma resposta — o
# `conferir-exe.ps1`, que a mostra, e o `atualizar.ps1 -Publicar`, que decide o
# nome do arquivo publicado a partir dela. Duas cópias da mesma aritmética de
# cabeçalho seria o tipo de duplicação que envelhece mal: uma delas seria
# corrigida um dia e a outra não.
#
# Use com ponto na frente, para as funções entrarem na sessão de quem chama:
#     . (Join-Path $PSScriptRoot "lib-arquitetura.ps1")

#: Os valores do campo `Machine` do cabeçalho PE que nos interessam.
$script:MaquinasConhecidas = @{
    0x014C = 'x86'
    0x8664 = 'x64'
    0xAA64 = 'ARM64'
    0x01C4 = 'ARM'
}

function ArquiteturaDoExe {
    <#
    .SYNOPSIS
    Devolve 'x64', 'ARM64', 'x86'... ou $null se o arquivo não for um PE.

    .DESCRIPTION
    Lê o cabeçalho PE. No byte 0x3C de todo executável do Windows há um número
    que aponta para a assinatura "PE\0\0"; quatro bytes depois vem o campo
    `Machine`, de dois bytes, e é ele que decide se o programa roda.
    #>
    param([Parameter(Mandatory = $true)][string]$Caminho)

    if (-not (Test-Path $Caminho)) { return $null }

    $fluxo = [IO.File]::OpenRead((Resolve-Path $Caminho))
    try {
        $leitor = New-Object IO.BinaryReader($fluxo)
        $fluxo.Position = 0x3C
        $inicioPe = $leitor.ReadInt32()
        if ($inicioPe -le 0 -or $inicioPe -ge $fluxo.Length - 6) { return $null }
        $fluxo.Position = $inicioPe
        if ($leitor.ReadUInt32() -ne 0x00004550) { return $null }  # "PE\0\0"
        $maquina = $leitor.ReadUInt16()
    }
    finally {
        $fluxo.Close()
    }

    $nome = $script:MaquinasConhecidas[[int]$maquina]
    if ($nome) { return $nome }
    return ('desconhecido (0x{0:X4})' -f $maquina)
}

function NomePublicadoPara {
    <#
    .SYNOPSIS
    O nome com que um binário desta arquitetura deve ser publicado.

    .DESCRIPTION
    O x64 fica com o nome principal porque o Windows em ARM **emula** x64:
    aquele arquivo roda nas duas arquiteturas, e é o que o botão grande da
    página oferece. O ARM64 nativo ganha sufixo, para quem sabe que tem um.

    Derivar o nome da arquitetura, em vez de digitá-lo, é o que impede o erro
    que já aconteceu: publicar um binário ARM64 com o nome do x64 e descobrir
    no computador de outra pessoa.
    #>
    param([Parameter(Mandatory = $true)][string]$Arquitetura)

    switch ($Arquitetura) {
        'x64'   { return 'Deskside.exe' }
        'ARM64' { return 'Deskside-ARM64.exe' }
        default { return $null }
    }
}
