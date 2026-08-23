# Publicar o instalador do Windows

Como o `.exe` sai da sua máquina e chega em `deskside.com.br/baixar`.

## Por que à mão, e por que por `scp`

O executável **não** é versionado. Binário no Git incha o repositório para
sempre — cada versão fica no histórico —, e o arquivo é gerado a cada build.
Então ele não vem no `git pull` do VPS: vai direto, por `scp`, do computador que
compilou para a pasta que o Caddy serve.

As GitHub Actions estão desligadas neste projeto, então a compilação é sua.

## Um arquivo só, e por quê

O download é o `Deskside.exe`, direto. **Não** há mais `.zip` nem `INSTALAR.cmd`,
e a razão é um aviso que dinheiro nenhum apagaria.

O Windows marca todo arquivo baixado, e a marca passa para o que sai de um
`.zip`. Executar um `.cmd` marcado abre "o fornecedor não pôde ser verificado" —
sobre um **script**, que é o formato que todo mundo aprendeu a temer. E o
Authenticode assina `.exe`, não `.cmd`: aquele aviso continuaria de pé mesmo
depois de comprarmos o certificado.

Havia também um custo menor e real: extrair era um passo a mais e ponto de falha
próprio. O Explorer abre `.zip` como se fosse pasta, o `.cmd` rodava de dentro
dele e não achava o `.exe` ao lado — o script precisou de uma mensagem de erro só
para esse caso, e precisar dela já era o sinal de que o desenho tinha uma quina.

Agora o próprio `.exe` pergunta se pode instalar quando é aberto de fora da pasta
de instalação. Um arquivo, sem extrair, **um** aviso — e esse é exatamente o que
o certificado remove.

## Os comandos

No **MateBook**, em `C:\Users\OseasyVM\Desktop\projetos\Deskside`:

### Preparar, uma vez só

```powershell
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc
```

### Compilar as duas

```powershell
git pull
cd agent
cargo build --release --target x86_64-pc-windows-msvc
cargo build --release --target aarch64-pc-windows-msvc
cd ..
```

**Sempre com `--target`, mesmo para a arquitetura da própria máquina.** Sem ele,
o cargo compila para o processador de quem está compilando — e no MateBook isso
quer dizer ARM64. Um `.exe` ARM64 num PC Intel dá "Este aplicativo não pode ser
executado em seu PC", uma frase que não menciona arquitetura, não diz qual é a
certa e não diz onde procurar. Foi assim que um binário só-ARM64 chegou a ficar
publicado no site.

Se o build ARM64 falhar com `failed to find tool "clang"`, use
`.\scripts\atualizar.cmd -Agente`, que tem um `PrepararClangArm64` para pôr o
LLVM no PATH — o `ring` monta o assembly ARM64 com clang, não com o `cl.exe`.
Se o build x86-64 pedir `nasm`, `winget install NASM.NASM` e reabra o terminal.

### Conferir antes de copiar

```powershell
Copy-Item agent\target\x86_64-pc-windows-msvc\release\deskside-agent.exe deploy\site\baixar\Deskside.exe -Force
Copy-Item agent\target\aarch64-pc-windows-msvc\release\deskside-agent.exe deploy\site\baixar\Deskside-ARM64.exe -Force

.\scripts\conferir-exe.ps1 deploy\site\baixar\Deskside.exe -Esperado x64
.\scripts\conferir-exe.ps1 deploy\site\baixar\Deskside-ARM64.exe -Esperado ARM64
```

O `conferir-exe.ps1` lê o cabeçalho PE e diz para qual processador cada um foi
compilado, o tamanho e a data. **Duas armadilhas de uma vez:** um `.exe` da
arquitetura errada é indistinguível de um certo pelo nome, pelo tamanho e pelo
comportamento na máquina de quem compilou — o erro só aparece no computador de
outra pessoa. E quando um build falha, o `.exe` do build anterior continua onde
estava, então o `Copy-Item` seguinte copia esse sem erro nenhum. Já aconteceu:
quase foi publicado um agente sem a remoção da marca da web e sem a pergunta de
instalação. Um comando que dá certo copiando a coisa errada é pior que um que
falha.

### Publicar

```powershell
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads\*.key" | Sort-Object LastWriteTime -Descending)[0].FullName
$remoto = 'ubuntu@147.15.45.45'
$raiz = (ssh -i $chave $remoto 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; pwd').Trim()
scp -i $chave deploy\site\baixar\Deskside.exe deploy\site\baixar\Deskside-ARM64.exe "${remoto}:$raiz/deploy/site/baixar/"
```

### Por que dois, e por que o x64 é o principal

O Windows em ARM **emula x64**, então o `Deskside.exe` funciona nas duas
arquiteturas. Se fosse para ter um só, seria ele.

O ARM64 nativo existe porque emular custa: roda mais devagar e gasta mais
bateria, justamente num aparelho comprado por causa da bateria. Quem tem um PC
ARM ganha de verdade com a versão nativa.

Na página, o botão grande é o x64 e o ARM64 é uma linha abaixo. É de propósito:
perguntar "qual é o seu processador?" na porta de entrada é um lugar a mais para
a pessoa errar, e errar aqui produz exatamente a tela azul sem explicação. O
padrão precisa ser o que funciona sempre.

O nome do arquivo publicado é `Deskside.exe`, e não `deskside-agent.exe`: é o que
a pessoa vê na pasta de downloads, e "deskside-agent" parece peça de dentro de
outra coisa.

Fica disponível na hora — o Caddy serve a pasta direto, sem reiniciar nada.

## Conferir

```powershell
curl.exe -I https://deskside.com.br/baixar/Deskside.exe
curl.exe -I https://deskside.com.br/baixar/Deskside-ARM64.exe
```

`200` e um `content-length` de alguns megabytes nos dois. `404` significa que o
`scp` foi para a pasta errada — confira o caminho que o `$raiz` descobriu.

## Quando automatizar

Isto vira um `-Publicar` no `atualizar.ps1` depois de funcionar à mão pelo menos
uma vez. Automatizar antes disso é embutir num script um passo que ninguém viu
dar certo — e quando falhar, falha dentro de um script de 700 linhas em vez de na
linha que você acabou de digitar.

## O que ainda falta

O `.exe` **não é assinado**, e sobra um aviso por causa disso: a tela azul do
SmartScreen ao executar. A página avisa antes de acontecer, o que ajuda, mas não
resolve — resolver é um certificado de assinatura de código, e é a próxima
despesa depois do domínio. O de validação estendida (EV) remove o aviso de
imediato e exige CNPJ; o comum (OV) reduz, com a reputação acumulando ao longo
de semanas.

De graça, e vale fazer: submeter o `.exe` em
<https://www.microsoft.com/en-us/wdsi/filesubmission> como falso positivo, na
opção de **software** ("Software developer"). Costuma limpar o SmartScreen em
alguns dias, e precisa ser refeito a cada versão nova do executável.
