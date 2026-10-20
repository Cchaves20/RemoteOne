# Agente no Linux

## Onde está

**Fase 1 (esta): tela, mouse e teclado.** Ainda sem instalador, início
automático, ícone ou barra de controle — roda-se no terminal.

| Sessão gráfica | Tela | Mouse e teclado |
|---|---|---|
| Wayland (Ubuntu 24.04+, Fedora) | portal do sistema + PipeWire | portal do sistema |
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
  acende um ícone de "tela compartilhada" no alto — que assim vira o aviso de
  que alguém está vendo, até a barra de controle chegar na fase 2.
- **Ficha recusada:** o sistema volta a mostrar a janela. O agente espera 3 s,
  avisa o celular ("o computador está pedindo permissão…") e desiste em 2 min,
  em vez de ficar preso.
- **Teclado pelo símbolo** (keysym), e não pela posição da tecla: "ç" sai "ç"
  em qualquer layout.
- **Uma tela só**, a escolhida na janela de permissão.

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

    wget https://github.com/Cchaves20/RemoteOne/releases/download/agente-linux/Deskside-linux-x86_64.tar.gz
    tar xzf Deskside-linux-x86_64.tar.gz
    cd deskside && ./deskside-agent

O código de pareamento aparece no terminal.

Para compilar à mão (Ubuntu 24.04+):

    sudo apt install libpipewire-0.3-dev libclang-dev clang pkg-config \
      libwayland-dev libgbm-dev libegl-dev libxcb1-dev libxcb-randr0-dev \
      libxcb-shm0-dev libxcb-xfixes0-dev libssl-dev
    cd agent && cargo build --release

## Próximas fases

- **Fase 2:** ícone, janela e barra "está controlando", instalador e início
  automático, e o login automático explicado na instalação.
- **Fase 3:** área de transferência, som, energia, programas abertos e
  atualização automática.
