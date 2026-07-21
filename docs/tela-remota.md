# Tela remota (Etapa 7)

Transmite a tela do computador para o app. Abordagem de MVP: **streaming de
frames JPEG** (algumas imagens por segundo), não vídeo H.264/VP9. É simples,
testável e entrega um desktop remoto funcional; codecs de vídeo ficam para
uma evolução futura.

## Onde a captura funciona

Como a injeção de entrada, a **captura de tela é específica do SO**:

- **Windows** — captura real via crate `xcap`.
- **Linux / macOS** — *stub* que gera um frame **sintético** (um gradiente com
  uma faixa que se move), permitindo testar todo o pipeline sem tela real.

`xcap` é declarado só para Windows em `agent/Cargo.toml`; a codificação JPEG
(crate `image`) é compartilhada e roda em qualquer plataforma.

## Fluxo (tempo real por WebSocket)

```
App                          Backend                      Agente
 │ WS /ws/viewer/{id} ───────►  1º viewer? manda start_stream ─► captura
 │ {"token": ...}               (autentica + checa posse)
 │ ◄──────────── frames JPEG ── empurra cada frame ◄── frames (binário, WS)
 │ (em tempo real, ~10 fps)
 │ (fecha o WS) ─────────────►  último viewer saiu? manda stop_stream ─► para
```

O app abre um WebSocket em `/ws/viewer/{device_id}` e envia
`{"token": "<access_token>"}` como primeira mensagem. Autenticado e sendo
dono do dispositivo, passa a **receber cada frame assim que chega** — sem
polling. O backend guarda também o último frame (para exibir algo na hora em
que um novo viewer entra).

- Parâmetros do agente (`agent/src/client.rs`): ~10 fps, largura máx. 1280 px,
  qualidade JPEG 55. A captura roda em `spawn_blocking` para não travar o
  tratamento de comandos. Fáceis de ajustar conforme rede/CPU.

### Alternativa por HTTP (para testar no navegador/`/docs`)

Os endpoints `POST /screen/start`, `GET /screen` e `POST /screen/stop`
continuam existindo: o `GET` devolve o último frame como `image/jpeg`. Útil
para validar a captura sem um cliente WebSocket, mas é polling (mais lento
que o WS).

## Endpoints (autenticados, exigem posse do dispositivo)

| Método | Rota | Efeito |
|---|---|---|
| POST | `/api/v1/devices/{id}/screen/start` | Pede ao agente que comece a transmitir |
| GET | `/api/v1/devices/{id}/screen` | Último frame (`image/jpeg`); 503 se ainda não há frame |
| POST | `/api/v1/devices/{id}/screen/stop` | Pede que pare e limpa o cache |

Erros: `404` dispositivo não é da conta; `503` agente offline ou sem frame.

## Mensagens WebSocket adicionadas

- `start_stream` / `stop_stream` (backend → agente).
- Frames JPEG como mensagens **binárias** (agente → backend).

## Verificação manual

Com backend + agente rodando e o dispositivo pareado:

```bash
TOKEN=... ; DEV=...
curl -X POST http://localhost:8000/api/v1/devices/$DEV/screen/start -H "Authorization: Bearer $TOKEN"
curl http://localhost:8000/api/v1/devices/$DEV/screen -H "Authorization: Bearer $TOKEN" -o tela.jpg
```

No Windows, `tela.jpg` é a captura real do computador; no Linux/macOS, o frame
sintético. Para parar: `POST .../screen/stop`.
