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
| `hello` | `device_id`, `hostname`, `os`, `agent_version` | Primeira mensagem ao conectar |
| `heartbeat` | — | Periódico, mantém a sessão viva |

## Mensagens do backend → agente

| type | Campos | Quando |
|---|---|---|
| `welcome` | `server_version` | Resposta ao `hello` |
| `ack` | — | Resposta ao `heartbeat` |
| `error` | `message` | Mensagem inválida ou fora de ordem |
| `pair_code` | `code`, `expires_in_seconds` | Após o `welcome`, se o dispositivo não está pareado |
| `paired` | `user_email` | Quando o dispositivo é vinculado a uma conta |

O pareamento em si está documentado em [`pareamento.md`](pareamento.md).

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
