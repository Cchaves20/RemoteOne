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

| Celulares | Primeiro plano p50 | p95 | p99 | Pior | Erros |
|---:|---:|---:|---:|---:|---:|
| 250 | 4 ms | 17 ms | 26 ms | 112 ms | 0 |
| 500 | 9 ms | 235 ms | 320 ms | 343 ms | 0 |
| **1.000** | **91 ms** | **376 ms** | **473 ms** | **721 ms** | **0** |

Com 1.000 celulares e 1.000 computadores, o servidor atende os ~400 pedidos
por segundo que eles fazem, num núcleo só e sem nenhum erro. O que sobra de
tempo é quase todo da própria pilha web (uvicorn, Starlette, FastAPI) — o
código do Deskside quase não aparece no perfil. Daqui para mais, o caminho é
tirar essas perguntas do servidor (ver o fim).

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

(pendente: rodar com `scripts/carga/vps.json`)

## O que mudaria a capacidade, se um dia precisar

- **Parte B: tirar as perguntas do servidor.** Primeiro plano, programas
  abertos e métricas podem ir pelo canal direto que o celular já abre com o
  computador (o do mouse e do teclado). O servidor ficaria só com as
  conexões abertas — e 3.000 delas custam 35% de um núcleo. Exige uma versão
  nova do app.
- **Mais de um processo** exige antes mudar o registro de quem está
  conectado, que hoje vive na memória do processo — dois processos não se
  enxergariam.
- **Mais portas no coturn**, se a retransmissão encher.
