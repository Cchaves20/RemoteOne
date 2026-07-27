# Protocolo WebSocket — agente ↔ backend

Canal entre o agente desktop (Rust) e o backend (FastAPI), base da Etapa 4
do projeto. O agente conecta em `ws://<backend>/ws/agent`.

O formato de fio é JSON com um campo discriminador `type`. As duas
implementações precisam ficar em sincronia:

- Backend: [`backend/app/protocol.py`](../backend/app/protocol.py)
- Agente: [`agent/src/protocol.rs`](../agent/src/protocol.rs)

Cada lado tem testes que fixam esse formato; ao alterar uma mensagem,
atualize os dois.

## Fluxo

```
Agente                          Backend
  |  ── hello ──────────────────►  registra o agente como online
  |  ◄──────────────── welcome ─   confirma (envia versão do servidor)
  |                                
  |  ── heartbeat ──────────────►  atualiza last_seen
  |  ◄──────────────────── ack ─   confirma
  |            (a cada 10s)         
  |                                
  |  (desconexão)                   remove o agente do registro
```

## Mensagens do agente → backend

| type | Campos | Quando |
|---|---|---|
| `hello` | `device_id`, `hostname`, `os`, `agent_version`, `mac?` | Primeira mensagem ao conectar (`mac` opcional, para Wake-on-LAN) |
| `heartbeat` | — | Periódico, mantém a sessão viva |
| `app_list` | `request_id`, `apps[]` | Resposta a um `list_apps` (ver "pergunta e resposta" abaixo) |

## Mensagens do backend → agente

| type | Campos | Quando |
|---|---|---|
| `welcome` | `server_version` | Resposta ao `hello` |
| `ack` | — | Resposta ao `heartbeat` |
| `error` | `message` | Mensagem inválida ou fora de ordem |
| `pair_code` | `code`, `expires_in_seconds` | Após o `welcome`, se o dispositivo não está pareado |
| `paired` | `user_email` | Quando o dispositivo é vinculado a uma conta |
| `input` | `action` (mouse/teclado) | Comando de entrada a injetar no computador (Etapa 6) |
| `start_stream` | `max_fps`, `quality?`, `max_width?` | Inicia a transmissão da tela; `quality`/`max_width` (opcionais) vêm do ajuste de qualidade do app (Etapa 7) |
| `stop_stream` | — | Encerra a transmissão da tela |
| `power` | `action` (`shutdown`/`restart`/`suspend`) | Desliga, reinicia ou suspende o computador |
| `wake` | `mac` | Pede a este agente que acorde (Wake-on-LAN) um vizinho da LAN pelo MAC |
| `list_apps` | `request_id`, `kind` (`installed`/`running`) | Pede a lista de aplicativos; o agente responde com `app_list` |
| `launch_app` | `id` (caminho do atalho) | Abre um programa no computador |
| `close_app` | `id` (PID) | Encerra um programa em execução |

## Pergunta e resposta (aplicativos)

Quase tudo aqui é mão única (o backend manda, o agente executa). Listar
aplicativos é a exceção: o backend precisa **esperar a resposta**. Para isso,
cada pedido leva um `request_id`, e o backend guarda um "pedido pendente"
([`backend/app/rpc.py`](../backend/app/rpc.py)) até chegar o `app_list` com o
mesmo id — ou até estourar o tempo limite (15 s → HTTP 504).

```
App          Backend                         Agente
 |  GET /apps   |                               |
 |  ──────────► |  ── list_apps (request_id) ─► |  varre menu Iniciar
 |              |  ◄──── app_list (request_id)  |  (ou lista processos)
 |  ◄────────── |                               |
```

O agente lista fora do laço de eventos (`spawn_blocking`), então varrer os
programas não trava o controle remoto que estiver em andamento.

O agente responde ao `start_stream` enviando frames JPEG como mensagens
**binárias** (agente → backend). O backend os repassa em tempo real aos apps
conectados em `/ws/viewer/{device_id}` (que autenticam com
`{"token": ...}`). A tela remota está em [`tela-remota.md`](tela-remota.md).

O pareamento está documentado em [`pareamento.md`](pareamento.md) e o controle
remoto em [`controle-remoto.md`](controle-remoto.md).

## Estado e identidade

- O `device_id` é um UUID gerado pelo agente na primeira execução e
  persistido em disco (`%APPDATA%\remoteone\device_id` no Windows,
  `~/.config/remoteone/device_id` no Linux/macOS), então o mesmo computador
  é reconhecido em conexões futuras.
- O registro de agentes online vive em memória no backend
  ([`backend/app/agents.py`](../backend/app/agents.py)). Ao escalar para
  múltiplos workers, passa a ser respaldado por Redis (já na stack).

## Verificação manual

1. Suba o backend: `cd backend && docker compose up` (ou `uvicorn app.main:app`).
2. Rode o agente: `cd agent && cargo run`.
3. Abra <http://localhost:8000/api/v1/agents> — o agente aparece com o
   `last_seen` avançando a cada heartbeat, e some ao encerrar o agente.
