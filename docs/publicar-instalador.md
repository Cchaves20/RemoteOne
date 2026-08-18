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

```powershell
git pull
cargo build --release --manifest-path agent\Cargo.toml
Copy-Item agent\target\release\deskside-agent.exe deploy\site\baixar\Deskside.exe -Force

$chave = (Get-ChildItem "$env:USERPROFILE\Downloads\*.key" | Sort-Object LastWriteTime -Descending)[0].FullName
$remoto = 'ubuntu@147.15.45.45'
$raiz = (ssh -i $chave $remoto 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; pwd').Trim()
scp -i $chave deploy\site\baixar\Deskside.exe "${remoto}:$raiz/deploy/site/baixar/"
```

O nome do arquivo publicado é `Deskside.exe`, e não `deskside-agent.exe`: é o que
a pessoa vê na pasta de downloads, e "deskside-agent" parece peça de dentro de
outra coisa.

Fica disponível na hora — o Caddy serve a pasta direto, sem reiniciar nada.

## Conferir

```powershell
curl.exe -I https://deskside.com.br/baixar/Deskside.exe
```

`200` e um `content-length` de alguns megabytes. `404` significa que o `scp` foi
para a pasta errada — confira o caminho que o `$raiz` descobriu.

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
