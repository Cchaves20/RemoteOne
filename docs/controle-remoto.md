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

## Barra de sugestões

Acima do teclado aparecem até três palavras. Ela **nunca corrige sozinha**:
tocar numa palavra é a única coisa que muda o texto.

Essa recusa é deliberada. O teclado digita direto no computador, e os usos mais
comuns são terminal, caminho de arquivo e senha — lugares onde "quase certo" é
simplesmente errado, e onde uma correção automática causaria mais estrago do que
o erro de digitação que ela tentava consertar. A barra também não sugere nada
sobre número, símbolo ou algo com `\` e `:`, justamente por isso.

De onde vêm as palavras:

1. **O que você já digitou** — é a fonte que sabe os seus nomes próprios, os
   seus comandos e o seu jargão, que dicionário nenhum traz. Fica só no celular.
2. **Uma lista curta de palavras comuns** do idioma da interface, para o
   primeiro dia valer alguma coisa. Chinês não recebe lista: a escrita não
   funciona por palavras separadas, e barra vazia é mais honesto que palpite
   ruim.

Digitar sem acento acha a palavra acentuada (`voce` → `você`), e a maiúscula de
quem digitou é mantida (`Proj` → `Projeto`).

Dá para desligar em **Configurações → Qualidade da tela → Sugestões de
palavra**.

### Por que a troca é uma ação só

Trocar a palavra significa apagar o que foi digitado e escrever o certo. Isso
vai numa única ação `key_replace` (com `backspaces` e `text`), e não em várias
mensagens.

O motivo é o canal de dados do WebRTC, que é **não ordenado de propósito** — o
que é bom para o mouse, onde o movimento mais novo vale mais que o antigo. Em
mensagens separadas, o texto novo poderia chegar antes dos backspaces e o
resultado sairia embaralhado. Como ação única, ou chega inteira ou não chega.

O app só rastreia a palavra enquanto ela faz sentido: mover o cursor (um toque
na tela, uma seta, Enter) zera o rastro, porque a partir dali o que o app acha
que está sendo digitado não corresponde mais ao que existe na tela do
computador.
