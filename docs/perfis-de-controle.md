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

### O que ainda falta

Abrir quatro programas empilhados ainda não é um ambiente montado; é a mesma
bagunça em três toques a menos. O que falta é cada um abrir **no seu lugar**, com
os layouts de janela do Windows. Está planejado em
[`plano-4.0.md`](plano-4.0.md), e este botão é de propósito o passo anterior:
serve para descobrir, usando, o quanto o resto ainda acrescenta.

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

## Onde fica

**Configurações → Perfis.** Fora da tela de controle, de propósito: montar um
perfil é arrumar a casa, não usar o computador — e quem está no meio de uma
apresentação não quer esbarrar num editor.

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

Para conferir se o backend no VPS já tem isto, `features` no `/health` precisa
conter `control-profiles`.
