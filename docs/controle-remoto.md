# Controle remoto — mouse (Etapa 6)

Primeiro comando remoto: o app envia ações de mouse que o agente injeta no
computador pareado. É a primeira feature que toca a **camada de plataforma**
do agente (injeção de entrada no SO).

## Onde funciona de verdade

A injeção de entrada é específica do sistema operacional. Nesta etapa:

- **Windows** — implementação real via crate `enigo` (o cursor se move,
  clica e rola de verdade). É a plataforma disponível para teste no projeto.
- **Linux / macOS** — *stub* que apenas registra a ação (`[mouse-stub] ...`).
  Permite desenvolver e testar todo o caminho app → backend → agente sem
  sessão gráfica; a implementação real entra numa fase posterior.

A dependência `enigo` é declarada apenas para Windows
(`[target.'cfg(windows)'.dependencies]` em `agent/Cargo.toml`), então os
builds de Linux/macOS não a compilam. Ver a estratégia por plataforma em
[`estrategia-de-testes.md`](estrategia-de-testes.md).

## Caminho do comando

```
App (usuário logado)                Backend                     Agente
  │  POST /devices/{id}/input ────►  valida posse + online
  │      {kind, ...}                 ├─ relay via WebSocket ───►  injeta no SO
  │  ◄──────────── 204 / 503 ─────   (503 se o agente offline)
```

Nesta etapa o comando vai por **HTTP** (um por requisição) — simples de testar
e suficiente para cliques e ajustes. O **streaming contínuo** do touchpad
(muitos eventos por segundo) usará um canal WebSocket dedicado do app, a ser
adicionado junto com o cliente Flutter.

## Endpoint

`POST /api/v1/devices/{device_id}/input` (autenticado). Corpo = uma ação:

| kind | Campos | Efeito |
|---|---|---|
| `mouse_move` | `dx`, `dy` (relativos) | Move o cursor |
| `mouse_click` | `button` (`left`/`right`/`middle`) | Clica |
| `mouse_scroll` | `dy` (+ = para cima) | Rola verticalmente |

Respostas: `204` enviado; `404` dispositivo não é da conta; `503` agente
offline; `422` ação inválida.

## Verificação manual

Com backend + agente rodando e o dispositivo pareado (ver
[`pareamento.md`](pareamento.md)), pegue um access token e envie:

```bash
curl -X POST http://localhost:8000/api/v1/devices/<device_id>/input \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{"kind":"mouse_move","dx":50,"dy":0}'
```

No Windows o cursor se move; no Linux/macOS o agente imprime
`[mouse-stub] MouseMove { dx: 50, dy: 0 }`.
