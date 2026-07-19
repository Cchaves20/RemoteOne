# RemoteOne — Cliente (Flutter)

Aplicativo usado no celular/tablet para controlar os computadores.

## Plataformas-alvo

| Plataforma | Como testar sem o hardware completo |
|---|---|
| iOS / iPadOS | Build na nuvem via Codemagic → TestFlight → iPhone/iPad físicos |
| Android | Emulador (AVD) no PC + Firebase Test Lab nos marcos |
| Windows (tablet) | Executável desktop no Surface Book 3 |
| HarmonyOS | Fase 2 — port da comunidade OpenHarmony + DevEco Studio |

## Pastas de plataforma

As pastas `android/`, `ios/`, `windows/` etc. **não são versionadas ainda**.
Gere-as localmente (ou deixe a CI gerar) com:

```bash
flutter create --org com.remoteone --project-name remoteone_client \
  --platforms=android,ios,windows .
```

Depois de gerar e personalizar (ícones, permissões, bundle id), commite-as.

## Desenvolvimento no dia a dia (sem Mac)

```bash
flutter pub get
flutter run -d windows   # iteração rápida no Dell G5 / Surface
flutter test             # testes de widget
```

Builds de iOS são feitos pelo `codemagic.yaml` na raiz do repositório.
