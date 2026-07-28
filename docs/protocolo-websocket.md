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
| `app_list` | `request_id`, `apps[]` (`id`, `name`, `icon?`) | Resposta a um `list_apps`; `icon` é o ícone real do programa em PNG base64 (ver "pergunta e resposta" abaixo) |
| `file_list` | `request_id`, `listing?` (`path`, `parent?`, `entries[]`), `error?` | Resposta a um `list_files`. Vem `listing` **ou** `error` — pasta sem permissão não pode chegar ao app como pasta vazia |
| `file_chunk` | `transfer_id`, `seq`, `data` (base64) | Um pedaço de arquivo indo ao celular; `seq` detecta pedaço fora de ordem |
| `file_done` | `transfer_id`, `ok`, `detail?`, `size?` | Fim de transferência nos dois sentidos: `detail` traz o caminho salvo ou o motivo da falha |
| `system_stats` | `request_id`, `stats` (`cpu_percent`, `memory_used`, `memory_total`, `disk_used`, `disk_total`, `disk_name`, `uptime_seconds`) | Resposta a um `system_info`. Bytes crus e porcentagem: quem formata é o app, que sabe o idioma |

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
| `list_apps` | `request_id`, `kind` (`desktop`/`installed`/`running`) | Pede a lista de aplicativos; o agente responde com `app_list`. `desktop` = atalhos da área de trabalho (com ícones), usado pela dock |
| `launch_app` | `id` (caminho do atalho) | Abre um programa no computador |
| `close_app` | `id` (PID) | Encerra um programa em execução |
| `system_info` | `request_id` | Pede as métricas do computador; o agente responde com `system_stats` |
| `list_files` | `request_id`, `path` (vazio = pasta do usuário) | Pede o conteúdo de uma pasta |
| `read_file` | `transfer_id`, `path` | Pede que o agente leia um arquivo e o mande em `file_chunk` |
| `write_file_begin` | `transfer_id`, `name`, `size` | Começa a receber um arquivo vindo do celular |
| `write_file_chunk` | `transfer_id`, `seq`, `data` (base64) | Um pedaço do arquivo que sobe ao computador |
| `write_file_end` | `transfer_id` | Fim do envio; o agente publica o arquivo e responde `file_done` |
| `cancel_transfer` | `transfer_id` | Desiste de uma transferência em curso, nos dois sentidos |
| `media` | `action` (`play_pause`/`next`/`previous`/`volume_up`/`volume_down`/`mute`) | Aciona uma tecla multimídia. São teclas **globais**: valem para quem estiver tocando som, sem depender da janela em foco |

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

Frames repetidos não são enviados: o agente compara um hash da imagem com o do
frame anterior e, se a tela não mudou, não transmite nada. Um silêncio no canal
binário significa "continua igual", não "caiu" — quem entra no meio recebe o
último frame guardado pelo backend. Detalhes em
[`video-e-latencia.md`](video-e-latencia.md).

## Sinalização de WebRTC

O mesmo par de canais transporta a negociação de WebRTC, que vai substituir o
JPEG pelo vídeo comprimido (plano em [`webrtc-plano.md`](webrtc-plano.md)). O
backend **não participa** da negociação: só encaminha.

Cada app conectado em `/ws/viewer/{device_id}` recebe um `session_id` interno,
porque o mesmo agente pode negociar com vários apps ao mesmo tempo. O app nunca
vê esse identificador — o backend o acrescenta na ida e o remove na volta.

App → backend → agente:

| Tipo | Campos | O que é |
| --- | --- | --- |
| `webrtc_offer` | `sdp` | Oferta do app, que quer receber a tela |
| `webrtc_ice` | `candidate`, `sdp_mid?`, `sdp_mline_index?` | Candidato ICE |

Agente → backend → app:

| Tipo | Campos | O que é |
| --- | --- | --- |
| `webrtc_answer` | `session_id`, `sdp` | Resposta do agente |
| `webrtc_ice` | `session_id`, `candidate`, … | Candidato ICE |

E o backend avisa o agente por conta própria quando um app sai, com
`webrtc_close` — assim a conexão daquela sessão não fica pendurada.

Dois detalhes que importam:

- **`candidate` vazio é válido** e significa "acabaram os meus candidatos".
  Descartá-lo deixaria a outra ponta esperando para sempre.
- **O backend confere que a sessão pertence ao dispositivo** antes de repassar
  a resposta do agente. Sem essa checagem, um agente que se comportasse mal
  poderia injetar sinalização na sessão de outro computador chutando um
  `session_id`.

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
