# RemoteOne

Aplicativo multiplataforma de controle remoto e integração entre dispositivos:
o celular/tablet controla computadores (mouse, teclado, tela remota, arquivos,
multimídia, energia e mais).

## Arquitetura

| Componente | Pasta | Tecnologia | Papel |
|---|---|---|---|
| Cliente | [`client/`](client/) | Flutter | App no celular/tablet (iOS, Android, iPadOS, Windows) |
| Agente | [`agent/`](agent/) | Rust | Serviço no computador controlado (Windows, Linux, macOS) |
| Backend | [`backend/`](backend/) | FastAPI + PostgreSQL + Redis | Autenticação, pareamento e comunicação em tempo real |

O escopo completo de features e etapas está no documento do projeto; a
estratégia para testar todas as plataformas sem possuir todos os aparelhos
está em [`docs/estrategia-de-testes.md`](docs/estrategia-de-testes.md).

Documentação por etapa:

- [`docs/protocolo-websocket.md`](docs/protocolo-websocket.md) — canal agente ↔ backend (Etapa 4)
- [`docs/autenticacao.md`](docs/autenticacao.md) — usuários, login e JWT (Etapa 2)
- [`docs/pareamento.md`](docs/pareamento.md) — vincular computador à conta (Etapa 5)
- [`docs/controle-remoto.md`](docs/controle-remoto.md) — mouse e teclado remotos (Etapa 6)
- [`docs/tela-remota.md`](docs/tela-remota.md) — ver a tela do PC no app (Etapa 7)
- [`docs/video-e-latencia.md`](docs/video-e-latencia.md) — pipeline de vídeo, otimizações medidas e o caminho até o WebRTC
- [`docs/webrtc-plano.md`](docs/webrtc-plano.md) — a migração do vídeo para WebRTC: plano, medições e diário das decisões
- [`docs/atualizar-tudo.md`](docs/atualizar-tudo.md) — atualizar agente, app e VPS de um terminal só
- [`docs/transferencia-de-arquivos.md`](docs/transferencia-de-arquivos.md) — trazer e mandar arquivos entre o celular e o computador
- [`docs/area-de-transferencia.md`](docs/area-de-transferencia.md) — copiar num aparelho e colar no outro
- [`docs/som-do-computador.md`](docs/som-do-computador.md) — ouvir no telefone o que toca no computador
- [`docs/monitor-e-midia.md`](docs/monitor-e-midia.md) — painéis retráteis de CPU/memória/disco e de controle de mídia
- [`docs/instalar-no-iphone.md`](docs/instalar-no-iphone.md) — instalar o app no iPhone sem Mac (sideload)
- [`docs/rodar-sem-terminal.md`](docs/rodar-sem-terminal.md) — agente e backend em segundo plano (sem terminal; base para desligar/Wake-on-LAN)
- [`docs/pc-sempre-pronto.md`](docs/pc-sempre-pronto.md) — IP fixo + backend no boot + login automático (controlar sem tocar no PC)
- [`docs/deploy-vps-oracle.md`](docs/deploy-vps-oracle.md) — backend na nuvem (Oracle Free + DuckDNS + HTTPS), controlar de qualquer lugar

## Como rodar

### Backend

```bash
cd backend
docker compose up --build      # API em http://localhost:8000/health
# ou, sem Docker:
pip install -e ".[dev]" && uvicorn app.main:app --reload
pytest                         # testes
```

### Agente

```bash
cd agent
cargo run     # conecta ao backend por WebSocket e envia heartbeats
cargo test    # testes (rodam em Windows, Linux e macOS)
```

Com o backend rodando, o agente aparece online em
<http://localhost:8000/api/v1/agents>. O backend é configurável por variável
de ambiente: `REMOTEONE_BACKEND_URL` (padrão `ws://127.0.0.1:8000/ws/agent`).

### Cliente

```bash
cd client
flutter pub get
flutter run -d windows   # iteração rápida no PC (sem precisar de celular)
flutter test
```

As pastas de plataforma (`android/`, `ios/`, ...) ainda não são versionadas —
veja [`client/README.md`](client/README.md).

## CI — o laboratório de plataformas

| Pipeline | Onde roda | O que cobre |
|---|---|---|
| [`agent.yml`](.github/workflows/agent.yml) | GitHub Actions (matriz Windows/Linux/**macOS**) | Compilação e testes do agente nos 3 sistemas — macOS sem possuir um Mac |
| [`backend.yml`](.github/workflows/backend.yml) | GitHub Actions (Linux) | Lint, testes e build Docker |
| [`client.yml`](.github/workflows/client.yml) | GitHub Actions (Linux) | `flutter analyze`, testes de widget e APK Android |
| [`codemagic.yaml`](codemagic.yaml) | Codemagic (Mac na nuvem) | Build iOS e, quando ativado, publicação no TestFlight |
