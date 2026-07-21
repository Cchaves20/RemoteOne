# RemoteOne — Cliente (Flutter)

Aplicativo usado no celular/tablet para controlar os computadores.

## O que já existe

- **Login/cadastro** (e-mail + senha) com token guardado na sessão.
- **Lista de computadores** pareados e **pareamento** pelo código.
- **Controle remoto**: touchpad (deslizar = mover, tocar = clicar), botões de
  clique/rolagem e campo de texto para digitar no computador.

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
flutter create --org com.remoteone --project-name remoteone_client \
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
- fixar no build: `flutter run --dart-define=REMOTEONE_BACKEND=http://192.168.0.10:8000`

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
