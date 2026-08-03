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

O que **não** vem por aqui é imagem copiada de um editor ou do navegador (aí
são pixels, não caminho). Isso exigiria um plugin nativo no iOS para escrever
imagem na área de transferência do aparelho, e ficou de fora.

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
