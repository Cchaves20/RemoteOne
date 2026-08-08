# Plano: versão 4.0 — automações, IA e outros sistemas

A 4.0 do documento do projeto tem três pedaços: **automações** (Etapa 17),
**integração com IA** (Etapa 18) e **suporte completo aos sistemas operacionais**.

Depois de planejar os três, **a IA saiu** — o motivo está na Fase 2, e ele não é
técnico: a conta de uso não fecha. Sobraram automações e sistemas operacionais.

Este documento decide a ordem, a arquitetura e o que fica de fora. O estado geral
do projeto e os cortes já feitos estão em
[`estado-do-projeto.md`](estado-do-projeto.md).

## A decisão que organizava tudo, e por que ela sobreviveu ao corte

**A saída da IA seria uma automação.**

Sem isso, os dois recursos seriam sistemas paralelos: um jeito de guardar uma
sequência de ações, e outro jeito de a IA executar ações. Dois formatos, duas
validações, dois lugares para um comando dar errado.

Com isso, viram um só. A automação é o **formato**; a pessoa é um produtor dele
(pelo editor) e a IA é o outro (traduzindo uma frase). Tudo o que for construído
para executar, validar, limitar e confirmar uma automação serve aos dois — e a
IA nasce sem poder nenhum que o editor já não tenha.

É também o que mantém a IA segura por construção: ela **escolhe de um cardápio
fechado**, não inventa comandos. Não há caminho pelo qual ela produza algo que um
usuário não pudesse ter montado à mão.

Consequência prática seria: **automações primeiro**. A IA sem elas seria
construir o formato duas vezes.

Esta parte continua valendo mesmo com a IA cortada, e por isso fica registrada: se
ela voltar um dia, é por aqui que entra. O que mudou foi o **papel** dela — de
quem executa para quem escreve. Ver a Fase 2.

## Fase 1 — Automações

Um botão que faz várias coisas. O exemplo do documento é o "Modo Trabalho": abrir
Outlook, Teams, navegador e Spotify.

### O que é um passo

Cada passo é **uma ação que o agente já sabe fazer**. Nada novo do lado dele:

`launch_app` · `close_app` · `input` (tecla, texto, atalho) · `media` ·
`brightness` · `power` · `keep_awake` · escolher monitor · escrever na área de
transferência.

Isso não é economia de esforço, é limite de projeto: o conjunto de coisas que uma
automação pode fazer é exatamente o conjunto que a pessoa já podia fazer com os
dedos. Nenhum poder novo entra pela porta da automação.

### Onde fica guardada: no servidor

Mesmo raciocínio dos perfis, e as duas razões continuam valendo:

- a conta é usada em mais de um aparelho — automação criada no iPhone tem de
  aparecer no iPad;
- o app instalado por sideload é reinstalado a cada sete dias, e o que estivesse
  só no aparelho iria embora junto.

### Onde é executada: no agente

Esta é a decisão menos óbvia, e a que mais importa.

O caminho fácil seria o app disparar os endpoints em sequência. Três problemas,
e o terceiro decide:

1. **Custo.** Uma automação de seis passos seriam seis idas e voltas
   `celular → VPS → agente`.
2. **Espera.** Um programa leva tempo para abrir antes de aceitar teclas. Quem
   espera teria de ser o telefone, contando o tempo do outro lado do mundo.
3. **O iOS suspende aplicativos.** Se a pessoa aperta o botão e bloqueia a tela,
   o app para no meio — e a automação fica pela metade, com o Outlook aberto e o
   resto não. Um "Modo Trabalho" que às vezes faz metade do trabalho é pior que
   não ter.

Então o backend manda **uma** mensagem com a lista de passos, e o agente executa
em ordem. Sobrevive ao telefone sair da frente, gasta uma ida e volta, e a espera
entre passos acontece onde ela faz sentido.

### As regras de execução

- **Espera por passo, opcional.** Abrir um programa e mandar `Ctrl+N` no mesmo
  instante não funciona: o programa ainda não existe para receber a tecla.
- **Falha não interrompe.** Se o Teams não está instalado, os outros três ainda
  devem abrir. Mas o resultado de **cada** passo volta ao app — falhar em
  silêncio é o que este projeto já corrigiu meia dúzia de vezes.
- **Teto de passos e de duração total.** A lista chega pela rede; ela não pode
  prender o agente para sempre nem virar um laço de mil aberturas de programa.
- **Passos destrutivos confirmam antes.** Desligar e fechar programa entram na
  automação, mas com aviso no app antes de rodar. Aqui é cuidado; se a IA um dia
  escrever automações, vira requisito.

### Onde aparece no app: na tela de perfis

A tela de perfis já era uma pré-automação, e é por isso que as duas moram juntas.

Compare o que se preenche em cada uma:

| Perfil personalizado (hoje) | Automação |
|---|---|
| ícone | ícone |
| nome | nome |
| **lista de programas** | **lista de passos** |
| em quais computadores vale | em qual computador roda |

É a mesma tela, o mesmo gesto e o mesmo lugar na cabeça de quem usa: *"coisas que
eu montei para o meu jeito de trabalhar"*. Uma tela separada nas configurações
obrigaria a pessoa a saber, antes de procurar, em qual das duas gavetas o que ela
quer foi guardado — e a diferença entre as duas é sutil demais para isso.

Então: **a tela de perfis vira a tela dos dois**, com duas seções.

### Mas continuam sendo dois objetos, e não um

Juntar na mesma tela é certo; juntar no mesmo objeto, não. A diferença aparece no
editor, e é uma só:

**Num perfil a ordem não significa nada** — são botões lado a lado, e você toca
no que quiser. **Numa automação a ordem é o recurso inteiro**, com espera entre
os passos.

Um editor que servisse aos dois teria de explicar essa diferença antes de servir
para alguma coisa, e todo perfil passaria a carregar uma sequência que talvez não
queira ter. Duas seções na mesma tela, dois editores parecidos: a pessoa vê a
semelhança sem precisar entender a distinção.

### Antes de tudo isso: "abrir todos", e depois "montar o ambiente"

Um perfil personalizado já guarda "Outlook, Teams, navegador, Spotify". Um botão
**"abrir todos"** nesse perfil entrega o "Modo Trabalho" do documento sem
nenhuma automação existir — sem modelo novo, sem editor novo, sem protocolo novo.

Vale fazer isso **primeiro**, e não por economia: é um teste barato da hipótese
inteira. Se abrir todos resolver o que você queria, a automação passa a valer só
pelo que ela acrescenta de verdade — ordem, espera e passos que não são
programas (brilho, mídia, teclas, energia). Pode ser que seja bem menos recurso
do que parece agora, e é melhor descobrir isso com um botão do que com um editor
pronto.

## Posicionar as janelas: o que faz "abrir todos" valer a pena

Abrir quatro programas empilhados um sobre o outro não é um "Modo Trabalho" — é
a mesma bagunça em quatro toques a menos. O que transforma isso em ambiente
montado é **cada programa abrir no lugar certo**.

A ideia são os layouts do Windows 11 (metades, três colunas, 2×2, 2/3+1/3), e a
escolha é feita duas vezes:

1. **O perfil escolhe o layout** — a grade, uma vez.
2. **Cada programa da lista escolhe a sua zona** dentro dela. Navegador à
   esquerda, terminal à direita.

O atributo é do **programa dentro do perfil**, e não de um passo de automação.
Isso importa: o perfil já tem a lista de programas, então a zona é uma coluna a
mais numa estrutura que existe — e o "abrir todos" passa a montar o ambiente sem
que nenhum objeto de automação precise existir.

### Como o agente posiciona

Não há API pública para *invocar* o menu de layouts do Windows 11. Mas há o que
está por trás dele: `SetWindowPos`, que põe uma janela em qualquer retângulo. É o
que o FancyZones do PowerToys faz.

O agente já tem metade da máquina: `gui.rs` usa `FindWindowExW`,
`GetWindowThreadProcessId` e `ShowWindow` para achar e mostrar a própria janela.
É a mesma família de chamadas, sem permissão especial — processos do mesmo
usuário podem posicionar as janelas uns dos outros.

O retângulo sai da **área de trabalho** do monitor (`SPI_GETWORKAREA`), não da
resolução: senão a janela de baixo fica atrás da barra de tarefas.

### O que **não** é o caminho: os atalhos de encaixe

Mandar `Win+Esquerda` depois de abrir seria mais fácil — o agente já sabe, e o
perfil Sistema até tem esse botão. Resolve mal:

- só faz metades e quartos, nada das três colunas ou do 2/3+1/3;
- age sobre a **janela em foco**, e logo depois de abrir um programa o foco é a
  coisa mais imprevisível que existe;
- meio segundo de atraso na abertura e o atalho encaixa a janela errada.

Trocar empilhamento por "às vezes encaixa a janela errada" não é progresso.

### A parte difícil não é posicionar, é achar a janela

Posicionar é uma chamada. Descobrir **qual** janela pertence ao programa que
acabou de ser aberto é onde mora o trabalho:

- o programa mostra uma tela de carregamento antes da janela de verdade;
- o processo lançado termina e quem abre a janela é outro — navegadores, Office,
  qualquer coisa em Electron;
- a janela pode aparecer três segundos depois, e até lá não há o que mover.

O caminho: depois de lançar, o agente observa por alguns segundos até aparecer
uma janela nova, visível, de nível superior, cujo processo corresponda — e só
então posiciona. Com tempo limite, e **falhando de forma explícita** ("abriu, mas
não consegui posicionar") em vez de em silêncio.

### As regras que faltam decidir cedo

- **Sem zona escolhida, abre como abre hoje.** Posicionar é opcional por
  programa; um perfil pode ter três posicionados e um solto.
- **Duas janelas na mesma zona é permitido.** Duas janelas de navegador lado a
  lado num quadrante é uso legítimo, e inventar uma regra que proíbe isso
  atrapalharia mais do que ajudaria.
- **A ordem da lista decide o foco.** O último a ser posicionado fica por cima e
  em foco. É o único sentido em que a ordem importa num perfil — e vale
  registrar, porque contradiz em parte o argumento de que num perfil a ordem não
  significa nada. Ela não significa para quem toca botão a botão; significa para
  quem toca "abrir todos".
- **O monitor é do perfil.** Numa máquina com duas telas, o layout precisa saber
  em qual delas se aplica. Padrão: a principal.

### O que vai resistir

Vale escrever antes de virar surpresa: janelas com tamanho mínimo maior que a
zona não encolhem, e alguns aplicativos da Microsoft Store ignoram o
reposicionamento. Outlook, Teams, navegadores e VS Code obedecem — que é a maior
parte do que interessa aqui.

### Como fica verificado

Aqui não há Flutter nem Windows, então a verificação se concentra onde ela é
possível e vale mais:

- **Agente:** a execução da lista é lógica portável — ordem, espera, falha que
  não interrompe, teto de passos, relatório por passo. Tudo testável no Linux.
- **Backend:** modelo, validação (passo desconhecido é recusado antes de chegar
  ao computador), posse (automação de outra conta é 404) e o repasse.
- **App:** editor e lista, sem compilar aqui — o que dá para testar é o modelo.

## Fase 2 — Integração com IA — **cortada**

"Abra o Photoshop e coloque uma música." O sistema interpreta, converte em passos
e executa.

O plano estava inteiro escrito — modelo na nuvem chamado pelo backend, cardápio
fechado de ações, plano mostrado antes de rodar, opt-in de privacidade. Nada
disso era o problema. **A conta de uso é que não fecha.**

### A conta

Automação existe para o que se faz **de novo**. E para o repetido:

| | Automação | IA |
|---|---|---|
| Toques | 1 | abrir o campo, digitar a frase, confirmar o plano |
| Espera | nenhuma | 2 a 5 segundos pelo modelo |
| Custo | zero | dinheiro por frase |
| Acerta | sempre | quase sempre |

Não há cenário em que digitar "abre o Outlook, o Teams e o Spotify" ganhe de um
botão que já faz isso. E se a coisa é rara o bastante para não valer um botão,
costuma ser rara o bastante para se fazer à mão.

Como executor de comandos, a IA aqui seria enfeite: impressiona numa
demonstração, é usada duas vezes por curiosidade, e continua custando por chamada
enquanto é a maior superfície de risco do produto — a única parte que decide
sozinha o que fazer no computador de alguém.

Vale registrar de onde vinha a pressão: o documento do projeto foi escrito quando
"integração com IA" era item obrigatório em toda lista de recursos. Isso é
contexto, não argumento.

### A porta que fica aberta: a IA que **escreve** a automação

Se ela voltar, volta com outro papel. Em vez de executar, ela monta o rascunho:
"quero um botão que prepare o computador para uma reunião" → ela propõe os passos
→ a pessoa ajusta e salva. Dali em diante é um toque, para sempre.

Isso inverte a economia inteira:

- **O custo é pago uma vez, na criação**, e não a cada uso.
- **A lentidão deixa de importar** — quem está montando não está com pressa.
- **O erro deixa de ser perigoso**: é um rascunho revisado antes de salvar, não
  um comando disparado.
- E resolve o problema real do editor, que é a **página em branco**. Boa parte das
  pessoas não abre um editor e monta uma sequência do zero, mas descreve o que
  quer sem dificuldade.

Nessa forma a IA vira a porta de entrada do recurso que importa, em vez de
concorrer com ele.

**Quando decidir:** depois de as automações estarem no ar e em uso. Se a página
em branco não incomodar ninguém, ela não precisa voltar.

## Fase 3 — Suporte completo aos sistemas operacionais

O agente compila em Linux e macOS hoje, e a lógica portável é testada nos três.
O que falta é a camada de plataforma inteira: captura, injeção de entrada,
aplicativos, área de transferência, arquivos, energia e "manter pronto" — hoje
todos *stub* fora do Windows.

É o maior dos três pedaços e o menos verificável daqui. Três realidades
diferentes:

### Linux — viável, com uma ressalva grande

X11 tem caminho conhecido para tudo. **Wayland não**: a captura de tela exige
PipeWire e o portal do ambiente gráfico, com **consentimento do usuário por
sessão**. Isso briga de frente com a premissa do produto — um agente que sobe
sozinho e fica disponível não pode depender de alguém clicar "permitir" a cada
reinício.

Não é impossível, é uma decisão de produto: em Wayland, ou o recurso pede
permissão uma vez por sessão e avisa, ou a captura fica de fora e sobra o resto
(entrada, arquivos, energia, monitoramento).

Dá para testar aqui, numa máquina virtual com sessão gráfica. É por onde começar.

### macOS — depende de hardware que o projeto não tem

Precisa de duas permissões que o usuário concede uma a uma (Acessibilidade e
Gravação de Tela) e de notarização para distribuir fora da App Store. E não há
Mac no projeto — o Codemagic compila, mas compilar não é testar.

Só faz sentido atacar com uma máquina emprestada ou comprada. Antes disso,
qualquer entrega seria fé.

### ChromeOS — rever se entra

Um agente em ChromeOS roda dentro do contêiner Linux (Crostini), que **não
controla a área de trabalho do ChromeOS** — só o próprio contêiner. Entregar isso
como "suporte a ChromeOS" seria prometer o que o nome sugere e entregar outra
coisa.

Recomendação: tirar do escopo, ou redefinir explicitamente como "o contêiner
Linux", que é o que de fato dá para fazer.

## A ordem, e por quê

1. **Automações.** Útil sozinha, reaproveita tudo o que existe, e é a parte
   inteiramente verificável daqui.
2. **Sistemas operacionais.** Maior, mais incerto, e o único que depende de
   comprar ou emprestar hardware.

A IA saiu do meio. Se voltar, entra depois das automações estarem em uso — nunca
antes, porque a pergunta que decide se ela vale a pena ("a página em branco
incomoda?") só tem resposta com o editor no ar.

## O que não está aqui, e continua na frente

A 4.0 é sobre o produto. O que separa o Deskside de poder ser **vendido** está em
[`estado-do-projeto.md`](estado-do-projeto.md) e não mudou: backup do banco,
limite de tentativas no login, App Store, cobrança, termos de uso.

O backup em particular é o único item de qualquer lista que pode custar tudo de
uma vez, e leva meia hora.
