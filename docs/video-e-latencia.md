# Vídeo e latência

Como a imagem do computador chega ao celular.

Hoje existem **dois caminhos**, e o app usa o melhor disponível. A migração para
WebRTC está descrita em [`webrtc-plano.md`](webrtc-plano.md), que também é o
diário das decisões e das medições.

## Caminho principal: vídeo por WebRTC

```
Windows → captura contínua (WGC) → RGB reduzido → H.264 → RTP/DTLS
       → iPhone (decodificação por hardware) → RTCVideoView
```

Vai **direto** do computador ao celular, sem passar pelo servidor, que só
intermedia a negociação. Mouse e teclado seguem pelo mesmo caminho, num canal de
dados.

## Caminho de segurança: JPEG por WebSocket

```
Windows → captura → RGB → reduz → hash → JPEG → WebSocket
       → backend (FrameStore + broadcast) → WebSocket → iPhone
       → decodifica → RawImage
```

Continua no ar e assume sozinho se o WebRTC não fechar — o agente só para de
mandar JPEG enquanto existe uma sessão de vídeo **conectada**. É o que garante
que uma rede hostil degrade a experiência em vez de quebrá-la.

O resto deste documento é sobre as otimizações do caminho JPEG, que continuam
valendo: várias delas (a captura reduzida, o filtro de caixa) alimentam os dois.

### Limitação conhecida: dois espectadores em caminhos diferentes

"O agente para de mandar JPEG enquanto existe sessão de vídeo conectada" vale
para o computador inteiro, não por espectador. Com **dois aparelhos** olhando o
mesmo computador, um por WebRTC e outro por JPEG (porque o vídeo falhou ali, ou
porque a pessoa desligou o WebRTC nas configurações), o segundo fica com a
imagem congelada: o agente já parou de emitir JPEG.

Não está resolvido de propósito. Para resolver, o agente precisaria saber
quantos espectadores estão em cada caminho - hoje ele sabe quantas sessões de
vídeo tem, mas "alguém pediu a tela" é uma bandeira só. A correção certa passa
pelo backend, que é quem conhece os espectadores, informando a contagem; e o
caso (duas pessoas, uma delas sem WebRTC) é raro o bastante para não valer o
protocolo a mais antes de aparecer de verdade.

O sintoma, para reconhecer: a tela para, o contador de fps vai a zero e o app
continua dizendo "ao vivo". Sair e voltar na tela de controle resolve, porque a
sessão nova negocia WebRTC de novo.

## O que foi otimizado

### 1. Redimensionamento: `thumbnail` no lugar de `resize(Triangle)`

Reduzir 1920×1080 → 1280×720 era, de longe, a etapa mais cara do pipeline. O
filtro triangular do `resize` interpola pixel a pixel; o `thumbnail` usa um
filtro de caixa, que para **redução** dá qualidade equivalente por uma fração
do custo.

### 2. Deduplicação: tela parada não gasta nada

O agente calcula um hash (FNV-1a, 64 bits) da imagem **já reduzida** e o compara
com o do frame anterior. Se forem iguais, a tela não mudou: o agente não
codifica o JPEG e não envia nada. O app continua mostrando a imagem que já tem.

Isso cobre um caso muito comum — ler um documento, um vídeo pausado, o PC
ocioso — em que antes se gastava CPU e rede repetindo a mesma imagem.

O hash é calculado depois da redução, não antes, para que o custo seja
proporcional ao que de fato seria transmitido.

Cuidados de correção:

- o hash zera ao receber `start_stream` e `stop_stream`, então o primeiro frame
  de uma sessão nova sempre vai (o app ainda não tem imagem alguma);
- quem entra no meio de uma transmissão recebe o último frame guardado pelo
  backend (`FrameStore`), então não fica esperando a tela mexer;
- o contador de fps do app mostra "tela parada" em vez de "0 fps" — 0 é o
  comportamento esperado com a tela imóvel, não um defeito.

### 3. App: frames fora do cache de imagens do Flutter

O app usava `Image.memory` a cada frame. Como cada frame é um `Uint8List` novo,
o cache de imagens do Flutter tratava cada um como uma imagem inédita: em
poucos segundos de transmissão o cache enchia e passava a despejar entradas sem
parar.

Agora o app decodifica com `decodeImageFromList` (que não passa pelo cache),
guarda o `ui.Image` num `ValueNotifier` e desenha com `RawImage`, liberando o
frame anterior assim que o novo entra em cena.

Dois ganhos vêm junto:

- **só a imagem se reconstrói** a cada frame, não a tela inteira (dock, botões,
  gestos) — antes era um `setState` na tela toda a cada frame recebido;
- **frames atrasados são descartados**: se um novo chega enquanto o anterior
  ainda está sendo decodificado, o antigo é jogado fora. Melhor mostrar a
  imagem mais recente do que acumular fila e ficar para trás.

## Medições

Frame 1920×1080 → 1280px, qualidade 50, em release. Os números absolutos são da
máquina de desenvolvimento (bem mais lenta que um PC comum); o que importa é a
proporção. Reproduza com:

```bash
cd agent && cargo run --release --example bench_capture
```

| Cenário | Antes | Depois |
| --- | ---: | ---: |
| Tela mudando (converter + reduzir + codificar) | 96,8 ms | **47,0 ms** |
| Tela parada | 96,8 ms + envio | **20,8 ms, 0 byte** |
| Tamanho do JPEG | 68 KB | 70 KB |

Com a tela mudando, o custo por frame caiu pela metade — o teto de fps que a
CPU aguenta praticamente dobrou. Com a tela parada, o custo cai a um quinto e o
tráfego vai a zero.

O JPEG ficou 2 KB maior porque o filtro de caixa preserva um pouco mais de
detalhe fino que o triangular; é uma troca boa por 50 ms.

## Por que isso não bastou, e o WebRTC entrou

Estes eram os limites do caminho JPEG. Todos foram confirmados na prática, e
juntos motivaram a migração:

- **JPEG não tem quadro-chave nem quadro de diferença.** Mover o cursor sobre
  uma tela parada obriga a reenviar a imagem inteira. Um codec de vídeo
  (H.264/VP9/AV1) enviaria só o que mudou — a diferença de banda em uso normal
  é de uma ordem de grandeza.
- **O tráfego passa pelo servidor.** Todo frame sobe do PC ao VPS e desce ao
  celular. O WebRTC negocia uma conexão direta (P2P) quando a rede permite,
  cortando uma perna inteira do trajeto — e com ela boa parte da latência.
- **Não há controle de congestionamento.** O agente envia no ritmo do relógio,
  sem saber se a rede está aguentando. O WebRTC *mede* a capacidade e tem para
  onde reportar isso — mas usar a medida para segurar a taxa ainda não está
  feito (Fase 4b): nenhuma configuração do codificador limita a banda sem travar
  a imagem, então falta baixar resolução/fps sob pressão.
- **A deduplicação é tudo ou nada.** Um pixel diferente reenvia o frame
  completo. Um codec resolve isso por blocos.

A deduplicação e o filtro de caixa continuaram úteis depois do WebRTC: economizam
CPU antes de qualquer codificação.

Como isso se resolveu, com os números medidos, está em
[`webrtc-plano.md`](webrtc-plano.md).
