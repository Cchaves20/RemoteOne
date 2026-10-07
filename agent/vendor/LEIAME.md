# Bibliotecas corrigidas pelo Deskside

## webrtc-ice 0.17.2

Cópia da versão publicada, com **um** acréscimo: o repasse (TURN) por TCP.

Na versão publicada, a coleta de caminhos de repasse só conhece UDP. Uma URL
`turn:...?transport=tcp` é ignorada com o aviso "Unable to handle URL" — o
caso TCP está lá como `TODO`. Numa rede que bloqueia UDP para fora (Wi-Fi de
faculdade, de empresa, de hotel), o computador fica só com o endereço da rede
local, e o vídeo direto não fecha vindo de fora.

O que mudou, e é tudo:

- `src/agent/turn_tcp.rs` (novo): um `util::Conn` sobre `TcpStream` que
  remonta as mensagens STUN e ChannelData do fluxo (RFC 5766, §2.1 e §11.5).
  Tem testes, inclusive um de ponta a ponta com o servidor TURN do próprio
  webrtc-rs atrás de TCP.
- `src/agent/agent_gather.rs`: um ramo `ProtoType::Tcp` em
  `gather_candidates_relay`, que conecta por TCP e entrega essa conexão ao
  cliente TURN de sempre.
- `src/agent/mod.rs`: a declaração do módulo.
- `Cargo.toml`: sem o exemplo `ping_pong`, que não veio junto.

Ligada no `Cargo.toml` do agente por `[patch.crates-io]`.

**Para atualizar o webrtc-rs:** se a versão nova já trouxer TURN por TCP, apague
esta pasta e o `[patch]`. Se não, copie a versão nova para cá e reaplique os
três arquivos acima.

`test_udp_mux` falha nesta cópia também sem a mudança — é do ambiente de teste
(rede do contêiner), não do código.
