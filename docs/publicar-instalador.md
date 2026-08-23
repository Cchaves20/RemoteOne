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

### Cada arquitetura é compilada na máquina dela

Não há compilação cruzada aqui, e o motivo não é preguiça: o `audiopus_sys`
(o Opus, para mandar o som do computador ao celular) só existe para x86 e
x86-64. O `cfg` que o inclui olha o **alvo**, então mirar x86-64 o traz para a
compilação — mas o `build.rs` dele compila para a **máquina que compila**, e num
host ARM64 a constante `ARCHITECTURE` fica indefinida. O build morre no host
mesmo estando tudo certo com o alvo, e nenhum toolchain conserta isso.

Então:

| Arquivo | Onde compilar |
|---|---|
| `Deskside.exe` (x64) | **Dell G5** — Intel |
| `Deskside-ARM64.exe` | **MateBook** — ARM64 |

Cada máquina compila e publica a sua. É mais simples do que juntar os dois
arquivos num lugar só, e evita o passo de copiar binário entre computadores —
que é justamente onde se troca um pelo outro sem perceber.

### No Dell, para o x64

```powershell
git pull
.\scripts\atualizar.cmd -Agente
New-Item -ItemType Directory -Force deploy\site\baixar | Out-Null
Copy-Item agent\target\release\deskside-agent.exe deploy\site\baixar\Deskside.exe -Force
.\scripts\conferir-exe.cmd deploy\site\baixar\Deskside.exe -Esperado x64
```

Sem `--target`: o alvo padrão é o processador da máquina, e no Dell ele já é o
que se quer.

### No MateBook, para o ARM64

```powershell
git pull
.\scripts\atualizar.cmd -Agente
New-Item -ItemType Directory -Force deploy\site\baixar | Out-Null
Copy-Item agent\target\release\deskside-agent.exe deploy\site\baixar\Deskside-ARM64.exe -Force
.\scripts\conferir-exe.cmd deploy\site\baixar\Deskside-ARM64.exe -Esperado ARM64
```

O `atualizar.cmd`, e não `cargo build` direto: ele tem o `PrepararClangArm64`,
que põe o LLVM no PATH antes de chamar o cargo. O `ring` monta o assembly ARM64
com clang, não com o `cl.exe`, e sem isso o build para em
`failed to find tool "clang"`.

O `.cmd` em vez do `.ps1` também não é detalhe: a política de execução do
Windows bloqueia `.ps1` por padrão, com a mensagem "a execução de scripts foi
desabilitada neste sistema". O `.cmd` chama o PowerShell já com a exceção, só
para aquele arquivo.

### Por que a conferência

O `conferir-exe` lê o cabeçalho PE e diz para qual processador o arquivo foi
compilado, o tamanho e a data. **Duas armadilhas de uma vez:** um `.exe` da
arquitetura errada é indistinguível de um certo pelo nome, pelo tamanho e pelo
comportamento na máquina de quem compilou — o erro só aparece no computador de
outra pessoa. E quando um build falha, o `.exe` do build anterior continua onde
estava, então o `Copy-Item` seguinte copia esse sem erro nenhum. As duas coisas
já aconteceram neste projeto.

### Publicar, na mesma máquina que compilou

```powershell
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads\*.key" | Sort-Object LastWriteTime -Descending)[0].FullName
$remoto = 'ubuntu@147.15.45.45'
$raiz = (ssh -i $chave $remoto 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; pwd').Trim()

# No Dell:
scp -i $chave deploy\site\baixar\Deskside.exe "${remoto}:$raiz/deploy/site/baixar/"
# No MateBook:
scp -i $chave deploy\site\baixar\Deskside-ARM64.exe "${remoto}:$raiz/deploy/site/baixar/"
```

E, de qualquer uma das duas, para a página com as duas opções chegar ao ar:

```powershell
ssh -i $chave $remoto 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; git pull'
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

## O caminho curto

Depois de funcionar à mão — o que aconteceu, com quatro tropeços pelo caminho —
os passos acima viraram um comando:

```powershell
.\scripts\atualizar.cmd -Agente -Publicar
```

Compila, descobre a arquitetura **lendo o cabeçalho do binário**, escolhe o nome
a partir dela, copia, avisa se o executável tem mais de um dia (sinal de build
que falhou e deixou o anterior no lugar), manda por `scp` e atualiza a página no
servidor.

O que ele **não** faz, de propósito: escolher a arquitetura. Ele publica a da
máquina em que está rodando. Não existe compilação cruzada aqui, então mandar no
Dell publica o x64 e mandar no MateBook publica o ARM64 — e o nome sai do
cabeçalho, nunca de um parâmetro. É o que torna impossível repetir o erro de
publicar o ARM64 com o nome do x64.

Automatizar **antes** de o fluxo funcionar à mão teria sido embutir num script
de 800 linhas um passo que ninguém viu dar certo. Os quatro tropeços de ontem
teriam acontecido lá dentro, e não na linha que se acabou de digitar.

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
