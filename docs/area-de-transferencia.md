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

## Arquivos copiados (inclusive vídeo)

Copiar um vídeo no Explorer **não** põe o vídeo na área de transferência: põe o
**caminho** dele. Isso vale para qualquer arquivo, e é por isso que "área de
transferência de vídeo" não existe em lugar nenhum - o que existe é uma lista
de caminhos.

Visto por esse lado, o recurso já estava metade pronto: quem sabe buscar
arquivo por caminho é a transferência de arquivos, com pedaços e contrapressão
prontos. Então a folha mostra os arquivos copiados no computador, com o
tamanho, e o botão traz cada um pela folha de compartilhar do iOS - o mesmo
caminho da tela de arquivos.

Imagem copiada é outra coisa, e tem seção própria abaixo: ali são pixels, não
caminho.

Dois casos em que o botão nasce apagado, com o motivo à vista em vez de falhar
depois do toque:

- **Pasta.** O download é de arquivo; para pasta, a tela de arquivos.
- **Acima de 100 MB**, o teto da transferência.

E um terceiro: arquivo copiado de **fora da pasta do usuário** não entra na
lista. É o mesmo limite do download - mostrar o que não dá para buscar seria
oferecer um botão que falha. Mas sumir em silêncio é pior: quem copiou três
arquivos de `D:\` veria exatamente a mesma tela de quem não copiou nada. Por
isso o agente conta os recusados, o número atravessa até o app, e a folha diz
"3 arquivos copiados estão fora da pasta do usuário".

## Imagem copiada

Um Print Screen, um recorte da ferramenta de captura, uma imagem copiada do
navegador. Aqui **não há caminho nenhum**: a imagem existe só na área de
transferência, e ou vêm os bytes ou não vem nada. É a diferença para os
arquivos, e é ela que faz este caminho ser separado.

A folha mostra a imagem com o tamanho e um botão de **salvar ou compartilhar**.

### Por que "salvar" e não "colar"

Colar a imagem direto na área de transferência do iPhone exigiria um plugin
nativo: o `Clipboard` do Flutter só trata texto. A folha de compartilhar chega
ao mesmo lugar por um caminho que o app já usa para os arquivos — dali a imagem
vai para Fotos, para uma conversa, para onde a pessoa quiser. É um toque a mais
e nenhuma dependência nova.

O caminho inverso (imagem do telefone → computador) continua de fora pela mesma
razão, com um agravante: além de escrever, seria preciso **ler** a área de
transferência do iOS, que é exatamente a operação que o sistema denuncia na tela
a cada vez.

### O que o agente faz com a imagem antes de mandar

O Windows entrega um DIB — um BMP sem cabeçalho de arquivo. Uma captura de tela
4K em BMP tem cerca de 25 MB, e isso não pode virar uma mensagem no WebSocket.
O agente:

1. **Reduz** se o maior lado passa de 1600 px. No telefone a imagem aparece num
   espaço de 400 px; mandar 3840 seria pagar rede e memória por detalhe que
   ninguém vê, e 1600 ainda deixa ler texto pequeno ao ampliar.
2. **Tenta PNG.** A imagem copiada mais comum, de longe, é uma captura de tela:
   texto, janelas, linhas retas. Nisso o PNG ganha do JPEG em tamanho *e* em
   qualidade, porque não borra a borda das letras.
3. **Cai para JPEG a 80** se o PNG passar de 2 MB. Uma foto colada do navegador
   comprime mal em PNG, e o JPEG é o formato feito para ela. (A conversão tira o
   canal alfa antes: JPEG não tem transparência, e um recorte com fundo
   transparente é justamente o tipo de imagem que se copia.)
4. **Reduz de novo e repete**, no máximo duas vezes, se nenhum dos dois couber.
   Entregar uma imagem menor é melhor que não entregar nada, e o limite impede
   que uma imagem patológica prenda o agente reduzindo para sempre.

Tentar os dois formatos e ficar com o que couber é mais simples, e mais certo,
do que adivinhar o tipo de imagem pelo conteúdo.

### A imagem não vai no aviso automático

O aviso de cópia nova continua sendo **só texto**. A diferença é de ordem de
grandeza: um texto copiado custa alguns quilobytes e o aviso sai sozinho a cada
cópia, enquanto uma captura de tela custa megabytes. Mandar isso sem ninguém ter
pedido gastaria a rede de quem copiou uma imagem só para colar no próprio
computador.

Então a imagem vem **a pedido**, quando a folha abre. E ela não fica guardada na
tela depois que a folha fecha: são megabytes, e segurá-los pelo resto da sessão
custaria memória por algo que a pessoa já viu.

### Abrir antes de ler

A primeira versão disto voltava lista vazia sempre, com um arquivo copiado bem
à vista. A causa: a biblioteca tem duas funções parecidas, e só uma delas abre
a área de transferência.

```rust
clipboard_win::get(FileList)           // pressupõe que já está aberta
clipboard_win::get_clipboard(FileList) // abre (com tentativas), lê e fecha
```

Ler sem abrir falha em **toda** chamada, e o erro estava sendo engolido por um
`Err(_) => return Vec::new()`. Duas lições ficaram no código: o erro agora é
impresso no console em vez de virar lista vazia, e a ausência de arquivo
copiado é checada antes (`is_format_avail`), para que "ninguém copiou" e "a
leitura falhou" parem de compartilhar o mesmo resultado.

Vale notar o que **não** teria pego isso. A verificação cruzada de tipos para
Windows compila as duas chamadas sem reclamar: as assinaturas são iguais, o que
difere é a pré-condição, e pré-condição não é tipo. Erro de contrato em API de
sistema operacional só aparece rodando na máquina certa.

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
