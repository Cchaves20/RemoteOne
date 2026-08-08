# Monitor do sistema e controle de mídia

Duas faixas retráteis na tela de controle: uma mostra como está o computador
(CPU, memória, disco), a outra comanda o que ele está tocando.

São **retráteis** por decisão de projeto. O que está em jogo naquela tela é a
imagem do computador; tudo o que fica permanentemente sobre ela come área útil.
Cada faixa tem o seu botão e só aparece quando alguém pede.

## Onde ficam

Os dois botões moram na **barra de cima**, ao lado da lupa: fora da imagem do
computador. Acesos quando o painel correspondente está aberto — é o que diz de
onde veio a faixa que apareceu.

As faixas **empurram a imagem** em vez de cobri-la, do mesmo jeito que o teclado
já fazia. Nada fica por cima da tela do computador, que é o que a pessoa veio
olhar. Fechada, a faixa não existe na árvore de widgets: não ocupa espaço nem
intercepta toque.

Onde cada faixa abre depende da orientação, porque o espaço barato é diferente:

| | Métricas | Mídia |
|---|---|---|
| Em pé | faixa sob a barra de cima | faixa acima do teclado |
| Deitado | coluna à esquerda da imagem | faixa sob a barra de cima |

Deitado a tela é baixa, e uma faixa horizontal de métricas comeria altura que
falta; a coluna lateral gasta largura, que sobra (a imagem é 16:9 e fica
encaixotada com margens nos lados). Em pé é o contrário.

A dock de aplicativos continua flutuando sobre a imagem — é o comportamento
esperado de uma dock, e ela é estreita o bastante para não atrapalhar.

## Monitor do sistema

O agente mede com o [`sysinfo`](https://crates.io/crates/sysinfo), que é
multiplataforma — diferente da captura de tela e da injeção de entrada, este
módulo não tem stub: o mesmo código roda no Windows, no Linux e no macOS.

O que aparece:

- **CPU** — uso somando todos os núcleos;
- **Memória** — usada / total;
- **Disco** — usado / total do disco do sistema (`C:` no Windows, `/` no resto);
- **GPU** — uso dos motores de renderização, com o nome da placa;
- **Temperatura** — o sensor mais quente;
- **Rede** — bytes por segundo entrando e saindo;
- **Bateria** — carga, e se está na tomada ou drenando;
- **Ligado há** — tempo desde que o computador iniciou.

As barras mudam de cor a partir de 70% (laranja) e 90% (vermelho). A cor é o que
se lê de longe, antes de ler o número.

### Ausente não é zero

GPU, temperatura e bateria **somem do painel** quando o computador não as tem —
não aparecem zeradas. A distinção não é cosmética: um desktop mostrando "Bateria
0%" parece um notebook prestes a desligar, e "GPU 0%" parece uma placa parada
quando na verdade não há placa dedicada nenhuma.

No fio isso é `null`, e os campos nem viajam quando ausentes (`skip_serializing_if`
no agente). Rede é a exceção que confirma a regra: toda máquina tem rede, então
zero ali é uma medida legítima de "nada passando agora" e o campo vai sempre.

Quem falta mais vezes é a **temperatura**. No Linux o `sysinfo` lê os sensores
direto; no Windows a leitura vem do WMI (`MSAcpi_ThermalZoneTemperature`), que
na maioria das máquinas exige driver do fabricante e simplesmente não responde.
A linha some, e isso é o comportamento correto — não há número honesto a mostrar.

### Por que a GPU sai de um processo separado

CPU, memória e disco saem de chamadas diretas do sistema e custam
microssegundos. GPU sai de uma consulta ao WMI, que abre um `powershell.exe` e
leva de meio segundo a dois — mais do que o intervalo entre dois pedidos do
painel.

Por isso a sonda é **assíncrona e preguiçosa**: a leitura devolve na hora o
último valor conhecido e, se ele estiver velho (mais de 5 s), dispara uma medição
nova em segundo plano para a próxima vez. Duas consequências assumidas: o
primeiro pedido depois de abrir o painel vem sem GPU (aparece no seguinte), e com
o painel fechado nenhum processo roda — o custo existe só enquanto alguém olha.

**A consulta usa classes do WMI, não `Get-Counter`.** Não é estilo: os nomes dos
contadores de desempenho são **traduzidos**, e `'\GPU Engine(*)\Utilization
Percentage'` não existe num Windows em português. Nome de classe do WMI
(`Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine`) é igual em qualquer
idioma. Pela mesma razão o número volta com vírgula decimal em português, e o
agente troca por ponto antes de converter.

Só os motores `engtype_3D` entram na soma: a lista traz um contador por motor
(cópia, decodificação de vídeo, computação), e somar todos passaria de 100%.

### A rede é uma taxa, e o agente entrega um acumulado

O `sysinfo` dá **bytes desde a leitura anterior**, não uma velocidade. O agente
divide pelo intervalo real medido, e não pelos 2 s que o app costuma usar — se um
pedido atrasa, o número continua honesto em vez de inflar.

A soma é de **todas as interfaces**, e isso é deliberado: escolher "a principal"
exige adivinhar, e num notebook com Wi-Fi, cabo, VPN e o adaptador virtual do
WSL qualquer critério erra em alguma máquina. A soma responde à pergunta que a
pessoa está de fato fazendo — "está passando tráfego?".

A formatação usa **base 1000**, ao contrário dos tamanhos de disco e memória, que
usam 1024. Não é inconsistência: velocidade de rede se conta em potências de dez
no mundo inteiro (é assim que o provedor vende e que o Windows mostra), enquanto
capacidade se conta em 1024. Usar a mesma base para os dois deixaria um dos
números errado.

### A bateria reaproveita o "manter pronto"

A carga vem do mesmo `GetSystemPowerStatus` que o "manter pronto" já consultava
para saber se o notebook está na tomada (ver [`pc-sempre-pronto.md`](pc-sempre-pronto.md)).
Uma segunda declaração da mesma estrutura do Windows noutro arquivo é o tipo de
duplicação que só se descobre errada no dia em que uma das duas muda.

O sufixo ("na bateria" / "na tomada") importa mais que o número: 68% drenando e
68% carregando são situações opostas para quem depende de o computador continuar
alcançável.

### O painel virou rolável

Com até oito medidas, a coluna não cabe mais na altura de um celular deitado. Sem
rolagem o Flutter resolveria isso com a faixa amarela de estouro por cima da
imagem do computador; com ela, nenhuma medida some e o painel continua ocupando
só o espaço que tem. Em pé há um teto de altura pelo mesmo motivo: oito medidas
não podem empurrar a tela do computador para um quarto do celular.

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
2. Toque no botão do monitor (ícone de chip, na barra de cima). Os quatro
   números aparecem e se atualizam de 2 em 2 s. Abra algo pesado no PC e veja a
   CPU subir.
3. Toque no botão de mídia (ícone de nota). Ponha uma música no PC e teste
   pausar, trocar de faixa e mudar o volume — sem colocar o player em foco.
4. Confira que a imagem do computador **encolhe** ao abrir uma faixa, em vez de
   ficar coberta por ela.
5. Gire o celular: as faixas mudam de lugar conforme a tabela acima.

Para conferir se o backend no VPS já tem isto:

```bash
curl.exe -s https://SEU-HOST/health
```

`features` precisa conter `system-stats` e `media-keys`.
