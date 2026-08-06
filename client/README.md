# Deskside — Cliente (Flutter)

Aplicativo usado no celular/tablet para controlar os computadores.

## O que já existe

- **Login/cadastro** (e-mail + senha) com token guardado na sessão.
- **Lista de computadores** pareados e **pareamento** pelo código.
- **Controle por toque direto** (`remote_screen.dart`): a tela do computador
  ocupa a tela inteira e o toque age como num touchscreen — tocar leva o
  cursor ao ponto e clica; arrastar faz o cursor seguir o dedo; segurar =
  clique direito; 2 dedos = rolar (usa posição absoluta, `mouse_move_to`).
- **Teclado customizado** (`remote_keyboard.dart`): campo de texto + teclas
  que o celular não tem (Ctrl, Alt, Shift, Tab, Esc, setas, Enter, Del). Os
  modificadores são grudentos: Ctrl e depois C envia Ctrl+C.
- **Tela em tempo real**: os frames chegam por WebSocket (`/ws/viewer/{id}`),
  empurrados pelo backend, com borda visível, indicador de fps e vibração ao
  clicar.
- **Lupa (zoom)** para acessibilidade: botão que amplia a tela (pinça ou botões
  + / −); como o toque é mapeado dentro do zoom, dá para controlar com precisão
  a área ampliada.
- **Login persistente**: os tokens ficam no armazenamento seguro
  (`token_store.dart`), então o app lembra o login entre aberturas.
- **Reconexão automática** da tela e **tela do celular sempre acesa** durante
  a sessão de controle.
- **Bloqueio por Face ID/biometria** opcional (`lock_gate.dart`, fail-open).
- **Verificação em duas etapas (2FA)** com app autenticador (TOTP): ativar por
  QR Code nas configurações e informar o código de 6 dígitos no login.
- **Tutorial de gestos** na primeira vez que se controla um PC (e revisável em
  Configurações → Ajuda).
- **Status online/offline** de cada computador na lista (ponto verde/cinza).
- **Aplicativos do computador** (`apps_screen.dart`): abas "Área de trabalho" e
  "Abertos", com busca — tocar abre um programa; nos abertos, o X encerra.
  (O backend também sabe listar o menu Iniciar inteiro, via `kind=installed`,
  mas o app não expõe: são centenas de entradas.)
- **Dock de aplicativos** na tela de controle, no estilo do macOS: barra
  flutuante **sempre visível** sobre a tela, compacta (só ícones, nome no
  toque longo) e **móvel** — arraste pela alça para deslocá-la ao longo da
  borda. Fica em pé à direita na horizontal e deitada embaixo na vertical;
  some no modo lupa. Os ícones são os **reais** de cada programa (o agente
  extrai do atalho); sem ícone, mostra a inicial do nome.
- **Ligar (Wake-on-LAN)**: computadores offline mostram "Ligar" no menu — o
  backend usa outro PC seu ligado na mesma rede para enviar o pacote mágico
  (peer-to-peer, sem configuração). Tela de ajuda em Configurações explica o
  modo padrão e o modo avançado (roteador) com aviso de segurança.
- **Ações do computador** (menu na lista): controlar, **renomear**, **desligar/
  reiniciar/suspender** (energia) e **remover** da conta.
- **Qualidade da tela ajustável** (Econômico/Equilibrado/Nítido): define fps,
  qualidade do JPEG e largura, enviados ao agente ao abrir a tela.
- **Configurações** (`settings_screen.dart`): tema (automático/claro/escuro),
  **idioma** (automático/PT-BR/Inglês/Chinês/Francês/Espanhol), qualidade da
  tela, bloqueio biométrico, **alterar e-mail**, **alterar senha**, sair,
  **excluir conta** e "Sobre".
- **5 idiomas** (`l10n/strings.dart`): a interface segue o idioma do sistema ou
  um escolhido manualmente — Português, English, 中文, Français, Español.

Estrutura:

```
lib/
  main.dart                 raiz do app (login ↔ dispositivos)
  models/device.dart
  services/api_client.dart  chamadas REST ao backend
  services/app_state.dart   estado (auth + dispositivos)
  screens/                  login, dispositivos, controle
  widgets/touchpad.dart
```

## Rodar

Gere as pastas de plataforma (uma vez) e rode:

```bash
flutter create --org com.deskside --project-name deskside_client \
  --platforms=android,ios,windows .
flutter pub get
flutter analyze        # confira que não há erros
flutter test           # testes de widget (usam http mockado)
flutter run -d windows # ou no emulador Android / iPhone
```

## Apontar o app ao backend (importante)

O app precisa alcançar o backend pela rede. A URL padrão é
`http://localhost:8000`, mas isso só vale quando app e backend estão na mesma
máquina (ex.: app Windows no mesmo PC do backend).

Para o **celular/emulador**, use o **IP do computador na rede local** (ex.:
`http://192.168.0.10:8000`) — descubra com `ipconfig` (Windows). Você pode:

- editar o campo **Servidor** na tela de login, ou
- fixar no build: `flutter run --dart-define=DESKSIDE_BACKEND=http://192.168.0.10:8000`

Casos comuns:

| Onde o app roda | URL do backend |
|---|---|
| App Windows, backend no mesmo PC | `http://localhost:8000` |
| Emulador Android, backend no host | `http://10.0.2.2:8000` |
| iPhone/iPad na mesma rede Wi-Fi | `http://IP_DO_PC:8000` |

> O backend precisa aceitar conexões da rede: rode o uvicorn com
> `--host 0.0.0.0` (o `docker compose` já publica a porta 8000).

## Fluxo de teste ponta a ponta

1. Backend rodando (`docker compose up` em `backend/`).
2. Agente rodando no computador (`cargo run` em `agent/`) — exibe o código.
3. No app: cadastre-se/entre, toque em **Parear**, informe o código, abra o
   computador na lista e use o touchpad. O cursor se move no computador.
