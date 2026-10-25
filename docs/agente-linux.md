# Agente no Linux

## Onde está

**Fases 1 e 2: tela, mouse e teclado; instalador, início no login, ícone e o
aviso "está controlando".** Sem a janela de configurações do Windows e do Mac.

| Sessão gráfica | Tela | Mouse e teclado |
|---|---|---|
| Wayland (Ubuntu, Fedora) | portal do sistema + PipeWire | portal do sistema |
| X11 | `xcap` (como no Windows e no Mac) | `enigo` |
| Nenhuma (servidor, CI) | quadro sintético | só registra no diário |

## Por que o Wayland é viável

O Wayland não deixa um programa capturar a tela nem mexer no mouse sozinho: o
caminho é o portal do sistema, que mostra uma janela de permissão. Antes de
escrever o agente, um teste (`scripts/spike-wayland.py`) mediu no Ubuntu 26.04
com GNOME 50:

| Rodada | Janela | Tempo até liberar |
|---|---|---|
| 1ª (sem ficha) | apareceu | 6,6 s (alguém clicando) |
| 2ª (com a ficha) | não | 0,1 s |
| depois de sair e entrar | não | 0,0 s |

Pedindo para **lembrar**, o sistema devolve uma ficha (`restore_token`), e com
ela as próximas sessões abrem sem janela. A ficha **muda a cada uso**; o
agente regrava a nova em `~/.config/deskside/wayland-ficha` (só o dono lê).

## Como funciona (`agent/src/wayland.rs`)

- **Na primeira vez**, o agente pede a permissão logo ao iniciar, enquanto há
  alguém diante do computador (quem acabou de abri-lo).
- **A sessão só existe enquanto alguém vê a tela.** Com ela aberta, o GNOME
  acende um ícone de "tela compartilhada" no alto.
- **Ficha recusada:** o sistema volta a mostrar a janela. O agente espera 3 s,
  avisa o celular ("o computador está pedindo permissão…") e desiste em 2 min,
  em vez de ficar preso.
- **Teclado pelo símbolo** (keysym), e não pela posição da tecla. O símbolo
  só sai se o teclado do computador tiver a tecla, então o agente lê o layout
  em uso (`teclado_linux.rs`) e digita como uma pessoa: tecla própria ("ç" no
  ABNT2) ou acento + letra ("´" e "e" para "é"). Se o layout não faz o
  caractere — acentos no inglês (EUA) —, ele fica de fora e o celular recebe
  um aviso com o que mudar no computador. (Digitar pelo código Unicode, com
  Ctrl+Shift+U, foi tentado e descartado: onde o atalho não é tratado, os
  programas recebem Ctrl e Shift como atalhos e o mouse sai clicando.)
- **Uma tela só**, a escolhida na janela de permissão.

## Instalação e interface (`setup.rs`, `interface_linux.rs`)

`./deskside-agent install`, sem administrador, tudo na conta do usuário:

| O quê | Onde |
|---|---|
| executável e ícone | `~/.local/share/deskside/` |
| início no login | `~/.config/autostart/deskside.desktop` |
| entrada no menu | `~/.local/share/applications/deskside.desktop` |
| configuração e identidade | `~/.config/deskside/` (como antes) |

Depois de copiar, sobe a cópia instalada solta do terminal e explica o login
automático — sem ligá-lo: é decisão de quem usa o computador. Instalar é
sempre pedido explícito; dois cliques no executável não instalam.

**Reinstalar com o Deskside aberto** fecha o que está rodando (pelo nome do
processo, só os da mesma conta) e sobe o novo. Antes, o novo via "já está
rodando" e saía, e a versão antiga seguia no ar sem ninguém perceber.

**Uma instância só**, como no Mac (arquivo trancado em `~/.config/deskside`):
abrir pelo menu com o agente rodando mostra a notificação "já está rodando".

**No lugar da barra "está controlando"**, uma notificação crítica (não some
sozinha) com o botão **Desconectar**, que faz o mesmo que o da barra: fecha a
tela e encerra o login daquele celular. O GNOME com Wayland não deixa fixar
uma janela por cima de tudo.

**O código de pareamento** chega numa notificação e some quando é usado.

**O ícone ao lado do relógio** (StatusNotifierItem, que o Ubuntu e o KDE
mostram): estado, código, Desconectar, Desinstalar (pergunta antes, numa
notificação) e Sair. O GNOME puro (Fedora) não mostra ícones; por isso nada
essencial depende dele.

`uninstall` pela linha de comando tira o início no login, o menu e o
executável, mas mantém a identidade (reinstalar não pede pareamento). O
Desinstalar do ícone apaga também a identidade e a configuração.

## Energia (`power.rs`, `awake.rs`)

- **Desligar, reiniciar e suspender** pelo `logind`, o mesmo pedido do menu
  do GNOME. Sem senha para quem está na sessão; com outra pessoa conectada ao
  computador, o sistema pede a senha de administrador na tela dele.
- **Manter pronto**: uma trava `sleep` no `logind` e um pedido à sessão do
  GNOME (que decide sozinho suspender depois de um tempo parado). Fora do
  GNOME, só a trava do `logind`.
- Tomada ou bateria por `/sys/class/power_supply`, ignorando pilhas de mouse e
  fone. Máquina virtual não expõe nada e conta como tomada.

## Área de transferência (`clipboard.rs`, `wayland.rs`)

Texto e imagem nos dois sentidos, o aviso automático de cópia nova e os
arquivos copiados no gerenciador de arquivos.

- **Wayland**: só a janela em foco lê a área de transferência, e o agente não
  tem janela. Vai pelo portal, dentro da sessão que abre quando o celular abre
  a tela — o único lugar do app que copia e cola. Fora dela, o celular é
  avisado. O teste `scripts/spike-clipboard.py` (Ubuntu 26.04, GNOME 50)
  confirmou os dois sentidos, com acentos, e que a ficha guardada continua
  dispensando a janela de permissão.
  - Copiar no computador: o portal avisa, e o agente lê o texto na hora.
  - Colar o que veio do celular: no Wayland quem copiou **serve** os dados a
    cada Ctrl+V, então o agente guarda o conteúdo enquanto a sessão existir.
  - O descritor que o portal entrega não bloqueia: ler antes de o programa
    dono escrever dá "tente de novo", e não "acabou".
- **X11**: direto, pela `arboard`, a qualquer hora.

A primeira sessão depois de atualizar pode mostrar a janela de permissão uma
vez: a ficha guardada foi dada antes de o agente pedir a área de
transferência.

## Som (`audio.rs`)

O que vai para o alto-falante, pelo PipeWire: um fluxo de gravação com
`stream.capture.sink`, que o liga ao monitor da saída padrão (e acompanha a
troca de saída). Sem portal nem janela de permissão, no Wayland e no X11.
Codificado com o mesmo Opus em Rust puro do Mac, na mesma faixa de áudio.

O monitor entrega o som **antes** do volume e do mudo do computador (medido
com um tom: mesmo nível em 100%, 10% e mudo). Por isso o ganho do app é
ignorado no Linux — o truque do Windows (computador baixinho, ganho alto no
celular) não é preciso, e ganho alto só cortaria o som. O computador pode
ficar mudo, e o celular ouve normal.

Sem PipeWire (Linux de antes de 2022, só com PulseAudio), o celular é avisado.

## O que ainda não existe no Linux

Responde ao celular que não dá, em vez de fingir que fez: abrir e fechar
programas, brilho e modo apresentação. Recusas
(um "desligar" que pediu senha, por exemplo) chegam ao celular numa faixa no
rodapé da tela remota (`aviso.rs`) — só com a tela aberta; sem ela, ficam no
diário.

## Limites conhecidos

- **Antes do login não funciona**: é regra do Wayland. Para o computador ficar
  alcançável depois de ligar, ele precisa de login automático.
- **Tela bloqueada**: ainda não testado se o GNOME manda imagem com a tela
  travada.
- Testado só no Ubuntu com GNOME. KDE e Fedora: a confirmar.

## Testar

O GitHub monta o executável a cada push no agente
(`.github/workflows/agente-linux.yml`) e publica no pré-lançamento
`agente-linux`:

    uname -m   # x86_64 (Intel e AMD) ou aarch64 (ARM)
    wget https://github.com/Cchaves20/RemoteOne/releases/download/agente-linux/Deskside-linux-$(uname -m).tar.gz
    tar xzf Deskside-linux-$(uname -m).tar.gz
    cd deskside && ./deskside-agent install

Para só testar, sem instalar: `./deskside-agent run`.

Os pacotes são compilados no Debian 12 (glibc 2.36): rodam em sistemas de
2023 para cá. Num mais antigo, a mensagem é sobre `GLIBC_2.xx`.

O código de pareamento aparece numa notificação (e no terminal, com `run`).

Para compilar à mão (Debian 12, Ubuntu 22.04 ou mais novos):

    sudo apt install libpipewire-0.3-dev libclang-dev clang pkg-config \
      libwayland-dev libgbm-dev libegl-dev libxcb1-dev libxcb-randr0-dev \
      libxcb-shm0-dev libxcb-xfixes0-dev libssl-dev libxkbcommon-dev xkb-data
    cd agent && cargo build --release

## Próximas fases

- **Fase 3:** programas e atualização automática (energia, área de
  transferência e som já entraram).
