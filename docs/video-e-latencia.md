# Vídeo e latência

Como a imagem do computador chega ao celular, o que já foi otimizado e o que
vem a seguir (WebRTC).

## O caminho de um frame

```
Windows → xcap (captura RGBA) → RGB → reduz → hash → JPEG → WebSocket
       → backend (FrameStore + broadcast) → WebSocket → iPhone
       → decodifica → RawImage
```

Tudo o que é caro acontece no computador (agente). O backend só repassa bytes,
e o celular só decodifica e desenha.

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

## Limites que sobram (e por que WebRTC é o próximo passo)

O gargalo agora é o formato, não o código:

- **JPEG não tem quadro-chave nem quadro de diferença.** Mover o cursor sobre
  uma tela parada obriga a reenviar a imagem inteira. Um codec de vídeo
  (H.264/VP9/AV1) enviaria só o que mudou — a diferença de banda em uso normal
  é de uma ordem de grandeza.
- **O tráfego passa pelo servidor.** Todo frame sobe do PC ao VPS e desce ao
  celular. O WebRTC negocia uma conexão direta (P2P) quando a rede permite,
  cortando uma perna inteira do trajeto — e com ela boa parte da latência.
- **Não há controle de congestionamento.** Hoje o agente envia no ritmo do
  relógio, sem saber se a rede está aguentando. O WebRTC ajusta a taxa sozinho.
- **A deduplicação é tudo ou nada.** Um pixel diferente reenvia o frame
  completo. Um codec resolve isso por blocos.

A deduplicação e o filtro de caixa continuam úteis depois do WebRTC: economizam
CPU antes de qualquer codificação.
