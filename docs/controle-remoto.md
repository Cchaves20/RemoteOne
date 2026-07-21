# Controle remoto — mouse e teclado (Etapa 6)

O app envia ações de mouse e teclado que o agente injeta no computador
pareado. É a primeira feature que toca a **camada de plataforma** do agente
(injeção de entrada no SO).

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
| `key_text` | `text` | Digita o texto |
| `key_press` | `key` (tecla especial) | Pressiona Enter, setas, F1–F12, etc. |
| `key_combo` | `modifiers` (`ctrl`/`alt`/`shift`/`meta`), `key` | Atalho (ex.: Ctrl+C, Alt+F4) |

Teclas especiais aceitas em `key_press`: `enter`, `backspace`, `tab`,
`escape`, `space`, `delete`, `up`, `down`, `left`, `right`, `home`, `end`,
`page_up`, `page_down`, `f1`–`f12`. Em `key_combo`, `key` é um caractere
(ex.: `"c"`) ou um nome de tecla (`enter`, `tab`, `escape`, `delete`,
`space`, `f1`–`f4`).

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
`[input-stub] MouseMove { dx: 50, dy: 0 }`.

Para teclado, abra um editor de texto no computador e envie:

```bash
curl -X POST http://localhost:8000/api/v1/devices/<device_id>/input \
  -H "Authorization: Bearer <access_token>" -H "Content-Type: application/json" \
  -d '{"kind":"key_text","text":"Olá do meu celular!"}'
```
