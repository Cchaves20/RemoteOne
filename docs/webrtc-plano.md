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
   mudaram. É a maior economia das três, e o [S2](#resultado-do-s2) já a mediu:
   16–21 Mbps hoje contra 0,08–0,22 Mbps com H.264, na mesma qualidade.
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
  reduzimos para 1280px de largura, então 720p é exatamente o alvo. O S2
  confirmou: custa **menos** CPU que o JPEG de hoje.
  Tem um perfil próprio para conteúdo de tela (`ScreenContentRealTime`), que é
  o que usamos na medição.
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

## O risco que decidia tudo: o .ipa — resolvido

> **O `flutter_webrtc` funciona num .ipa não assinado, instalado pelo Sideloadly
> com Apple ID grátis?**
>
> **Sim.** Verificado no [S1](#resultado-do-s1), num iPhone real. Nenhum
> entitlement especial foi necessário.

O que foi preciso ajustar para chegar lá — tudo já no `codemagic.yaml`:

- **Mínimo de iOS 13.** É o que o podspec do `flutter_webrtc` exige. Como a
  pasta `ios/` não é versionada (é gerada com `flutter create` a cada build), o
  Podfile e o `project.pbxproj` são remendados por script antes do
  `pod install`.
- **Chaves de câmera e microfone no `Info.plist`.** O app só recebe vídeo e
  nunca usa nenhum dos dois, mas o binário do WebRTC referencia essas APIs e o
  iOS encerra o processo se a chave faltar.
- **Teto de build maior**, de 45 para 90 minutos: o framework binário
  (`WebRTC-SDK`) é grande e o `pod install` pesa.
- **Apple ID grátis: 3 apps e 7 dias.** Continua valendo, e é o que amarra a
  consequência abaixo.

**Consequência prática para as fases:** como só dá para ter um .ipa instalado
por vez, o caminho JPEG **tem que continuar funcionando no mesmo binário**. Um
único sideload precisa entregar os dois caminhos, com escolha automática.

## Fases

### Fase 0 — Spikes (antes de qualquer compromisso)

| # | Pergunta | Como responder | Estado |
|---|---|---|---|
| S1 | O `flutter_webrtc` sideloada? | Diagnóstico embutido no app, build no Codemagic, sideload e rodar | **passou** ↓ |
| S2 | Quanto custa codificar H.264 no agente? | `openh264` sobre quadros capturados; medir ms/quadro e Mbps contra o JPEG de hoje | **feito** ↓ |
| S3 | O P2P fecha na rede real? | iPhone no 4G ↔ PC em casa; medir quantas vezes conecta sem TURN | pendente (parcial ↓) |

S1 era bloqueante e está resolvido: **o plano segue como está.** S3 pode correr
em paralelo com a implementação.

#### Resultado do S1

Rodado num iPhone, com `.ipa` não assinado gerado pelo Codemagic e instalado
pelo Sideloadly com Apple ID grátis. Os três testes passaram:

| Teste | Resultado |
| --- | --- |
| 1. O framework carrega | Conexão criada e fechada sem erro |
| 2. Duas conexões conversam | Ida e volta completa em **32 ms** |
| 3. O STUN enxerga o IP | IP externo obtido; 12 endereços locais |

Três leituras:

1. **A pergunta bloqueante está respondida.** O `flutter_webrtc` sobrevive ao
   sideload com Apple ID grátis, sem entitlement especial. Nenhuma decisão do
   plano precisa mudar.
2. **A pilha é rápida.** Os 32 ms são estabelecimento de conexão *mais* uma ida
   e volta, dentro do próprio aparelho — não é medida de rede. Mas mostra que
   ICE, DTLS e o canal de dados não são o gargalo, o que reforça antecipar a
   Fase 6 (entrada pelo canal de dados).
3. **O S3 só foi parcialmente respondido.** Obter um candidato *server
   reflexive* prova que o NAT do celular deixa descobrir o endereço externo —
   é necessário, mas não suficiente. Se o P2P fecha depende do par: o NAT do
   celular **e** o do computador. NAT simétrico ou CGNAT da operadora ainda
   podem forçar TURN. O teste iPhone ↔ PC continua valendo.

A tela de diagnóstico fica no app durante as Fases 1–3 — é útil para depurar —
e sai quando o vídeo por WebRTC estiver funcionando.

#### Como rodar o S1

O diagnóstico foi embutido no próprio RemoteOne, em **Configurações →
Diagnóstico → Testar WebRTC**, e não num app separado: com Apple ID grátis só
cabem 3 apps, e não vale gastar um slot com uma ferramenta temporária. Um
sideload entrega o app normal e o spike.

1. O Codemagic dispara sozinho ao receber um push nesta branch (o
   `codemagic.yaml` agora aceita `claude/*`, além de `main`).
2. Baixe o `.ipa` e instale pelo Sideloadly, como sempre.
3. Abra **Configurações → Diagnóstico → Testar WebRTC** e toque em *Rodar os
   testes*, com o celular na rede que você usa no dia a dia.

São três testes, do mais básico ao mais revelador:

| Teste | O que prova | Decide o spike? |
| --- | --- | --- |
| 1. O framework carrega | A biblioteca nativa subiu num app não assinado | **sim** |
| 2. Duas conexões conversam | ICE, criptografia e canal de dados funcionam no aparelho, sem rede nem servidor | **sim** |
| 3. O STUN enxerga seu IP | O IP externo é descobrível — pré-requisito do P2P | não (adianta parte do S3) |

Se os testes 1 e 2 passarem, o plano segue como está. Se o 1 falhar, o
`flutter_webrtc` não sobrevive ao sideload e o plano inteiro precisa ser
repensado — provavelmente mantendo o caminho JPEG e otimizando por outro lado.

**Riscos deste build**, que valem ser ditos antes: o framework nativo do WebRTC
(`WebRTC-SDK`) é grande, então o `.ipa` cresce e o build demora bem mais que o
de costume — daí o teto ter subido de 45 para 90 minutos. E se o build quebrar,
o app instalado hoje continua funcionando: só não haverá `.ipa` novo.

#### Resultado do S2

Medido com `cargo run --release --example bench_h264`, 1280×720 a 30 fps, 90
quadros por cenário, alvo de 1,5 Mbps, contra o JPEG q50 **com a deduplicação
que já está no ar**. O PSNR é medido decodificando os dois formatos de volta e
comparando com o original, para que a comparação de banda seja honesta.

| Cenário | Codec | ms/quadro | Mbps | PSNR dB |
| --- | --- | ---: | ---: | ---: |
| Parada + cursor | JPEG q50 | 30,7 | 16,38 | 39,7 |
| | **H.264** | **23,0** | **0,08** | **39,3** |
| Digitando | JPEG q50 | 31,1 | 16,40 | 39,7 |
| | **H.264** | **24,2** | **0,09** | **39,3** |
| Rolando | JPEG q50 | 30,4 | 21,33 | 38,4 |
| | **H.264** | **25,0** | **0,22** | **39,0** |
| Ruído (teto) | JPEG q50 | 34,0 | 41,90 | 25,2 |
| | H.264 (descartando) | 5,8 | 2,05 | 25,4 |
| | H.264 (sem descarte) | 49,3 | 26,28 | 25,4 |

Três conclusões:

1. **O ganho de banda é de duas ordens de grandeza, com a mesma qualidade.**
   97× a 213× menos tráfego em uso normal, e o PSNR fica empatado (na rolagem o
   H.264 é até melhor: 39,0 contra 38,4). Não é troca de qualidade por banda —
   é o JPEG desperdiçando por não ter quadro de diferença.
2. **A CPU melhora.** O H.264 custa 0,8× o JPEG, não mais. A preocupação de que
   codificar vídeo pesaria mais que codificar imagem estava errada.
3. **A política de descarte de quadros precisa ser decidida.** O padrão do
   openh264 é jogar quadros fora para caber no teto de banda: no cenário
   extremo ele entregou 7 de 90 quadros (~2 fps). Desligando o descarte, os 90
   quadros passam, mas a CPU dobra e a banda estoura o alvo. Para controle
   remoto, travar é pior que borrar — a inclinação é desligar o descarte e
   deixar o controle de congestionamento do WebRTC governar a taxa. Fica como
   decisão da Fase 2, agora com número em mãos.

**Ressalva importante:** os quadros são sintéticos e mais simples que uma tela
real (sem suavização de fontes, sem ícones, sem fotos), então os números do
H.264 estão otimistas. Para fechar essa lacuna há um par de exemplos que grava
e mede quadros reais **no Windows**:

```bash
cargo run --release --example capture_frames -- 90 quadros/   # mexa na tela
cargo run --release --example bench_h264 -- quadros/
```

A ordem de grandeza do ganho não deve mudar; os valores absolutos, sim.

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

1. ~~**`flutter_webrtc` + sideload**~~ — **resolvido no S1**: funciona num `.ipa`
   não assinado com Apple ID grátis, sem entitlement especial.
2. **Interoperar webrtc-rs ↔ libwebrtc** — costuma funcionar; verificar cedo.
3. ~~**Compilar o `openh264`**~~ — resolvido no S2: a crate compila a fonte
   embutida sem cmake nem nasm, em menos de um minuto. Falta confirmar no
   Windows.
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

Detalhe prático descoberto no S2: a crate tem duas formas de obter o codec —
`source` (compila a fonte junto, que é o que a medição usou) e `libloading`
(carrega em tempo de execução a biblioteca já compilada e distribuída pela
Cisco). É justamente a segunda que se encaixa no arranjo da Cisco. Se o
licenciamento virar um problema, trocar de uma para a outra é uma mudança
pequena — vale saber disso antes de escolher.

Não é conselho jurídico e eu não vou fingir que é. É um item para checar antes
de cobrar pelo produto — não antes de construí-lo. Se virar um problema, o
plano B é VP8, que é livre de royalties e custa bateria do iPhone.
