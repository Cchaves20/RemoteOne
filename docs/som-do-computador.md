# Som do computador no telefone

O que sai pelo alto-falante do computador sai também pelo telefone. Liga e
desliga no painel de mídia da tela de controle (o botão de fone, à direita das
teclas de mídia).

## Por onde o som anda

Pela **mesma conexão direta** que leva a tela: uma faixa de áudio Opus na
sessão WebRTC. Não e uma escolha estética. O Opus e obrigatório em WebRTC, e o
celular toca a faixa que chega sem precisar de tocador, de plugin nem de
formato combinado - o encaixe ja existe.

Consequencia direta: **sem vídeo direto não há som**. Quando a tela está indo
por JPEG (o caminho reserva, que passa pelo servidor), não existe faixa de
áudio, e o botão avisa em vez de ligar calado.

## O caminho, do alto-falante ao fone

1. **Captura.** O agente abre o dispositivo de *saída* como se fosse entrada -
   é assim que o Windows faz "loopback" (o `cpal` liga o
   `AUDCLNT_STREAMFLAGS_LOOPBACK` sozinho nesse caso). O que chega e a mistura
   que iria para o alto-falante: todos os programas, sem escolher nenhum.
2. **Formato.** O que a placa entrega quase nunca e o que o Opus aceita: vem na
   taxa dela (44,1 kHz e comum), com o numero de canais dela (mono, 5.1) e em
   blocos de tamanho irregular. O `Shaper` (`agent/src/audio.rs`) converte para
   48 kHz estéreo em quadros de 20 ms exatos.
3. **Opus,** 96 kbps estéreo, com `stereo=1` no SDP - sem isso o WebRTC negocia
   como voz e a música chega em um canal só.
4. **Faixa de áudio** da sessão, escrita pelo mesmo laço que escreve o vídeo.
5. **No telefone**, o alto-falante de música. Sem esse ajuste o iPhone toca no
   alto-falante de encostar no ouvido, porque WebRTC nasce pensando em ligação.

## A faixa de som só existe quando alguém pediu

A oferta comum do app **não** tem faixa de áudio. Ligar o som refaz a sessão de
vídeo, e é a sessão nova que a carrega. A imagem pisca por um instante, e esse
é o preço.

A alternativa - pedir som em toda sessão e deixar a faixa vazia - foi tentada e
custou caro: no iPhone, a faixa a mais na negociação derrubou o **vídeo**, que
voltou a cair no JPEG. O caso é o que separa o principal do extra: ver o
computador é a função do app, ouvi-lo é um acréscimo, e um acréscimo não pode
ter poder de quebrar o principal.

Daí três proteções, além de o áudio ser opcional:

- No agente, a faixa de som entra com `match` e não com `?`: se falhar, a
  sessão segue sem som em vez de morrer inteira.
- No app, o bloco do áudio tem prazo (2 s para o modo da sessão, 3 s para o
  transceptor). Um ajuste de aparelho que não responde não segura a oferta.
- Um teste negocia de verdade, no Linux, uma oferta **com** som e outra
  **sem**, e confere que a resposta traz as duas faixas e que o app a aceita.
  Esse teste não existia quando o vídeo quebrou.

## Três decisões que o código carrega

**A faixa nasce com a oferta, não quando se liga o som.** Criar uma faixa nova
no meio da sessão exigiria renegociar tudo. Enquanto ninguém liga, ela
simplesmente não carrega nada.

**A thread da placa de som nunca espera.** Quando a rede não acompanha, o
quadro e descartado (`try_send`), nunca enfileirado - travar ali engasgaria o
som do computador inteiro, não só o do telefone.

**A captura para sozinha** quando a última sessão de vídeo se fecha, e o app
manda desligar ao sair da tela. Um computador capturando som para ninguém e um
desperdício que não aparece na tela de ninguém.

## Computador quase mudo, som no telefone

O jeito de ouvir só no telefone sem instalar nada: deixe o volume do Windows no
**mínimo** - sem silenciar - e recupere o volume no controle deslizante do
painel de mídia (1x a 32x).

Funciona porque o Windows aplica o volume mestre na mistura que o loopback
entrega: um computador baixinho produz um sinal baixinho, e multiplicar devolve
o que se esperava ouvir. **Silenciar não serve**: aí não sobra sinal nenhum
para amplificar.

A amplificação acontece **no computador, antes de codificar**, e essa escolha é
o ponto todo. O Opus distribui o ruído de codificação em proporção ao sinal que
recebe; mandar um sinal fraco e amplificar no telefone amplificaria o ruído
junto, e o resultado seria chiado. Amplificando antes, o codificador vê um
sinal de nível normal e o que chega é o som limpo.

Se o ganho ficar alto demais para o volume do computador, o som é cortado no
limite (e o agente avisa uma vez no console). O corte é seco de propósito: um
limitador suave disfarçaria o excesso, e o que se quer é perceber que passou.

Quem quiser o computador **totalmente** mudo continua precisando de uma saída
virtual (VB-CABLE e afins) definida como padrão - aí os alto-falantes não
recebem nada e o agente captura o cabo, sem ganho nenhum.

## Por que o som picotava

Três causas, e as três estavam no computador - não na rede:

**1. O som disputava o laço principal com o vídeo.** O `select!` do agente
sorteia qual ramificação atender quando várias estão prontas. O som precisa de
uma volta a cada 20 ms; a codificação de vídeo 1080p leva dezenas de ms e
ocupa o laço enquanto roda. No sorteio, o som perdia metade das vezes, o canal
enchia e os quadros eram descartados. Agora o `select!` é `biased` com o som
**primeiro**, e cada despertar esvazia tudo o que estiver esperando em vez de
um pacote só.

**2. A correção de erro estava anunciada mas desligada.** O SDP dizia
`useinbandfec=1` e o codificador nunca a ativava - pior que não anunciar,
porque o telefone conta com uma recuperação que não existe. Com a FEC ligada
(e 10% de perda esperada), cada quadro leva uma versão comprimida do anterior
e um pacote perdido é reconstruído. Numa rede móvel passando por relay, perder
pacote é rotina.

**3. A codificação rodava com complexidade 10 na thread da placa de som**, que
tem prazo de milissegundos. Estourar esse prazo faz o Windows descartar o
bloco inteiro. A 96 kbps estéreo, complexidade 5 é inaudivelmente diferente e
custa de duas a três vezes menos CPU - numa máquina que está codificando vídeo
ao mesmo tempo, isso é o que sobra de folga.

E, para a próxima vez, o número que separa as causas: o resumo do áudio no
console do agente agora conta os quadros **DESCARTADOS**. Diferente de zero
significa que o gargalo é o computador; zero com som picotando significa que a
perda é da rede.

## Limites conhecidos

- Só Windows (e a única plataforma com agente real).
- A placa precisa entregar float de 32 bits, que e o que o modo compartilhado
  do WASAPI usa. Fora disso o agente recusa com uma mensagem clara em vez de
  mandar ruído.
- Sem áudio em segundo plano: com o app fora da tela, o iOS pausa o som.
- O som e o da máquina inteira. Escolher um programa só exigiria captura por
  processo (existe no Windows 10 2004+, mas por outra API).
