# Área de transferência compartilhada

Copiar num aparelho e colar no outro. O botão fica na barra de cima da tela de
controle (o ícone de prancheta) e abre uma folha com o que está copiado no
computador, dois botões e o interruptor da sincronia automática.

## As duas direções não são simétricas

E a assimetria não é escolha de projeto - é o que cada sistema permite:

**Computador → telefone pode ser automático.** O Windows tem um contador que
muda a cada cópia (`GetClipboardSequenceNumber`), então o agente percebe que
algo novo foi copiado sem precisar ler o conteúdo o tempo todo. Ele lê **só**
quando o contador muda.

**Telefone → computador é sempre a pedido.** O iOS mostra um aviso na tela toda
vez que um app lê a área de transferência. Um app que fizesse isso a cada
segundo viraria um incômodo - e, com razão, um suspeito. Então essa direção
acontece no toque do botão "Enviar", e o app lê a área de transferência só
naquele instante.

## A sincronia automática nasce desligada

O que passa pela área de transferência de alguém costuma incluir senha copiada
do gerenciador. Mandar isso sozinha para outro aparelho tem que ser uma decisão
consciente, não um padrão herdado - e o texto do interruptor diz isso com todas
as letras, em vez de esconder atrás de "sincronizar".

Com ela desligada, o agente **nem olha** o que se copia no computador: o
relógio de verificação só corre quando ela está ligada.

Quem estiver com a tela aberta recebe o aviso na hora; quem não estiver, não
recebe nada depois. Guardar o que alguém copiou para entregar mais tarde seria
guardar justamente o tipo de coisa que não se deve guardar - por isso o aviso
vai para os espectadores do momento e acaba ali.

## Detalhes que o código carrega

**Teto de 64 KB.** Copiar um log inteiro é comum, e isso não pode virar uma
mensagem de megabytes no WebSocket. O corte respeita a fronteira do caractere:
cortar por bytes num texto com acento partiria o caractere e produziria lixo do
outro lado.

**Sem eco.** Escrever na área de transferência do Windows muda o contador dele.
Sem uma memória do que acabamos de escrever, o texto que veio do telefone
voltaria para o telefone como se fosse novidade - e a cada ida e volta.

**O aviso vai pela fila que não descarta.** No backend, um frame de vídeo
atrasado pode ser jogado fora (o próximo o substitui), mas um aviso de área de
transferência perdido some sem deixar rastro. Por isso ele usa a mesma fila da
sinalização de WebRTC, que nunca descarta.
