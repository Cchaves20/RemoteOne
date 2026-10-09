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

## Como se monta e onde baixar

O GitHub monta o `Deskside.app` num Mac a cada push que mexe no agente
(`.github/workflows/agente-mac.yml`), roda os testes lá, e deixa o
`Deskside-mac.zip` para baixar na página da execução, em **Artifacts**.

Num Mac, à mão: `sh scripts/montar-app-mac.sh`, a partir da raiz do repositório.

## Testar quando o Mac chegar

1. Baixar o `Deskside-mac.zip` da última execução de "Agente no Mac" no
   GitHub (aba Actions) e abrir o zip.
2. Arrastar o `Deskside.app` para **Aplicativos**.
3. Abrir com **botão direito › Abrir** (a primeira vez). Como o pacote ainda
   não tem assinatura da Apple, o duplo clique sozinho mostra "não é possível
   verificar o desenvolvedor"; o botão direito oferece "Abrir mesmo assim".
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

Se algo falhar, o diário fica em `~/.config/deskside/agent.log` (no Finder:
Ir › Ir para a Pasta…, e colar o caminho).

## O que ainda não existe (fases 2 e 3)

- **Som do computador.** No Mac o som do sistema só se captura pelo
  ScreenCaptureKit (macOS 13+). Hoje o vídeo vai sem som.
- **Energia e "manter pronto"**: suspender, desligar, reiniciar e o
  `caffeinate`. Hoje o app oferece e o Mac não faz nada.
- **Modo apresentação, brilho, lista de janelas e de programas,
  notificações.** Cada um tem um equivalente no Mac, quase sempre por
  AppleScript.
- **Assinatura e notarização** com o Developer ID da conta da Apple. Sem
  isso, quem baixa vê o aviso do passo 3 — e, mais importante, o Mac guarda
  as permissões pela assinatura: com a ad hoc de hoje, **cada versão nova
  pede as duas permissões de novo**.
- **Atualização automática.** Mesma ideia do Windows, trocando o `.app`
  inteiro; depende da assinatura acima.
- **Instalador `.dmg`** com o atalho para Aplicativos. Hoje é um `.zip`.

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
