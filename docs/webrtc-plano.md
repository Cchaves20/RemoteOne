# Plano: migrar o vídeo para WebRTC

Documento de planejamento. Nada aqui está implementado ainda.

O ponto de partida é o pipeline atual, medido em
[`video-e-latencia.md`](video-e-latencia.md): JPEG frame a frame, sempre
passando pelo servidor.

## O que o WebRTC resolve

Três problemas de uma vez, e vale separá-los porque cada um tem um peso
diferente:

1. **Codec de vídeo.** JPEG não tem quadro de diferença: mover o cursor sobre
   uma tela parada reenvia a imagem inteira. Um codec envia só os blocos que
   mudaram. É a maior economia das três — a estimativa é ~11 Mbps hoje contra
   0,5–1,5 Mbps com H.264 a 720p30 em conteúdo de desktop.
2. **Caminho direto (P2P).** Hoje cada frame sobe do PC ao VPS e desce ao
   celular. O WebRTC negocia conexão direta quando a rede permite, cortando uma
   perna inteira do trajeto — e o VPS deixa de pagar esse tráfego.
3. **Controle de congestionamento.** Hoje o agente envia no ritmo do relógio,
   sem saber se a rede aguenta. O WebRTC mede e ajusta a taxa sozinho.

## O que o WebRTC *não* resolve

- **A captura.** O `xcap` continua sendo o começo da fila (ver "Riscos", item 5).
- **A latência de entrada.** Mouse e teclado continuam indo por HTTP → WebSocket
  → agente. Isso vira a Fase 6 e é, sozinha, provavelmente a melhoria mais
  *sentida* de todas.
- **Redes hostis.** Uma parte das conexões não fecha P2P e precisa de TURN, que
  é o VPS relayando de novo — só que agora com vídeo comprimido.

## As decisões

### Codec: H.264 Constrained Baseline

O que decide é o **iPhone**: H.264 tem decodificação por hardware
(VideoToolbox) no iOS. VP8 e VP9 caem em software, o que significa mais bateria
e mais calor num aparelho que a pessoa segura na mão. AV1 em software está
fora de cogitação para tempo real hoje.

Custo dessa escolha: H.264 tem patentes (ver "Licenciamento"). VP8 seria
livre de royalties, mas paga em bateria do usuário. Recomendo H.264 e tratar o
licenciamento como uma questão a resolver antes de vender, não antes de
construir.

### Encoder no agente: `openh264` primeiro, hardware depois

- **`openh264`** (Cisco, via crate) — software, Constrained Baseline,
  multiplataforma, fácil de integrar. A 720p30 é perfeitamente viável, e já
  reduzimos para 1280px de largura, então 720p é exatamente o alvo.
- **Media Foundation** (encoder de hardware do Windows, QuickSync/NVENC) — bem
  mais leve para a CPU, mas é API COM chamada do Rust. Fica como otimização
  depois que o caminho todo estiver funcionando.
- **x264 está descartado**: licença GPL ou licença comercial paga. Como a ideia
  é comercializar, não vale a dor de cabeça.

### Transporte no agente: crate `webrtc` (webrtc-rs)

É a implementação em Rust puro — ICE, DTLS, SRTP, empacotamento RTP. Não
codifica vídeo (por isso o openh264 acima); ela transporta quadros já
codificados.

Risco a verificar: interoperar com a libwebrtc (que é o que o `flutter_webrtc`
usa por baixo). Costuma funcionar, mas é item de spike, não de fé.

### App: `flutter_webrtc`

É a única opção real no Flutter. **E é o maior risco do projeto inteiro** — ver
a seção seguinte.

### Quem faz a oferta: o app

O app é quem inicia a sessão, então ele monta a oferta com um transceptor de
vídeo `recvonly` e o agente responde. O agente já está parado escutando o
WebSocket dele, então recebe a oferta sem precisar de nada novo.

### Sinalização: pelos WebSockets que já existem

Nada de infraestrutura nova. O `/ws/viewer/{device_id}` já é um canal
autenticado por token e por posse do dispositivo — vira também o canal de
sinalização. O backend repassa SDP e candidatos ICE entre os dois lados usando
o `ConnectionManager.send_to_agent()` que já existe.

O padrão de pergunta-e-resposta do `rpc.py` (`request_id` + `Future`) é o molde
para a troca de SDP.

**Regra de segurança:** candidatos ICE carregam endereços IP dos dois lados.
Só podem ser repassados entre pares já autenticados e pareados — a mesma
verificação que o `viewer_ws` faz hoje, sem exceção.

## O risco que decide tudo: o .ipa

Antes de escrever uma linha de Rust, é preciso responder:

> **O `flutter_webrtc` funciona num .ipa não assinado, instalado pelo Sideloadly
> com Apple ID grátis?**

Se a resposta for não, todo o resto do plano muda e é melhor descobrir isso no
primeiro dia. Pontos concretos a verificar:

- O `flutter_webrtc` traz o framework binário do WebRTC, que é grande. O .ipa
  cresce bastante e o `max_build_duration: 45` do `codemagic.yaml` pode ficar
  curto.
- A pasta `ios/` não é versionada — é gerada com `flutter create` a cada build.
  Então o Podfile (mínimo iOS 13) e o `Info.plist` precisam ser remendados por
  script, do mesmo jeito que já é feito hoje com a chave do Face ID.
- Mesmo sendo só receptor de vídeo, convém adicionar
  `NSCameraUsageDescription` e `NSMicrophoneUsageDescription`: o binário
  referencia essas APIs e o iOS derruba o app se a chave faltar.
- Apple ID grátis: 3 apps e 7 dias. Nenhum entitlement especial é necessário
  para WebRTC, o que é a boa notícia aqui.

**Consequência prática para as fases:** como só dá para ter um .ipa instalado
por vez, o caminho JPEG **tem que continuar funcionando no mesmo binário**. Um
único sideload precisa entregar os dois caminhos, com escolha automática.

## Fases

### Fase 0 — Spikes (antes de qualquer compromisso)

| # | Pergunta | Como responder |
|---|---|---|
| S1 | O `flutter_webrtc` sideloada? | App mínimo, build no Codemagic, instalar e abrir uma `RTCPeerConnection` |
| S2 | Quanto custa codificar H.264 no agente? | `openh264` sobre frames capturados; medir ms/frame e KB/s contra o JPEG de hoje |
| S3 | O P2P fecha na rede real? | iPhone no 4G ↔ PC em casa; medir quantas vezes conecta sem TURN |

S1 é bloqueante. S2 e S3 podem correr em paralelo.

### Fase 1 — Sinalização (backend)

Repasse de `offer`/`answer`/`ice_candidate` entre app e agente pelos canais que
já existem. Sem vídeo ainda — o teste é a sinalização chegar inteira dos dois
lados. É a fase mais fácil de testar automaticamente.

### Fase 2 — Agente transmite

`webrtc` + `openh264`, alimentado pela captura atual. A deduplicação e o filtro
de caixa continuam valendo: economizam CPU *antes* de qualquer codificação.

Com N espectadores: codifica **uma vez** e entrega a mesma amostra para as N
conexões.

### Fase 3 — App recebe

`RTCVideoRenderer` no lugar do `RawImage`. O mapeamento de toque → coordenada
do mouse precisa ser refeito em cima do tamanho do vídeo, e o modo lupa
(`InteractiveViewer` / `Transform`) precisa continuar funcionando por cima.

### Fase 4 — Fallback automático (entra junto com a Fase 3)

Se o ICE falhar, se a conexão cair, ou se nenhum quadro chegar em alguns
segundos, o app fecha a conexão WebRTC e reabre o caminho JPEG. O usuário vê,
no máximo, uma pausa.

Sem isso, uma rede ruim vira "o app não funciona".

### Fase 5 — TURN, se o S3 disser que precisa

`coturn` no VPS. Consome pouca RAM (cabe no 1 GB), mas relaya vídeo — a franquia
de saída da Oracle é generosa e o vídeo agora está comprimido, então deve
caber. Autenticação por credencial temporária, nunca aberto.

### Fase 6 — Entrada pelo canal de dados

Mouse e teclado saem do HTTP e passam para um data channel do WebRTC, direto de
ponta a ponta, sem ordenação garantida (posição de mouse antiga não interessa).

É a fase que a pessoa mais vai *sentir*, e por isso vale considerar antecipá-la
para logo depois da Fase 2.

## Como testar

O ponto fraco de tudo isso é que WebRTC é difícil de testar sozinho. O que dá
para automatizar:

- **Backend (bom):** o repasse de sinalização é lógica pura — mesmo molde dos
  testes que já existem para o `rpc.py`.
- **Agente (razoável):** dá para abrir duas `RTCPeerConnection` no mesmo teste
  em Rust, conectar uma na outra e mandar uma faixa sintética. Roda no Linux,
  sem tela, sem Windows.
- **App (fraco):** não dá para testar WebRTC em teste de widget. Fica manual.

Ou seja: a validação de ponta a ponta continua sendo você com o iPhone na mão —
o que já é o caso hoje.

## Riscos

1. **`flutter_webrtc` + sideload** — bloqueante, e é por isso que é o S1.
2. **Interoperar webrtc-rs ↔ libwebrtc** — costuma funcionar; verificar cedo.
3. **Compilar o `openh264` no Windows** — pode pedir cmake/nasm e dar atrito no
   ambiente de build.
4. **Tamanho e tempo de build do .ipa** — Codemagic tem cota mensal.
5. **A captura vira o novo gargalo.** Com H.264 queremos 30 fps, e o `xcap`
   custa dezenas de ms por quadro. A resposta certa é a **Desktop Duplication
   API (DXGI)** do Windows, que entrega retângulos sujos e é bem mais rápida.
   Provavelmente vira um item próprio.
6. **Regressão de qualidade percebida.** H.264 a taxa baixa borra texto pequeno,
   e texto é justamente o que se lê numa tela de computador. Pode ser preciso
   forçar taxa mais alta ou perfil melhor para conteúdo de desktop.

## Licenciamento (H.264)

O H.264 é coberto por patentes administradas por um pool (Via LA). Distribuir
um produto comercial que codifica/decodifica H.264 pode implicar royalties,
ainda que existam faixas isentas por volume. A distribuição do `openh264` pela
Cisco tem um arranjo próprio, que depende de usar o binário deles.

Não é conselho jurídico e eu não vou fingir que é. É um item para checar antes
de cobrar pelo produto — não antes de construí-lo. Se virar um problema, o
plano B é VP8, que é livre de royalties e custa bateria do iPhone.
