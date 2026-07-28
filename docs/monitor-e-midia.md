# Monitor do sistema e controle de mídia

Dois painéis retráteis na tela de controle: um mostra como está o computador
(CPU, memória, disco), o outro comanda o que ele está tocando.

São **retráteis** por decisão de projeto. O que está em jogo naquela tela é a
imagem do computador; tudo o que fica permanentemente sobre ela come área útil.
Cada painel tem o seu botão e só aparece quando alguém pede.

## Onde ficam

A posição muda com a orientação, porque o espaço livre muda: a imagem do
computador é 16:9, então com o celular deitado sobram faixas nas laterais e em
cima, e em pé sobram faixas em cima e embaixo.

| | Botão do monitor | Botão de mídia | Painel do monitor | Botões de mídia |
|---|---|---|---|---|
| Em pé | canto inferior esquerdo | canto inferior direito | faixa de cima | acima da dock |
| Deitado | canto inferior direito | canto superior direito | coluna à esquerda | faixa de cima |

Os botões ficam nas pontas da dock de aplicativos, que é o eixo que já organiza
os controles flutuantes: em pé ela é deitada na base, e deitado ela fica em pé à
direita.

## Monitor do sistema

O agente mede com o [`sysinfo`](https://crates.io/crates/sysinfo), que é
multiplataforma — diferente da captura de tela e da injeção de entrada, este
módulo não tem stub: o mesmo código roda no Windows, no Linux e no macOS.

O que aparece:

- **CPU** — uso somando todos os núcleos;
- **Memória** — usada / total;
- **Disco** — usado / total do disco do sistema (`C:` no Windows, `/` no resto);
- **Ligado há** — tempo desde que o computador iniciou.

As barras mudam de cor a partir de 70% (laranja) e 90% (vermelho). A cor é o que
se lê de longe, antes de ler o número.

### Detalhes que não são óbvios

**A CPU não é um instante, é um intervalo.** O `sysinfo` calcula o uso pela
diferença entre duas leituras, e exige pelo menos 200 ms entre elas. Um `System`
criado a cada pedido devolveria sempre 0% — que o usuário leria como "meu PC está
livre". Por isso o agente mantém o monitor vivo e tira a leitura de referência
**ao conectar**: quando o painel abre, os 200 ms já passaram há muito, e ninguém
paga a espera no meio da transmissão. Cada medida cobre o intervalo desde a
anterior, o que com o painel atualizando de 2 em 2 s dá uma média mais honesta
que uma amostra instantânea.

**Bytes crus no fio.** O agente manda números, não texto: quem formata em
"7,8 GB" é o app, que sabe o idioma do usuário. A conversão usa base 1024, para
o número bater com o que o Windows mostra em vez de ser 7% maior.

**O painel só consulta enquanto está aberto.** Medir custa uma ida e volta ao
computador; um painel fechado não deve pagar isso. E há um pedido de cada vez:
numa rede lenta os pedidos de 2 em 2 s se empilhariam, e a resposta que chegasse
por último poderia ser a mais velha.

**Uma medida que falha não apaga a anterior.** O painel continua mostrando o que
sabe, com o aviso embaixo — melhor um número de 4 s atrás do que um campo vazio.

## Controle de mídia

Seis botões: volume −, silenciar, anterior, tocar/pausar, próxima, volume +.

O agente aciona as **teclas multimídia** do teclado, via `enigo`
(`MediaPlayPause`, `MediaNextTrack`, `VolumeUp`…). É o detalhe que faz isso
funcionar bem: essas teclas são globais, atendidas por quem estiver tocando som,
e **não** vão para a janela em foco. Dá para pausar a música sem antes clicar no
player — que é justamente o que se quer de um controle remoto.

Por isso os comandos de mídia **não** são uma variante de `input_action`: o alvo
é diferente, e misturá-los sugeriria que dependem do foco.

O volume anda em passos do sistema (~2% por toque no Windows). Um controle
deslizante exigiria a API de áudio do Windows (Core Audio), que é bem mais
trabalho para pouca diferença prática.

## Caminho de uma consulta

```
 app            backend                    agente
  |  GET /system  |                          |
  |  ───────────► |  ── system_info (id) ──► |  mede (CPU/RAM/disco)
  |               |  ◄── system_stats (id) ─ |
  |  ◄─── 200 ────|                          |
```

Pergunta e resposta com `request_id`, o mesmo mecanismo da lista de aplicativos
([`backend/app/rpc.py`](../backend/app/rpc.py)). Mídia é mão única: não há
resposta a esperar.

## Endpoints

| Método | Rota | Corpo / resposta |
|---|---|---|
| `GET` | `/api/v1/devices/{id}/system` | Responde com as métricas. `503` se o agente está offline, `504` se ele não respondeu em 5 s |
| `POST` | `/api/v1/devices/{id}/media` | `{"action": "play_pause"}`. `204` no sucesso, `503` se offline |

Ambos exigem autenticação e só respondem ao dono do computador — métricas
revelam o uso da máquina, e apertar teclas nela é agir sobre ela.

## Verificação manual

1. Abra o controle de um computador.
2. Toque no botão do monitor (ícone de chip). Os quatro números aparecem e se
   atualizam de 2 em 2 s. Abra algo pesado no PC e veja a CPU subir.
3. Toque no botão de mídia (ícone de nota). Ponha uma música no PC e teste
   pausar, trocar de faixa e mudar o volume — sem colocar o player em foco.
4. Gire o celular: os painéis mudam de lugar conforme a tabela acima.

Para conferir se o backend no VPS já tem isto:

```bash
curl.exe -s https://SEU-HOST/health
```

`features` precisa conter `system-stats` e `media-keys`.
