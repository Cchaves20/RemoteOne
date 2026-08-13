# Perfis de controle

A barra que flutua na borda da tela de controle. Cada perfil é um jeito de usar
o computador, e traz os botões que servem àquele jeito.

## Dois tipos, e por que eles são diferentes

**Os cinco de fábrica** (Sistema, Vídeo, Navegador, Trabalho, Slides) mandam
**teclas**: `Ctrl+S`, `F5`, seta para a direita. Vivem no código do app, e não
no banco, porque é isso que eles são — nomes de tecla, com o cuidado de escolher
a forma certa (`key_press` para tecla com nome próprio, texto digitado para uma
letra solta, combinação quando há modificador). Não há o que editar neles sem
virar um editor de atalhos, que é outro recurso.

**Os seus** abrem **programas**. Você escolhe o nome, o ícone, quais programas e
em quais computadores; cada programa vira um botão. Ficam no servidor.

**E há uma terceira natureza, com dois botões só:** o brilho da tela, no perfil
Sistema. Não é tecla nem programa — vai por um endpoint próprio
(`POST /devices/{id}/brightness`) e por isso `ProfileAction.input` não significa
nada para ele. É esse detalhe que faz a barra ter três caminhos a partir do
mesmo toque, e confundi-los mandaria um `input` sem tecla nenhuma ao computador.

## Abrir todos

Um perfil com dois ou mais programas ganha, sozinho, um botão a mais **na
frente** dos outros: abre todos de uma vez.

O botão é **derivado**, não guardado — não vem do servidor e não aparece no
editor. Com um programa só ele não aparece: seria o mesmo botão duas vezes,
ocupando espaço numa barra que fica em cima da tela do computador.

### A lista vai numa mensagem só

O caminho fácil seria o app chamar `/apps/launch` uma vez por programa. Três
problemas, e o terceiro decide:

1. Quatro programas seriam quatro idas e voltas `celular → servidor → agente`.
2. A espera entre uma abertura e a seguinte teria de ser contada do outro lado
   do mundo.
3. **O iOS suspende aplicativos.** Quem aperta o botão e bloqueia a tela veria a
   lista parar no meio, com o primeiro programa aberto e o resto não. Um "Modo
   Trabalho" que às vezes faz metade do trabalho é pior que não ter.

Então o app manda `POST /devices/{id}/apps/launch-many` com a lista inteira, e
quem executa em ordem é o agente. O telefone pode sair da frente no instante
seguinte ao toque.

### Uma falha não interrompe as outras

Se o Teams não está instalado naquele computador, os outros três ainda abrem —
quem pediu o ambiente montado não pediu uma verificação de integridade.

Mas o resultado de **cada** programa volta, com o identificador que foi pedido, e
o app diz *qual* não abriu: "3 de 4 abertos. Não abriu: Teams". Um "algo falhou"
mandaria a pessoa conferir os quatro para descobrir qual.

O aviso de sucesso existe pela mesma razão do brilho: o efeito acontece **no
computador**, e de longe não se vê nada. Sem ele, um toque que funcionou e um que
não fez nada seriam idênticos.

### O intervalo de 400 ms entre um e outro

Não é medo. Abrir quatro programas pesados no mesmo instante faz os quatro
demorarem mais, e o Windows empilha as janelas numa ordem que depende de quem
terminou de carregar primeiro. Com o intervalo, **o último da lista fica por
cima** — e é a única forma de a ordem do perfil significar alguma coisa.

Vale registrar que isso contraria em parte o que se diz acima sobre os perfis: a
ordem não importa para quem toca botão a botão, mas importa para quem toca
"abrir todos".

## O ambiente montado: cada janela no seu lugar

Abrir quatro programas empilhados um sobre o outro não era um ambiente montado —
era a mesma bagunça em três toques a menos. O que fecha o recurso é cada
programa abrir **no lugar certo**.

A escolha é feita **duas vezes**, e as duas ficam no editor do perfil:

1. **O perfil escolhe o layout** — a grade, uma vez. São os cinco desenhos do
   menu de encaixe do Windows 11: metades, 2/3+1/3, três colunas, quadrantes, e
   uma principal com duas empilhadas.
2. **Cada programa escolhe a sua zona** dentro dela. Navegador à esquerda,
   terminal à direita.

### Células, e não frações

Uma zona é `{cols, rows, col, row, colspan, rowspan}`: em que grade, e qual
célula.

Frações pareceriam mais simples e estariam erradas. Três colunas seriam 0,333
cada, e três vezes 0,333 não fecha 1 — sobraria uma fresta de um ou dois pixels
entre as janelas, ou elas se sobreporiam. Com a grade, a borda direita de uma
zona sai da **mesma conta** que a borda esquerda da seguinte, e o encaixe é
exato por construção, em qualquer resolução.

### Quem sabe o quê

- **O app** tem o catálogo de layouts, porque é ele que desenha o seletor.
- **O backend** valida a célula contra a grade que ela declara, e nada mais.
- **O agente** transforma célula em pixels e não conhece layout nenhum.

Uma cópia do catálogo no agente seria uma segunda fonte de verdade para a mesma
coisa. E é por isso que a grade viaja **dentro** de cada zona: assim o layout
escolhido é dedutível do que está guardado, sem um campo à parte que pudesse
discordar das zonas.

### Onde isso fica guardado

Nos programas do perfil, que já eram um JSON no banco. **Não há coluna nova** —
num projeto sem Alembic, evitar uma migração é evitar um remendo à mão em
`db.py`.

### Como o agente posiciona

`SetWindowPos`, na área de trabalho do monitor — não na resolução, senão a
janela de baixo fica atrás da barra de tarefas. É o mesmo caminho do FancyZones,
do PowerToys; não existe API pública para *invocar* o menu de layouts do
Windows.

Antes de mover, restaura a janela se ela estiver maximizada: uma janela
maximizada ignora o tamanho pedido e volta a ocupar a tela inteira no próximo
desenho. É a diferença entre "não funcionou" e "funcionou em alguns programas".

E não mexe na ordem de empilhamento nem no foco: quem decide quem fica por cima
é a ordem de abertura.

### A parte difícil é achar a janela

Posicionar é uma chamada. Descobrir **qual** janela pertence ao programa que
acabou de abrir é onde mora o trabalho:

- o programa mostra uma tela de carregamento antes da janela de verdade;
- o processo lançado termina e quem abre a janela é outro — navegadores, Office,
  qualquer coisa em Electron;
- a janela pode aparecer três segundos depois, e até lá não há o que mover.

A saída é **não depender do processo**: o agente fotografa quais janelas existem
antes de abrir e espera aparecer uma nova (até cinco segundos, olhando a cada
150 ms). A pergunta deixa de ser "de quem é esta janela" e passa a ser "qual
janela não existia agora há pouco" — o que funciona igual nos três casos acima.

Três filtros descartam o que não é janela de programa: invisível (toda aplicação
tem janelas internas), sem título, e "tool window" (paletas, dicas, bandeja).

### Abriu mas não posicionou não é falha

É o **terceiro** desfecho, e por isso o agente tem três e não dois. O programa
está lá; a tela é que não ficou como a pessoa montou. Dizer que falhou seria
mentira com o programa à vista, e ficar calado deixaria o layout errado sem
explicação. O app diz "Abriu tudo. Não consegui posicionar: Teams".

### O que vai resistir

Janelas com tamanho mínimo maior que a zona não encolhem, e alguns aplicativos
da Microsoft Store ignoram o reposicionamento. Outlook, Teams, navegadores e VS
Code obedecem — que é a maior parte do que interessa aqui.

### O que ainda não tem

**Escolher o monitor.** Hoje o encaixe usa sempre a tela principal. Numa máquina
com duas telas, o layout se aplica àquela — e o plano previa a escolha ser do
perfil. Fica para quando houver uma segunda tela para testar.

## Brilho

O documento do projeto pede volume **e** brilho no "controle de recursos do
sistema". O volume já morava na faixa de mídia; o brilho veio para a barra de
perfis, que é a área de atalhos — e brilho é exatamente isso: um ajuste de um
toque, no meio de outra coisa.

**Passos de 10%, não um controle deslizante.** Um deslizante não caberia numa
barra de ícones de 42 px, e cada arrasto viraria dezenas de pedidos ao
computador. Cinco toques atravessam a faixa inteira.

**O passo é somado no computador, não no telefone.** Fazer o app ler, somar e
escrever custaria duas idas e voltas por toque — e dois toques rápidos se
atropelariam, porque os dois leriam o mesmo valor antigo e o segundo desfaria o
primeiro. O agente recebe `delta` e resolve lá.

**O piso é 5%, não 0.** Um notebook com o brilho no zero parece desligado, e
quem está do outro lado de um controle remoto não tem como perceber que o que
aconteceu foi um toque a mais no botão de diminuir.

**Tem resposta, ao contrário das teclas de mídia.** Volume mexe no sistema e
funciona em qualquer máquina; brilho por software só alcança o **painel
embutido de um notebook**. Monitor externo se ajusta por DDC/CI, pelo cabo, e
muitos fabricantes não implementam — este agente não tenta esse caminho. Então
num computador de mesa o pedido é recusado com a explicação, que sobe como
`detail` de um 409 e aparece no aviso do app. Sem isso o toque simplesmente não
faria nada: o pior tipo de falha, a que não deixa rastro.

O aviso de sucesso ("Brilho: 60%") também não é enfeite — a tela que muda é a do
computador, do outro lado, e quem está olhando o celular não veria diferença
nenhuma entre um toque que funcionou e um que não fez nada.

## Por que no servidor

Duas razões concretas, e as duas doem se ignoradas:

- A conta é usada em mais de um aparelho. Perfil criado no iPhone tem de
  aparecer no iPad.
- O app instalado por sideload é **reinstalado com frequência** — a assinatura
  de um Apple ID grátis dura sete dias. Perfil guardado só no aparelho iria
  embora junto.

## O programa que muda de lugar

Um perfil atribuído a dois computadores esbarra num detalhe do Windows: o mesmo
programa mora em caminhos diferentes em cada máquina. O Spotify de um usuário
está em `AppData\Roaming`; o de outro, em `Program Files`.

Por isso cada programa guarda **nome e caminho**. Ao abrir:

1. O caminho existe → abre direto.
2. Não existe → o agente procura um atalho com aquele nome no menu Iniciar (o
   do usuário e o do sistema).
3. Nem isso → entrega o texto ao `start`, que ainda resolve nomes do PATH
   (`notepad`, `calc`).

Guardar só o caminho faria o perfil funcionar apenas no computador onde nasceu.
Guardar só o nome perderia o caso comum, em que o caminho está certo e a busca
é desperdício.

## A ordem

Você arrasta a barra inteira, de fábrica e seus misturados — porque a barra é
uma só. O servidor guarda a fila de identificadores como ela veio.

O que a fila **não** menciona vai para o fim, na ordem natural. É o que faz um
perfil criado noutro aparelho, ou um perfil de fábrica trazido por uma versão
nova do app, aparecer em vez de sumir por não constar de uma lista salva antes
de ele existir.

## Automações

Um perfil é um punhado de botões: você toca no que quiser, e a ordem entre eles
não significa nada. Uma **automação** é o passo seguinte da mesma ideia — uma
sequência que um toque só executa, em ordem, com espera entre os passos.

Dois exemplos, que foram os que motivaram o recurso:

| Modo reunião | Fim do expediente |
|---|---|
| abrir o Teams à esquerda | **fechar tudo** |
| abrir o OneNote à direita | brilho no mínimo |
| silenciar | suspender |
| brilho em 80% | |

### "Fechar tudo", e por que ele não tem campo nenhum

O "fim do expediente" nasceu como uma lista: fechar o Slack, fechar o Outlook,
fechar o navegador. E envelheceu na semana seguinte, porque **o que está aberto
hoje não é o que estava ontem** — entrou um PDF, entrou o Excel de um colega,
entrou o terminal. A lista escrita à mão só acerta no dia em que foi escrita.

O passo `close_all` pergunta ao computador o que está aberto na hora de rodar.
Por isso ele não tem parâmetro: não há o que escolher, e escolher é justamente
o que dá errado.

"Aberto" tem uma definição precisa: **processo com janela visível**. Serviço de
sistema e tarefa de fundo não são o que a pessoa vê na barra de tarefas, e
encerrá-los seria estragar a máquina para cumprir o pedido ao pé da letra.

Três decisões dentro dele:

- **O agente se exclui.** Ele tem janela e apareceria na própria lista; fechar-se
  no meio da automação mataria a sessão e os passos seguintes junto. O nome vem
  do executável, não escrito à mão — quem renomeia o binário não pode fazer o
  agente se suicidar por causa disso.
- **O Explorer fica de fora**, porque é a barra de tarefas e a área de trabalho.
- **Sem `/F`.** O programa recebe o pedido de fechar e pergunta sobre o que não
  foi salvo. Uma automação que roda sozinha, de madrugada, não pode descartar o
  trabalho de ninguém. Programa que recusa não interrompe os outros: o relatório
  diz quantos aceitaram.

Não pede confirmação no app, ao contrário do que se poderia esperar de um passo
tão destrutivo. Quem monta uma automação chamada "fim do expediente" quer que
ela rode sozinha — um diálogo derrotaria o propósito. O aviso continua onde
serve: o passo é marcado como destrutivo, e é isso que o app usa para avisar
**antes de rodar a automação inteira**.

Quem quiser exceções ("fecha tudo menos o Spotify") põe o `close_all` primeiro e
um `launch` depois. Uma lista de exceções teria o mesmo problema de envelhecer
que a lista original.

Elas aparecem em dois lugares, e cada um tem um papel: **na barra da tela de
controle** é onde se roda (ver abaixo), e **em Configurações → Perfis** é onde
se monta.

### Onde se monta: na tela de perfis, e não numa gaveta própria

A tela de perfis já era uma pré-automatização. Compare o que se preenche:

| Perfil | Automação |
|---|---|
| ícone | ícone |
| nome | nome |
| **lista de programas** | **lista de passos** |
| em quais computadores vale | em qual computador roda |

É o mesmo gesto e o mesmo lugar na cabeça de quem usa: *coisas que eu montei
para o meu jeito de trabalhar*. Uma tela separada obrigaria a pessoa a saber,
antes de procurar, em qual das duas gavetas o que ela quer foi guardado — e a
diferença entre as duas é sutil demais para isso.

**Mas continuam dois objetos**, e não um. Num perfil a ordem é indiferente; numa
automação ela é o recurso inteiro. Um editor que servisse aos dois teria de
explicar essa diferença antes de servir para alguma coisa, e todo perfil passaria
a carregar uma sequência que talvez não queira ter.

### O que um passo pode ser

Abrir um programa (com zona, como no "abrir todos") · fechar um programa · um
atalho de teclado · uma tecla de mídia · o brilho · energia.

Isso não é economia de esforço, é limite de projeto: **o conjunto do que uma
automação pode fazer é exatamente o conjunto do que a pessoa já podia fazer
tocando nos botões.** Nenhum poder novo entra pela porta da automação — e cada
passo herda um comportamento já testado e explicado em outro lugar.

Os atalhos de teclado oferecidos são os dos perfis de fábrica, e por um motivo
concreto: cada um já vem com o formato certo resolvido (tecla com nome próprio,
letra solta ou combinação). Um campo livre de "escreva o atalho" deixaria montar
combinações que o computador não sabe receber, e a falha só apareceria na hora
de rodar.

### A sequência inteira vai numa mensagem só

A mesma decisão do "abrir todos", pelo mesmo motivo decisivo: **o iOS suspende
aplicativos**. Se o telefone conduzisse passo a passo, bastaria bloquear a tela
para a rotina parar no meio — com o Teams aberto, o som ainda alto e o brilho
como estava. Uma automação que às vezes faz metade é pior que não ter.

Então o backend manda uma mensagem com a lista, e o agente executa em ordem.

### A espera é depois do passo, e tem teto

Abrir um programa e mandar um atalho no instante seguinte não funciona: o
programa ainda não existe para receber a tecla. Por isso cada passo carrega
quanto esperar **depois** dele — 1,5 s por padrão nos que abrem programa, nada
nos demais.

Três tetos, e nenhum é decoração — a lista chega pela rede, e não pode prender o
agente para sempre:

| | |
|---|---|
| Passos por automação | 24 |
| Espera de um passo | 10 s |
| Espera somada | 60 s |

A espera nunca acontece depois do último passo: seria o agente dormindo à toa
com a automação já terminada.

### Uma falha não interrompe as seguintes

Se o Slack não estava aberto para ser fechado, o brilho ainda baixa e a máquina
ainda suspende. Quem pediu "fim do expediente" quer o expediente encerrado, não
uma verificação de integridade.

Mas o resultado de **cada** passo volta, identificado pelo **índice** e não pelo
nome: dois passos podem ser idênticos ("baixar o volume" duas vezes), e dizer só
"baixar o volume falhou" não diria qual dos dois. O app mostra quantos passos
rodaram e, tocando em *Resultado*, quais falharam e por quê.

Um aviso volta com o passo tendo dado certo — "a janela abriu, mas não foi para
o lugar pedido". Aviso não é falha, e esconder não ajudaria: a pessoa vê o Teams
no meio da tela e precisa saber que aquilo era o esperado.

### Fechar programa é gentil, e é por isso que confirma

O agente pede ao programa que feche, como o X da janela — sem `/F`. Uma
automação roda sem ninguém olhando, e matar o processo descartaria em silêncio o
que não foi salvo. Se houver algo pendente, o programa pergunta e continua
aberto: o passo "falha", e essa é a resposta certa.

**Passos destrutivos confirmam antes de rodar** — fechar programa e mexer na
energia. Só eles: pedir confirmação em toda automação faria um recurso de um
toque custar dois, que é o oposto do que ele existe para fazer.

### Onde se roda: na barra, com o computador à vista

O editor mora em Configurações, mas **rodar uma automação não pode morar lá**.
"Modo reunião" é uma coisa que se faz olhando para o computador, no meio de
outra coisa — e sair da tela de controle, entrar nas configurações, achar a
automação e voltar já custou mais do que abrir os programas à mão.

Então a barra de perfis ganhou **mais um grupo**, no fim da fila: um botão de
automações que abre a segunda pista com uma automação por botão. A gramática da
barra já era essa — escolha um grupo, veja os botões dele —, e uma automação é
exatamente um botão.

Duas regras que caem disso:

- **A segunda pista é uma só.** Abrir as automações fecha o perfil aceso e
  vice-versa. Mostrar as duas coisas ao mesmo tempo faria a barra cobrir a tela
  do computador, que é o que ela existe para não fazer.
- **Só aparecem as automações desta máquina.** As fixadas noutra ficam de fora:
  um botão que age num computador que não está à vista é pior que botão nenhum,
  porque nada do que a pessoa está vendo mudaria e não haveria como saber por
  quê.

Sem automação nenhuma na conta, o grupo não aparece — um botão que abre uma
pista vazia não leva a lugar nenhum.

### Em qual computador

Uma automação pode fixar a máquina ou perguntar na hora. Fixar é singular, ao
contrário do perfil (que aceita vários): um perfil é um punhado de atalhos que
vale em qualquer Windows, mas uma automação abre programas *daquele* computador
e pode terminar suspendendo *aquela* máquina.

Quando ela fixou uma, o parâmetro da URL não a desvia — quem fixou, fixou por um
motivo.

### Endpoints

| Método | Rota | O que faz |
|---|---|---|
| `GET` | `/api/v1/automations` | As automações da conta |
| `POST` | `/api/v1/automations` | Cria (o servidor gera o `id`) |
| `PUT` | `/api/v1/automations/{id}` | Substitui o conteúdo; o `id` continua |
| `DELETE` | `/api/v1/automations/{id}` | Apaga |
| `POST` | `/api/v1/automations/{id}/run` | Executa e devolve o relatório |

O `run` aceita `?device_id=` para quando a automação não fixou um computador, e
recusa com 409 uma automação sem passos: o relatório seria uma lista vazia, e
lista vazia é indistinguível de "rodou tudo e nada deu errado".

Um passo sem o campo obrigatório do próprio tipo é recusado com 422 **no
telefone**, e não no computador — um `launch` sem caminho falharia lá, longe de
quem montou a automação, com uma mensagem sobre um programa vazio em vez de
"faltou escolher o programa". Os nomes dos comandos de mídia e de energia também
são conferidos aqui: `sleep` é o nome corrente em inglês e o agente chama de
`suspend`, e sem essa conferência o passo só falharia na última linha da
sequência.

### Limites

| | |
|---|---|
| Automações por conta | 30 |
| Passos por automação | 24 |
| Tamanho do nome | 60 caracteres |

## A dock diz o que está aberto

A dock flutuante mostra os atalhos da área de trabalho. Ela passou a mostrar
também **o que está aberto agora**, de dois jeitos:

- **Anel branco** em volta do ícone dos atalhos cujo programa está rodando.
- **Os abertos sem atalho** — o terminal é o caso típico — entram no fim da
  fileira.

### Por que os avulsos não são botões

Eles entram levemente apagados e **não respondem ao toque**. Não é descuido: não
existe ainda uma ação de "trazer a janela para frente" no agente, e um botão que
não faz nada ensina a desconfiar dos que fazem. Enquanto isso eles são
informação — e o texto ao segurar diz exatamente isso, para o ícone mudo não
parecer defeito.

Ficam **no fim**, depois dos atalhos, e não intercalados: a ordem que a pessoa
montou na área de trabalho é estável, e o que está aberto muda o tempo todo.
Misturar faria os ícones dançarem de lugar a cada dez segundos.

### O casamento entre atalho e processo

O atalho chega como `Spotify.lnk` e o processo como `Spotify`. Tira-se a
extensão, baixa-se o caso, e compara-se **exato**.

Exato, e não por prefixo, porque prefixo pegaria "Google Chrome" com "chrome" —
mas também pegaria **"Word" com "WordPad"**. Entre errar para menos e errar para
mais, aqui se erra para menos: o anel não aparece, a dock segue funcionando, e
ninguém é informado de algo falso. Um indicador que mente é pior que um
indicador ausente, porque quem olha confia.

O preço é conhecido e está no teste: `Google Chrome.lnk` não casa com `chrome`.
Se um dia incomodar, o conserto é o agente devolver o executável junto do
atalho — não afrouxar a comparação.

### Dez segundos, e não um

Cada consulta de "quem está aberto" roda um **PowerShell** no computador
controlado. Um relógio de um segundo, como o das métricas, transformaria a dock
num consumidor constante de CPU da máquina que se quer usar.

A exceção é logo depois de abrir um programa pela dock: aí a pessoa acabou de
tocar e está olhando para o ícone, e esperar o próximo ciclo pareceria que não
pegou.

## Onde fica

**Configurações → Perfis.** Fora da tela de controle, de propósito: montar um
perfil é arrumar a casa, não usar o computador — e quem está no meio de uma
apresentação não quer esbarrar num editor. A mesma tela tem as duas seções:
perfis em cima, automações embaixo.

## Limites

| | |
|---|---|
| Perfis por conta | 30 |
| Programas por perfil | 12 |
| Tamanho do nome | 60 caracteres |

O teto de programas não é falta de espaço: mais do que isso não cabe na barra
sem virar rolagem, e uma barra com rolagem deixa de ser um atalho.

## Endpoints

| Método | Rota | O que faz |
|---|---|---|
| `GET` | `/api/v1/profiles` | Os perfis da conta e a ordem da barra |
| `POST` | `/api/v1/profiles` | Cria (o servidor gera o `id`) |
| `PUT` | `/api/v1/profiles/order` | Guarda a ordem |
| `PUT` | `/api/v1/profiles/{id}` | Substitui o conteúdo; o `id` continua |
| `DELETE` | `/api/v1/profiles/{id}` | Apaga, e tira o `id` da ordem |

`/profiles/order` é declarada **antes** de `/profiles/{id}`: os dois são `PUT`
sob o mesmo prefixo, e o FastAPI casa as rotas na ordem em que foram escritas —
ao contrário, reordenar viraria uma tentativa de editar um perfil chamado
"order". Há um teste só para isso.

Computador que não é da conta é recusado com 404 na criação e na edição.
Computador **desemparelhado depois** some do perfil na leitura, sem ser apagado
do banco: repareando a mesma máquina, o perfil volta a valer nela sem precisar
ser editado de novo.

## Verificação manual

1. Configurações → **Perfis**. Os cinco de fábrica aparecem, marcados como tal.
2. **Novo perfil**: nome, ícone, e **Adicionar** para escolher programas. A
   lista vem do menu Iniciar do computador — inclusive o que não está na área
   de trabalho.
3. Deixe os computadores todos desmarcados e salve: o perfil tem de aparecer na
   barra de qualquer máquina.
4. Arraste um perfil para o topo. Feche o app, abra de novo: a ordem tem de
   continuar.
5. Na tela de controle, abra a barra e toque num botão do seu perfil: o
   programa abre no computador.
6. Com dois computadores pareados, atribua o mesmo perfil aos dois e teste no
   segundo. Se o caminho de lá for outro, o console do agente diz que procurou
   pelo nome e o que achou.

7. Ainda em **Perfis** (nas Configurações), role até **Automações** e crie uma: dê um nome, toque
   em **Adicionar passo** e monte "abrir um programa · silenciar · brilho".
   Arraste os passos para ver a ordem mudar.
8. Toque em ▶: o computador executa a sequência inteira e o app diz quantos
   passos rodaram.
9. Acrescente um passo **Fechar programa** e rode de novo: agora o app pergunta
   antes.
10. Volte à **tela de controle** e abra a barra de perfis: no fim da fila de
    ícones há um grupo novo. Toque nele e a automação aparece como botão —
    **é daqui que ela se usa no dia a dia.**
11. Crie uma automação fixada no outro computador e confira que ela **não**
    aparece na barra deste.
12. **O teste que interessa de verdade:** toque na automação e *bloqueie a tela
    do telefone na hora*. A sequência tem de terminar inteira no computador — é
    para isso que ela vai numa mensagem só.

Para conferir se o backend no VPS já tem isto, `features` no `/health` precisa
conter `control-profiles` e `automations`.
