# O agente no Mac

O mesmo agente do Windows, compilado para macOS. A maior parte do código é
comum (servidor, pareamento, vídeo, automações); o que muda está atrás de
`#[cfg(target_os = "macos")]`.

## O que já está escrito (fase 1)

| Peça | Como funciona no Mac | Onde |
|---|---|---|
| Ver a tela | `xcap`, a mesma biblioteca do Windows | `capture.rs` |
| Mouse e teclado | `enigo`, a mesma do Windows. Ctrl e ⌘ trocam de lugar: o app manda Ctrl+C e o Mac recebe ⌘C | `injector.rs`, `input.rs` (`Modifier::no_mac`) |
| Área de transferência | `NSPasteboard`: texto, imagem (PNG e TIFF) e arquivos copiados no Finder | `clipboard.rs` |
| Permissões | Pede Gravação de Tela e Acessibilidade ao abrir, e a janela mostra o que falta com o botão que leva aos Ajustes | `permissoes_mac.rs`, `gui.rs` |
| Janela e ícone | A mesma janela do Windows; o ícone fica na barra de menus, sem ícone no Dock | `gui.rs` |
| Abrir com o Mac | `~/Library/LaunchAgents/com.deskside.agente.plist`, gravado na primeira abertura | `setup.rs` |
| Uma cópia só | Arquivo trancado em `~/.config/deskside/agente.lock` | `instance.rs` |
| Identificador da máquina | `IOPlatformUUID`, pelo `ioreg` | `identity.rs` |
| App do celular | Mostra "macOS" e o ícone de Mac na lista | `client/lib/models/device.dart` |

## Fase 2

| Peça | Como funciona no Mac | Onde |
|---|---|---|
| Automações agendadas | O relógio local pelo `localtime_r`. Antes disso, nenhuma automação agendada disparava no Mac | `agenda.rs` |
| Suspender | `pmset sleepnow` | `power.rs` |
| Desligar e reiniciar | Pelo `loginwindow`, como o menu Apple: os programas perguntam sobre o que não foi salvo. O Mac pode pedir, uma vez, para liberar o Deskside em Privacidade e Segurança › **Automação** | `power.rs` |
| Manter pronto | `caffeinate`, amarrado ao agente: se o agente cair, o Mac volta a dormir normalmente. Bateria e tomada pelo `pmset` | `awake.rs` |
| Programas abertos | Os que têm ícone no Dock, com o ícone de verdade. Fechar pela tela força; fechar por automação pede, e o programa pergunta sobre o que não foi salvo | `apps.rs`, `mac.rs` |
| Programas instalados | Os `.app` de Aplicativos (do sistema, de todos e do usuário) | `apps.rs` |
| Atalhos da dock do app | Os programas fixados no **Dock** do Mac — o equivalente dos atalhos da área de trabalho do Windows | `apps.rs` |
| Perfil feito no Windows | Abre o mesmo programa no Mac pelo nome: o atalho `Spotify.lnk` de lá abre o Spotify daqui | `apps.rs` (`nome_para_o_mac`) |
| Programa em primeiro plano | Pelo `NSWorkspace`, para os perfis trocarem sozinhos | `foreground.rs` |
| Salvar tudo (automação) | Traz cada editor para a frente e manda ⌘S | `janelas.rs` (`focar`) |
| Modo apresentação | A tela fica acesa e a tela cheia é reconhecida (Keynote, PowerPoint, vídeo). **Não** silencia as notificações: a Apple não deixa programa nenhum ligar o "Não Perturbe", e o app avisa isso | `apresentacao.rs`, `janelas.rs` |
| Brilho | Da tela embutida (MacBook, iMac), pela mesma biblioteca do sistema que a tecla de brilho usa. Monitor externo, não | `brightness.rs` |

## Fase 3

| Peça | Como funciona no Mac | Onde |
|---|---|---|
| Som do computador | ScreenCaptureKit (macOS 13+), a mesma permissão da Gravação de Tela, sem driver. O som do próprio Deskside fica de fora. Opus em Rust puro, testado no Linux com som de verdade | `audio.rs`, `opus_puro.rs` |
| Instalador | `Deskside.dmg`, com o atalho para Aplicativos ao lado | `scripts/montar-app-mac.sh` |
| Assinatura e notarização | Com o Developer ID e a chave da API da Apple nos segredos do GitHub (ver abaixo); sem eles, sai a versão de teste | `scripts/montar-app-mac.sh`, workflow |
| Atualização automática | Baixa o `.app` novo num `.zip`, confere, troca, abre e espera a prova de que conectou; sem a prova em 90 s, volta o velho | `atualizacao.rs` |
| Publicação | O GitHub publica no pré-lançamento `agente-mac`; o servidor copia para o site com `scripts/publicar-mac.sh` | workflow, `scripts/publicar-mac.sh` |

## Como se monta e onde baixar

O GitHub monta tudo num Mac a cada push que mexe no agente
(`.github/workflows/agente-mac.yml`), roda os testes lá e publica no
pré-lançamento **agente-mac**:

https://github.com/Cchaves20/RemoteOne/releases/tag/agente-mac

Ali ficam o `Deskside.dmg` (para instalar) e o `Deskside-mac.zip` com os
resumos (para a atualização automática). Publicar ali **não** põe nada no ar:
o site só muda quando alguém roda, no servidor,

```sh
cd ~/RemoteOne && git pull && sh scripts/publicar-mac.sh
```

que baixa do GitHub, confere o resumo e grava em `deploy/site/baixar/`. Só a
partir daí os Macs instalados veem a versão nova.

Num Mac, à mão: `sh scripts/montar-app-mac.sh`, a partir da raiz do repositório.

## Assinatura e notarização: o que configurar (uma vez)

Sem isso tudo funciona, mas: quem baixa vê "desenvolvedor não identificado",
e cada versão nova pede de novo as permissões de Gravação de Tela e
Acessibilidade — o Mac as guarda pela assinatura, e a de teste muda a cada
build.

**Quem pode:** só o titular da conta de desenvolvedor da Apple cria um
certificado Developer ID. Dá para fazer tudo no Windows.

1. **Pedido de certificado.** No Dell, no PowerShell, numa pasta **fora** do
   repositório (estes arquivos são segredos):

   ```powershell
   mkdir "$env:USERPROFILE\Documents\deskside-developer-id"; cd "$env:USERPROFILE\Documents\deskside-developer-id"
   & "C:\Program Files\Git\usr\bin\openssl.exe" req -new -newkey rsa:2048 -nodes -keyout developerid.key -out developerid.csr -subj "/CN=Deskside/C=BR"
   ```

2. **O certificado.** Em developer.apple.com › Certificates, IDs & Profiles ›
   Certificates › **+** › **Developer ID Application** › envie o
   `developerid.csr` › baixe o `developerID_application.cer` para a mesma
   pasta.

3. **O pacote com a chave** (o segundo comando pede uma senha; guarde-a):

   ```powershell
   & "C:\Program Files\Git\usr\bin\openssl.exe" x509 -inform DER -in developerID_application.cer -out developerid.pem
   & "C:\Program Files\Git\usr\bin\openssl.exe" pkcs12 -export -inkey developerid.key -in developerid.pem -out developerid.p12 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
   ```

   Os `PBE-SHA1-3DES` e o `sha1` são o formato que o chaveiro do Mac lê; o
   padrão do OpenSSL novo ele recusa.

4. **Os segredos do GitHub.** Em github.com/Cchaves20/RemoteOne › Settings ›
   Secrets and variables › Actions › **New repository secret**, um de cada
   vez. Para copiar sem mostrar na tela:

   | Segredo | Valor | Como copiar (na mesma pasta) |
   |---|---|---|
   | `MAC_CERTIFICADO_P12` | o `developerid.p12` em base64 | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\developerid.p12")) \| Set-Clipboard` |
   | `MAC_CERTIFICADO_SENHA` | a senha do passo 3 | digite |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | o conteúdo do `.p8` que o Codemagic já usa | `Get-Content (Get-ChildItem "$env:USERPROFILE\Downloads\AuthKey_*.p8")[0] -Raw \| Set-Clipboard` |
   | `APP_STORE_CONNECT_KEY_ID` | o Key ID dessa chave (o que vem no nome do `.p8`) | digite |
   | `APP_STORE_CONNECT_ISSUER_ID` | o Issuer ID, em App Store Connect › Users and Access › Integrations | digite |

5. O próximo push no agente já sai assinado e notarizado. Confira no log do
   passo "Montar o Deskside.app": a última linha diz
   `assinatura: Developer ID; notarizado: sim`.

## Testar quando o Mac chegar

1. Baixar o `Deskside.dmg` do pré-lançamento
   (https://github.com/Cchaves20/RemoteOne/releases/tag/agente-mac) e abrir.
2. Arrastar o `Deskside` para **Aplicativos**.
3. Abrir. Sem a assinatura da Apple configurada (ver acima), a primeira vez é
   com **botão direito › Abrir**: o duplo clique sozinho mostra "não é
   possível verificar o desenvolvedor"; o botão direito oferece "Abrir mesmo
   assim".
   No macOS 15 ou mais novo: tentar abrir, e depois Ajustes do Sistema ›
   Privacidade e Segurança › "Abrir mesmo assim".
4. O Mac pede **Gravação de Tela** e **Acessibilidade**. Ligar o Deskside nas
   duas em Ajustes do Sistema › Privacidade e Segurança, e clicar em
   "Reabrir o Deskside" na janela.
5. Parear pelo celular, como no Windows.

O que conferir, nesta ordem, e o que mandar se falhar:

- [ ] A janela abre e o ícone aparece na barra de menus.
- [ ] O código de pareamento aparece e o pareamento fecha.
- [ ] A tela chega ao celular (a imagem e o vídeo direto).
- [ ] Mouse, clique, rolagem e digitação, inclusive acentos.
- [ ] Ctrl+C / Ctrl+V do app copiam e colam no Mac.
- [ ] A área de transferência nos dois sentidos (texto e imagem).
- [ ] Depois de reiniciar o Mac, o Deskside volta sozinho.
- [ ] Suspender, desligar e reiniciar pelo celular (o Mac pode pedir para
      liberar "Automação" na primeira vez).
- [ ] A lista de programas abertos e instalados, com ícones; abrir e fechar.
- [ ] Uma automação agendada para dali a dois minutos dispara.
- [ ] O brilho, se for um MacBook ou iMac.
- [ ] O som do computador chega ao celular (macOS 13 ou mais novo).
- [ ] Atualização: publicar uma versão nova no site
      (`scripts/publicar-mac.sh`) e, no Deskside do Mac, clicar em Atualizar.
      Ele fecha, volta sozinho em alguns segundos, e o celular reconecta.

Se algo falhar, o diário fica em `~/.config/deskside/agent.log` (no Finder:
Ir › Ir para a Pasta…, e colar o caminho).

## O que ainda não existe

- **Pôr a janela numa zona da tela** (as zonas dos perfis). O programa abre,
  mas onde o Mac quiser; exige a API de Acessibilidade janela a janela.
- **Silenciar notificações** no modo apresentação: sem API da Apple para isso.
- **O link de download na página do site.** Fica para depois do primeiro
  teste num Mac de verdade; até lá, o `.dmg` sai do pré-lançamento do GitHub.

## Riscos conhecidos, para olhar primeiro no teste

- **macOS 15 (Sequoia).** A Apple aposentou o `CGWindowListCreateImage`, que
  o `xcap` usa na captura de um quadro só, e marcou como obsoleta a captura
  contínua que ele usa (`AVCaptureScreenInput`). Se a tela vier preta ou não
  vier, o caminho é trocar a captura pelo ScreenCaptureKit.
- **Retina.** A captura vem em pixels e o mouse anda em pontos (metade, numa
  tela Retina). O mouse usa a fração da tela, então deve bater — mas é o
  primeiro lugar a olhar se o clique cair fora do lugar.
- **Teclado que não é o americano.** O `enigo` digita texto pelo Unicode, o
  que cobre acentos; atalhos com letra dependem do layout.
