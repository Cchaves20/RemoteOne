# Teste de carga do backend

Quantos computadores e celulares o servidor aguenta, onde ele quebra primeiro,
e o que o teste encontrou pelo caminho.

## O que se mede

O vídeo, o mouse e o teclado vão **direto** do celular ao computador (WebRTC);
o servidor só ajuda os dois a se acharem. O que pesa nele é:

- **Conexões abertas**: cada computador ligado mantém um `/ws/agent`, com uma
  batida a cada 10 s; cada celular com a tela aberta, um `/ws/viewer`.
- **Perguntas que atravessam o servidor até o computador**: com a tela
  aberta, o app pede o programa em primeiro plano a cada 3 s, os programas
  abertos a cada 10 s e, com o painel aberto, as métricas a cada 2 s
  (`remote_screen.dart`). Cada uma espera o computador responder — e no
  Windows a lista de programas abertos passa por um PowerShell, 1 a 2 s.
- **Login**: confere a senha com bcrypt, caro de propósito.
- **A retransmissão de vídeo (TURN)**, quando celular e computador não se
  alcançam direto. Não é testada: é calculada (ver abaixo).

## Como rodar

O simulador fica em `scripts/carga/`:

- `carga.py` finge ser computadores (respondem como o agente) e celulares
  (entram, abrem a tela, negociam o vídeo e pedem o que o app pede), em
  **degraus**: a cada degrau entram mais, e ele fica de pé por `--segundos`.
  Sai uma linha por degrau com p50/p95/p99 e erros; a subida para sozinha
  quando o p95 passa de `--teto-ms` ou os erros passam de `--teto-erros`.
- `preparar_local.py` cria contas e computadores pareados direto no banco de
  um backend **local** (nunca no de produção).

Local, com o servidor preso a um núcleo (o VPS é ainda mais fraco):

    cd backend
    DESKSIDE_DATABASE_URL=sqlite:////tmp/carga.db \
        python ../scripts/carga/preparar_local.py 3000 /tmp/contas.json
    DESKSIDE_DATABASE_URL=sqlite:////tmp/carga.db DESKSIDE_JWT_SECRET=x \
        taskset -c 0 uvicorn app.main:app --port 8000 &
    cd ../scripts/carga
    taskset -c 1-3 python carga.py --url http://127.0.0.1:8000 \
        --contas /tmp/contas.json --degraus 40,80,160,320 \
        --celulares-por-degrau 40,80,160,320 --atraso-programas-ms 1500 \
        --pid <pid do uvicorn>

No VPS: o workflow `.github/workflows/carga-vps.yml` roda num servidor do
GitHub contra `deskside.com.br` quando `scripts/carga/vps.json` muda. Só com
computadores sem parear — não há contas de teste lá —, com o prefixo
`carga-vps` nos `device_id`.

## Resultados locais (servidor em 1 núcleo, SQLite, um processo, como no VPS)

### Só computadores, ninguém usando

| Computadores | CPU (1 núcleo) | Memória | Batida p95 | `/health` p95 |
|---:|---:|---:|---:|---:|
| 250 | 5% | 107 MB | 3,7 ms | 5 ms |
| 500 | 8% | 126 MB | 3,2 ms | 6 ms |
| 1.000 | 14% | 164 MB | 3,5 ms | 9 ms |
| 2.000 | 24% | 241 MB | 4,2 ms | 6 ms |
| 3.000 | 35% | 319 MB | 7,0 ms | 15 ms |

Cerca de **80 KB e 0,01% de núcleo por computador ligado**. O contêiner do
VPS tem 512 MB: a memória acaba perto de **5.000 computadores**, antes da CPU.

### Celulares em uso (cada um com seu computador, que leva 1,5 s para listar programas)

**Antes da correção:** com **40 celulares o servidor travou inteiro** — nenhum
pedido respondia, nem o login, com a CPU em 0%. Ver "O defeito" abaixo.

**Depois da correção do estoque** (simulador ainda em um processo):

| Celulares | CPU média | Memória | Primeiro plano p95 | Batida p95 | Erros |
|---:|---:|---:|---:|---:|---:|
| 40 | 8% | 103 MB | 13 ms | 4 ms | 0 |
| 80 | 16% | 115 MB | 15 ms | 4 ms | 0 |
| 160 | 27% | 138 MB | 906 ms | 64 ms | 0 |

**Depois da memória de vínculos e do coletor de lixo** (ver "Parte A",
abaixo), com os celulares já logados e o simulador em três processos com
aiohttp, para ele não ser o limite:

| Celulares | CPU | Memória | Primeiro plano p50 | p95 | Erros |
|---:|---:|---:|---:|---:|---:|
| 1.000 | 41% | 280 MB | 34 ms | 184 ms | 0 |
| 1.500 | 49% (picos de 100%) | 412 MB | 1,1 s | 1,6 s | 0 |

O limite com o app de hoje fica entre **1.000 e 1.200 celulares de tela
aberta** por núcleo. O que sobra de tempo é quase todo da própria pilha web
(uvicorn, Starlette, FastAPI) atendendo os ~400 pedidos por segundo: o código
do Deskside quase não aparece no perfil.

### Com a parte B (perguntas pelo canal direto)

Os celulares abrem a tela e negociam o vídeo, mas o primeiro plano, os
programas abertos e as métricas vão direto ao computador (`--canal-direto`):

| Celulares + computadores | CPU | Memória | Batida p95 | `/health` p95 | Erros |
|---:|---:|---:|---:|---:|---:|
| 1.000 | 9% | 268 MB | 1,2 ms | 2 ms | 0 |
| 2.000 | 17% | 445 MB | 2,0 ms | 5 ms | 0 |
| 3.000 | 23% | 622 MB | 2,4 ms | 3 ms | 0 |
| 4.000 | 29% | 799 MB | 2,7 ms | 3 ms | 0 |
| 5.000 | 33% | 977 MB | 3,4 ms | 5 ms | 0 |

O processador deixa de ser o limite — pela inclinação, um núcleo chegaria
perto de 15.000 pares. O limite passa a ser a **memória: ~180 KB por par**
celular + computador. Com os 512 MB do contêiner do VPS, **cerca de 2.300
pares**; com 2 GB, perto de 10.000.

**Login:** cerca de **4 por segundo por núcleo** (o bcrypt). Uma multidão
digitando a senha ao mesmo tempo espera na fila: 1.000 pessoas entrando no
mesmo minuto não entram todas, e enquanto isso o resto fica lento. No uso
normal isso não acontece — o app guarda o acesso e o renova sem a senha —,
mas é o primeiro limite num "todo mundo de manhã reinstalou o app".

### Armadilhas do próprio teste

O simulador foi o limite três vezes, e cada vez parecia o servidor:

- Um processo Python só fingindo 640 aparelhos fica em 100% de um núcleo,
  com o servidor em 10%. Por isso `--processos`.
- O `httpx` gasta muito processador por pedido: com 1.000 celulares, três
  processos em 100% e o servidor em 34%. Trocado pelo `aiohttp` (6% cada).
- Um servidor de um experimento anterior ficou rodando na porta, e três
  rodadas falaram com ele sem ninguém notar — o novo não conseguia subir. O
  reinício agora confere quem escuta na porta.
- Celulares fazendo login com senha a cada degrau medem o bcrypt, não o uso.
  `preparar_local.py` agora abre um acesso por conta; `--entrar` volta ao
  login com senha.

## O defeito (corrigido)

O servidor tinha um estoque de 15 conexões com o banco (o padrão do
SQLAlchemy), e duas coisas o esgotavam:

1. Cada pergunta ao computador **segurava uma conexão enquanto esperava a
   resposta**, sem usar o banco nesse tempo.
2. Cada login segurava uma conexão enquanto conferia a senha.

Esgotado o estoque, a próxima consulta feita no laço principal — a batida de
um computador, por exemplo — esperava uma conexão até 30 s, e com ela **o
servidor inteiro parava**, inclusive a parte que recebe as respostas dos
computadores. As perguntas em espera nunca eram respondidas: um impasse.

A correção (`backend/app/db.py`):

- `liberar(db)`: os pedidos que perguntam algo ao computador devolvem a
  conexão logo depois de conferir dono e plano, antes de esperar.
- O estoque passou a ser maior que o número de pedidos atendidos em paralelo:
  no SQLite, sem limite; no PostgreSQL, 10 + 40.

O teste `tests/test_conexoes_do_banco.py` confere que, no meio da espera pelo
computador, nenhuma conexão está emprestada.

## Parte A: cada pergunta mais barata

Com o estoque corrigido, 160 celulares respondiam em 1,5 s com o servidor em
um terço do processador. O perfil mostrou o tempo indo em filas, não em
trabalho:

1. **Três consultas ao banco por pergunta** — usuário, sessão e dono do
   computador —, cada uma com troca de thread. Agora `app/vinculos.py` guarda
   as respostas na memória por ~60 s, e elas são apagadas sozinhas quando o
   banco muda um usuário, uma sessão ou um computador: trocar a senha, sair e
   desparear valem no pedido seguinte (`tests/test_vinculos.py`). As 21 rotas
   que só precisam disso usam `devices.dono_do_computador`, sem banco e sem
   thread; a batida dos computadores e a reconferência da tela também.
2. **Tudo vencendo junto.** O que entrava na memória no mesmo minuto vencia
   no mesmo instante, e centenas de idas ao banco travavam o servidor alguns
   segundos. O vencimento é sorteado entre 45 e 75 s.
3. **O coletor de lixo do Python.** Com 2.000 conexões, cada varredura
   completa parava tudo perto de um segundo. Na subida, `gc.freeze()` e
   varreduras mais raras (`main._acalmar_o_coletor`): p50 de 1,1 s para
   ~90 ms com 1.000 celulares.

## A retransmissão de vídeo (TURN), por conta

O coturn do VPS usa as portas **49160 a 49200**: 41 portas, e cada lado que
precisa de retransmissão ocupa uma. Na prática, **20 a 40 sessões
retransmitidas ao mesmo tempo**, no máximo.

O vídeo sai a até 1,5 Mbit/s (mais o som), e a retransmissão o recebe e o
reenvia: cerca de 1,6 Mbit/s entrando e 1,6 saindo por sessão. 20 sessões são
~32 Mbit/s em cada sentido — a rede do VPS só limita antes das portas se a
banda dele for menor que isso.

Quase todo celular em Wi-Fi alcança o computador direto; a retransmissão é
para redes móveis e corporativas mais fechadas.

## Resultados no VPS

Primeira rodada em 3 de novembro de 2026, com a E2.1.Micro. Foram só
computadores sem parear: no VPS não há contas de teste, então não houve
celulares. O simulador rodou num servidor do GitHub nos EUA, a ~145 ms do VPS,
e esses 145 ms aparecem em toda medida.

| Computadores | Entrada p50 / p95 | Batida p50 / p95 | `/health` p95 | Erros |
|---:|---:|---:|---:|---:|
| 50 | 2,2 / 2,5 s | 146 / 148 ms | 151 ms | 0 |
| 100 | 2,5 / 2,5 s | 144 / 147 ms | 150 ms | 0 |
| 250 | 3,9 / 6,0 s | 145 / 147 ms | 150 ms | 0 |
| 500 | 7,7 / 10,9 s | 144 / 149 ms | 151 ms | 0 |
| 1.000 | 11,9 / 20,8 s | 143 / 151 ms | 157 ms | 0 |
| 1.500 (só ~1.060 entraram) | 10,4 / 14,9 s | 210 / 403 ms | 604 ms | 3 (502 e quedas) |

- **Ligados e parados, 1.000 computadores cabem**: a batida fica no tempo da
  rede.
- **O que aperta é a entrada.** Cada conexão nova custa um aperto de mão TLS
  e um registro, e a máquina tem 1/8 de núcleo garantido. Pela tabela, a
  entrada anda a ~25 computadores por segundo. Depois de um reinício do
  servidor, 1.000 agentes levam perto de um minuto para voltar todos.
- **No degrau de 1.500 o servidor começou a ceder**: só 63 dos 500 novos
  entraram, o `/health` deu um 502 e duas conexões caíram.
- **~~O limite foi o processador.~~ Errado.** Os "~1.060 que entraram" eram o
  limite de **1.024 arquivos abertos** da API: cada conexão é um arquivo
  aberto, e o padrão do contêiner é 1.024. Descoberto em 14/11, na A1 (abaixo).
  O processador apertado era real, mas não era ele que barrava.

Celulares não foram medidos no VPS. Para eles continua valendo a estimativa
pela proporção com o teste local: 200 a 300 de tela aberta hoje, e 1.500 a
2.000 com a parte B.

## Resultados na A1 (14 e 15/11)

A A1 (VM.Standard.A1.Flex, 4 OCPU ARM, 23 GB) substituiu a E2.1.Micro em
14/11. A API continua um processo só, então usa **um** núcleo; o Caddy, que é
Go, usa os quatro. Cinco rodadas, só computadores sem parear, do GitHub nos
EUA (~115 a 145 ms de rede).

**Rodada 2 (um gerador, até 5.000 pedidos).** Saiu "sem erros", mas a batida
parou em ~6.000 por minuto de 1.000 em diante: o servidor nunca segurou mais
de ~1.000. O simulador não contava quem falhava na entrada. Agora conta: cada
degrau mostra os **ligados** e para se faltar mais de 1%. Reproduzido aqui:
com 1.024 arquivos abertos, a API para em 1.006 computadores e, nesse ponto,
**nem o próprio banco ela consegue abrir** (`unable to open database file`):
login e o resto falham juntos. Correção: `ulimits: nofile: 65536` na API.

**Rodada 3 (um gerador, limites novos):**

| Pedidos | Ligados | Entrada p50 / p95 | Batida p50 / p95 | `/health` p95 | Erros |
|---:|---:|---:|---:|---:|---:|
| 1.000 | 1.000 | 4,2 / 5,5 s | 143 / 144 ms | 145 ms | 0 |
| 2.500 | 2.500 | 5,7 / 8,3 s | 143 / 152 ms | 149 ms | 0 |
| 5.000 | 4.094 | 8,4 / 13,4 s | 144 / 160 ms | sem resposta | 908 |

Os 4.094 ficaram bem (batida 160 ms); as conexões **novas** é que morriam.
Não era a A1: a tabela de conexões da Oracle (métrica "Connection Tracking
Table Utilization" da VNIC) chegou a 5% e nunca encheu, e o `/health` interno
seguiu respondendo. Era o gerador: uma máquina do GitHub não abre muito mais
de 4.096 conexões para o mesmo destino. O workflow passou a usar até quatro
máquinas (`maquinas` no `vps.json`; os degraus são por máquina).

**Rodada 4 (quatro geradores, 2.000 / 5.000 / 8.000):** em ~4.000 ligados o
**Caddy foi morto por falta de memória** (512 MB; o `dmesg` mostra 484 MB em
uso) e todos os computadores caíram de uma vez. Voltaram sozinhos em
segundos. ~120 KB por conexão no Caddy. Correção: 2 GB e `GOMEMLIMIT`.

**Rodada 5 (quatro geradores, Caddy com 2 GB):** nada caiu.

| Pedidos (soma) | Ligados | Entrada p50 / p95 (pior máquina) | Batida p95 | Erros |
|---:|---:|---:|---:|---:|
| 2.000 | 2.000 | 14,7 / 19,5 s | 150 a 650 ms | 0 |
| 5.000 | 4.274 | 19,5 / 21,0 s | 770 a 990 ms | 726 (tempo esgotado na entrada) |
| 2.000 (uma máquina seguiu sozinha) | 2.000 | 4,3 / 7,1 s | 165 ms | 0 |

**Rodada 6 (quatro geradores, depois da correção abaixo: entrada em thread
e SQLite em WAL):**

| Pedidos (soma) | Ligados | Entrada p95 (por máquina) | Batida p95 (por máquina) | Erros |
|---:|---:|---:|---:|---:|
| 2.000 | 2.000 | 7,6 a 9,8 s | 118 a 182 ms | 0 |
| 5.000 | **5.000** | 11,5 a 18,9 s | 259 a 340 ms | 0 |
| 8.000 | **8.000** | 7,4 a 17,0 s | 197 a 332 ms | 0 |

As máquinas do GitHub estavam a 115, 145 e 180 ms da A1; a batida p50 de cada
uma ficou nesse valor, ou seja, o servidor respondeu quase na hora. Contra a
rodada 5, nenhuma conexão desistiu (eram 726 em 5.000) e a batida dos já
ligados caiu de ~900 para ~300 ms durante as entradas. A entrada continua
lenta (até ~19 s no p95), mas abaixo do prazo do simulador, e o teste não
achou o limite: parou em 8.000 porque era o último degrau pedido.

### O que as rodadas dizem

- **Ligados e parados, a A1 segura pelo menos 8.000 computadores** (rodada
  6) com a batida perto do tempo da rede. O limite não foi alcançado.
- **O que mais aperta é a velocidade de entrada.** Com quatro geradores entrando
  juntos (~200 por segundo), a fila na API passa de 20 s e conexões novas
  desistem. Com um gerador (~50 por segundo), a entrada fica em 4 a 8 s.
- **Por quê:** o `hello` do `/ws/agent` (`backend/app/main.py`, `agent_ws`)
  faz quatro a cinco consultas **síncronas** ao banco dentro do laço de
  eventos — `_autorizar_agente`, `_paired_email` (duas vezes) e, para quem
  não é pareado, um `create_pairing_request` que **grava**. O SQLite está no
  diário padrão (sem WAL), então cada gravação espera o disco da Oracle. Com
  o laço parado nisso, as batidas dos já ligados também atrasam (p95 de
  ~800 ms durante a entrada).
- **O teste exagera esse custo**: os computadores dele não são pareados e
  gravam um código de pareamento a cada entrada. Um computador de verdade
  reconectando só lê. Mas o momento em que todos entram juntos existe:
  depois de um reinício do servidor.

## O que mudaria a capacidade, se um dia precisar

- **Parte B (feita, falta publicar):** primeiro plano, programas abertos e
  métricas pelo canal direto (`agent/src/datachannel.rs`,
  `client/lib/services/video_session.dart`). Só vale para quem tiver o app
  e o agente novos; os outros continuam pelo servidor.
- **Menos memória por conexão**, quando a memória for o limite (com a parte
  B, é o primeiro): ~90 KB por WebSocket, boa parte buffers e objetos do
  Python por conexão.
- **Mais de um processo** exige antes mudar o registro de quem está
  conectado, que hoje vive na memória do processo — dois processos não se
  enxergariam.
- **Mais portas no coturn**, se a retransmissão encher.
- **Entrada mais barata: feita em 15/11** (`_entrada_do_agente` em
  `backend/app/main.py`, `_sqlite_em_wal` em `backend/app/db.py`). Medido
  aqui, com a API presa a um núcleo e 1.500 entrando juntos: p50 de 1,4 s
  para 0,3 s, p95 de 2,5 s para 0,7 s. Na A1, ver a rodada 6.
- **A entrada ainda é o próximo limite.** O que sobra nela é o aperto de mão
  TLS no Caddy e o trabalho da API num núcleo só. Se um dia milhares
  precisarem voltar juntos depois de um reinício, o próximo passo seria mais
  de um processo (que exige antes o registro de conectados fora da memória do
  processo, como dito acima).
