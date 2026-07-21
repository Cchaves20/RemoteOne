# Pareamento de dispositivos (Etapa 5)

Vincula um computador (agente) a uma conta de usuário. Depois de pareado, o
computador aparece na lista de dispositivos da conta e pode ser controlado.

## Decisão de design: o backend gera o código

O documento do projeto diz "o agente gera o código". Optamos por **gerar o
código no backend** por ser a fonte única da verdade: garante unicidade (sem
colisão entre dois computadores) e controla a expiração. Do ponto de vista do
usuário o fluxo é idêntico — o agente apenas exibe o código que recebe.

O alfabeto (sem `0/O/1/I/L`) e o tamanho (9 caracteres) são iguais nos dois
lados: `app/pairing.py` (backend) e `agent/src/pairing.rs` (agente).

## Fluxo

```
Agente                     Backend                     App (usuário logado)
  │  ── hello ───────────────►  device não pareado?
  │  ◄────────── pair_code ──   gera código + expiração
  │  (exibe o código)
  │                                              informa o código
  │                             ◄──── POST /api/v1/pairing/claim ────
  │                             cria Device (device_id ↔ user)
  │  ── heartbeat ───────────►
  │  ◄───────────── paired ──   detecta o vínculo e avisa
  │  (mostra "pareado com <conta>")
```

Ao reconectar, um dispositivo já pareado recebe `paired` diretamente após o
`welcome`, em vez de um novo `pair_code`.

> **Nota de latência:** o agente é avisado do pareamento no próximo heartbeat
> (≤10 s), não instantaneamente. É simples e robusto para o MVP; um push
> imediato pela conexão é uma otimização futura.

## Endpoints HTTP (autenticados)

| Método | Rota | Corpo | Resposta |
|---|---|---|---|
| POST | `/api/v1/pairing/claim` | `{code}` | 201 + dispositivo; 404 inválido, 410 expirado, 409 já pareado |
| GET | `/api/v1/devices` | — | lista dos computadores da conta |
| DELETE | `/api/v1/devices/{device_id}` | — | 204; 404 se não for da conta |

Cada conta pode ter **vários** computadores (Etapa 7.2); a listagem é sempre
restrita ao usuário autenticado.

## Mensagens WebSocket adicionadas

- `pair_code` (backend → agente): `{code, expires_in_seconds}`.
- `paired` (backend → agente): `{user_email}`.

Ver [`protocolo-websocket.md`](protocolo-websocket.md) para o protocolo completo.

## Verificação manual

1. Suba o backend (`docker compose up` em `backend/`) e rode o agente
   (`cargo run` em `agent/`). O agente exibe o código.
2. Cadastre-se/logue (ver [`autenticacao.md`](autenticacao.md)) e reivindique:
   ```bash
   curl -X POST http://localhost:8000/api/v1/pairing/claim \
     -H "Authorization: Bearer <access_token>" \
     -H "Content-Type: application/json" \
     -d '{"code":"<CÓDIGO_EXIBIDO>"}'
   ```
3. Em até 10 s o agente imprime "✓ Dispositivo pareado com a conta ...", e o
   computador aparece em `GET /api/v1/devices`.
