# Transferência de arquivos

Trazer um arquivo do computador para o celular e mandar um do celular para o
computador, sem cabo e sem mandar e-mail para si mesmo.

Fica no menu de cada computador na lista, em **Arquivos**.

## O que dá para fazer

- **Navegar** pelas pastas do computador, a partir da pasta do usuário.
- **Trazer um arquivo**: toque nele e o iPhone abre a folha de
  compartilhamento, onde você escolhe "Salvar em Arquivos", mandar por
  WhatsApp, abrir num app — o que quiser.
- **Enviar um arquivo**: o botão flutuante abre o seletor do iPhone, e o
  arquivo aparece no computador em `Downloads\Deskside`.

Limite de **100 MB** por arquivo, nos dois sentidos.

## As pastas conhecidas

Na raiz, antes da lista de pastas, aparece uma faixa com **Área de Trabalho,
Downloads, Documentos, Imagens, Músicas e Vídeos**. É o mesmo conjunto que o
Explorer fixa no topo, e existe pelo mesmo motivo: quem abre a tela de arquivos
quase sempre quer uma dessas seis, e chegar nelas por navegação custa toques
para nada.

Os caminhos são **perguntados ao Windows**, não montados por concatenação.
Duas razões, e as duas aparecem em máquina real:

- **O OneDrive redireciona.** Com o backup ligado, a Área de Trabalho vira
  `C:\Users\você\OneDrive\Área de Trabalho`, e `USERPROFILE\Desktop` passa a
  apontar para uma pasta vazia — ou para nenhuma.
- **Os nomes são traduzidos.** "Área de Trabalho" em português, "Desktop" em
  inglês, "Escritorio" em espanhol. Um caminho fixo em inglês só funcionaria
  numa parte das instalações.

O agente resolve isso com uma única chamada ao PowerShell no arranque:
`[Environment]::GetFolderPath` para cinco delas e a chave de registro
`Shell Folders` (GUID `{374DE290-...}`) para Downloads, que é a única sem
constante própria. O resultado fica em cache — as pastas conhecidas não mudam
de lugar enquanto o agente roda.

Pasta que não existe não vira atalho. Mostrar um botão que abre em erro é pior
do que não mostrar o botão.

Um agente antigo, que ainda não manda a lista, continua funcionando: o campo é
opcional e a faixa simplesmente não aparece.

## A fronteira: a pasta do usuário

O agente só enxerga dentro da pasta do usuário (`C:\Users\você`). Não é o dono
da máquina que precisa ser contido — ele já pode tudo nela. É o **caminho que
chega pela rede**: sem essa checagem, um `..\..\Windows\System32` numa mensagem
adulterada leria o que quisesse.

O caminho é canonicalizado antes de ser comparado com a raiz, que é o que
derruba `..` e atalhos apontando para fora. Comparar texto cru deixaria passar.

No sentido inverso vale o mesmo: o nome que vem do celular é reduzido a **só um
nome** antes de virar arquivo — `../../Windows/System32/algo.dll` vira
`algo.dll`.

## Por que passa pelo servidor

O canal de dados P2P do WebRTC existe e seria mais rápido, mas só enquanto o
vídeo está conectado. Arquivo tem de funcionar sempre — inclusive com a tela
fechada, numa rede que derrubou o P2P. Então a transferência usa o caminho que
está sempre de pé: HTTP até o backend, WebSocket do backend até o agente.

O backend é **relé, não depósito**. Os pedaços passam por ele e seguem adiante;
o arquivo inteiro não existe ali em momento algum. É o que torna possível mover
100 MB numa VM de 1 GB de RAM.

```
 iPhone            backend                    computador
   |  GET /download   |                            |
   |  ──────────────► |  ── read_file (id) ──────► |  abre o arquivo
   |  ◄─── pedaço ─── |  ◄── file_chunk (seq 0) ── |
   |  ◄─── pedaço ─── |  ◄── file_chunk (seq 1) ── |
   |  ◄─── fim ────── |  ◄── file_done ─────────── |
```

## Contrapressão: o detalhe que faz isso não estourar

Um disco lê mais rápido do que uma rede móvel entrega. Sem nada segurando, o
computador leria o arquivo inteiro para uma fila e a memória acabaria —
primeiro no VPS, depois no agente.

São três freios, um em cada trecho:

1. **No agente**, os pedaços saem por um canal de capacidade 4. A thread que lê
   o arquivo usa envio bloqueante: quando o canal enche, ela **para** de ler.
2. **No backend**, cada transferência tem uma fila de 4 pedaços. Quando ela
   enche, o backend deixa de drenar o socket do agente — e o freio 1 aperta.
3. **No envio ao computador**, cada pedaço é `await`-ado até o agente aceitar,
   o que segura o upload do celular na mesma medida.

Nenhum dos três precisa saber dos outros: cada um só espera o vizinho.

## Pedaço fora de ordem

Cada pedaço leva um número de sequência, e as duas pontas conferem. É a falha
que mais importa evitar: um arquivo remontado fora de ordem **parece** ter
chegado, e o erro só aparece quando alguém tenta abri-lo, muito depois.

Fora de ordem encerra a transferência com erro. Um arquivo pela metade nunca
recebe o nome final: ele é escrito como `.parte` e só é renomeado no fim.

## Nome repetido não sobrescreve

Mandar `nota.txt` duas vezes gera `nota.txt` e `nota (2).txt`. Sobrescrever
seria a única alternativa, e apagar em silêncio o arquivo que a pessoa mandou
antes é o tipo de perda que não se desfaz.

## Endpoints

| Método | Rota | O que faz |
|---|---|---|
| `GET` | `/api/v1/devices/{id}/files?path=` | Lista uma pasta. `400` se o caminho é recusado, `503` se o agente está offline, `504` se ele não respondeu |
| `GET` | `/api/v1/devices/{id}/files/download?path=` | Traz um arquivo (corpo binário, em fluxo) |
| `POST` | `/api/v1/devices/{id}/files/upload?name=` | Envia um arquivo (corpo = os bytes crus). `413` acima do limite, `502` se o computador recusou |

Todos exigem autenticação e só respondem ao dono do computador.

O envio manda os bytes crus, sem `multipart`: o nome já vai na URL, e envelopar
custaria uma cópia a mais em cada ponta.

## Verificação manual

1. Menu do computador → **Arquivos**. A pasta do usuário aparece, com a faixa
   das pastas conhecidas em cima.
2. Toque em **Downloads** na faixa: tem de abrir a pasta certa. Se o OneDrive
   estiver ligado nessa máquina, confira que **Área de Trabalho** abre a pasta
   do OneDrive, e não uma vazia.
3. Entre numa subpasta: a faixa some (ela só existe na raiz). Volte por "Pasta
   acima". Na raiz, o "voltar" não aparece — é o limite, e oferecer um botão
   que sempre dá erro seria um beco sem saída.
4. Toque num arquivo pequeno: a folha de compartilhamento abre com ele.
5. Botão **Enviar arquivo**: escolha algo no iPhone e confira que apareceu em
   `Downloads\Deskside` no computador.
6. Mande o mesmo arquivo de novo: tem de virar `nome (2).ext`, sem apagar o
   primeiro.

Para conferir se o backend no VPS já tem isto, `features` no `/health` precisa
conter `file-transfer`.
