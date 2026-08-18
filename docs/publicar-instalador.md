# Publicar o instalador do Windows

Como o `.exe` sai da sua máquina e chega em `deskside.com.br/baixar`.

## Por que à mão, e por que por `scp`

O executável **não** é versionado. Binário no Git incha o repositório para
sempre — cada versão fica no histórico —, e o arquivo é gerado a cada build.
Então ele não vem no `git pull` do VPS: vai direto, por `scp`, do computador que
compilou para a pasta que o Caddy serve.

As GitHub Actions estão desligadas neste projeto, então a compilação é sua.

## O pacote

Um `.zip` com dois arquivos:

- `deskside-agent.exe` — o agente, compilado em release;
- `INSTALAR.cmd` — versionado em `deploy/site/baixar/`, é ele que a pessoa clica.

Duas coisas nesse `.cmd` valem saber, porque as duas nasceram de erro real:

- **Ele não tem acento.** O `cmd.exe` em português abre `.cmd` na página de
  código 850, não em UTF-8; um "instalação" sai como "instala‡Æo". Um instalador
  que parece corrompido não ajuda quem já está desconfiado do aviso do
  SmartScreen.
- **Ele avisa se foi rodado de dentro do `.zip`.** O Explorer do Windows abre
  `.zip` como se fosse pasta, mas os arquivos continuam comprimidos e não se
  veem: o `INSTALAR.cmd` rodaria e não acharia o `.exe` ao lado. Em vez de um
  erro seco, ele explica que é preciso extrair primeiro.

## Os comandos

No **MateBook**, em `C:\Users\OseasyVM\Desktop\projetos\Deskside`:

```powershell
# 1. Compilar em release.
cargo build --release --manifest-path agent\Cargo.toml

# 2. Montar o pacote (o INSTALAR.cmd já está versionado na pasta).
Copy-Item agent\target\release\deskside-agent.exe deploy\site\baixar\ -Force
Compress-Archive -Path deploy\site\baixar\deskside-agent.exe,
                       deploy\site\baixar\INSTALAR.cmd `
                 -DestinationPath deploy\site\baixar\Deskside-Windows.zip -Force

# 3. Enviar ao VPS. A chave é a mais recente em Downloads, como no atualizar.ps1.
$chave = (Get-ChildItem "$env:USERPROFILE\Downloads\*.key" |
          Sort-Object LastWriteTime -Descending)[0].FullName
$remoto = 'ubuntu@147.15.45.45'
$pasta  = 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; pwd'
$raiz   = (ssh -i $chave $remoto $pasta).Trim()

scp -i $chave deploy\site\baixar\Deskside-Windows.zip `
    "${remoto}:$raiz/deploy/site/baixar/"
```

O `.zip` fica disponível na hora: o Caddy serve a pasta direto, sem reiniciar
nada.

## Conferir

```powershell
curl.exe -I https://deskside.com.br/baixar/Deskside-Windows.zip
```

`200` e um `content-length` de alguns megabytes. `404` significa que o `scp` foi
para a pasta errada — confira o caminho que o `$raiz` descobriu.

## Quando automatizar

Isto vira um `-Publicar` no `atualizar.ps1` depois de funcionar à mão pelo menos
uma vez. Automatizar antes disso é embutir num script um passo que ninguém viu
dar certo — e quando falhar, falha dentro de um script de 700 linhas em vez de na
linha que você acabou de digitar.

## O que ainda falta

O `.exe` **não é assinado**. O Windows mostra a tela azul do SmartScreen dizendo
que protegeu o PC, e a pessoa precisa clicar em "Mais informações" → "Executar
assim mesmo". A página do site avisa isso antes de acontecer, o que ajuda — mas
não resolve. Resolver é comprar um certificado de assinatura de código, e é a
próxima despesa depois do domínio.
