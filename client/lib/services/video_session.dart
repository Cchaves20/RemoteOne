// Recepção de vídeo por WebRTC (Fase 3 do docs/webrtc-plano.md).
//
// Vive fora da tela de controle de propósito: a negociação tem estado próprio
// (oferta, resposta, candidatos, conexão) e a tela já carrega gestos, zoom e a
// dock. Aqui só se cuida de uma coisa.
//
// O papel do app é **receber**: ele monta a oferta com um transceptor
// `recvonly`, e o agente responde. Toda a sinalização sai e entra pelo mesmo
// WebSocket que já trazia os frames JPEG — nenhum canal novo.
//
// O fallback (Fase 4) cai naturalmente do desenho do agente: ele só para de
// mandar JPEG enquanto existe uma sessão de WebRTC **conectada**. Então basta
// esta classe informar honestamente seu estado, e a tela decide o que mostrar.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Em que ponto está a tentativa de receber vídeo.
enum VideoState {
  /// Nem começou (desligado nas configurações, por exemplo).
  idle,

  /// Oferta enviada, esperando a resposta e os candidatos.
  negotiating,

  /// Vídeo chegando. É o único estado em que vale mostrar o `RTCVideoView`.
  live,

  /// Não deu — segue no JPEG. `error` conta o porquê.
  failed,
}

/// Uma tentativa de receber a tela por WebRTC.
///
/// Uso: [start] uma vez, [handleSignal] para cada mensagem de texto que chegar
/// no WebSocket, e [dispose] ao sair. Ouça via [ChangeNotifier] para saber
/// quando trocar o que está na tela.
class VideoSession extends ChangeNotifier {
  VideoSession({
    required this.channel,
    this.withAudio = false,
    List<Map<String, dynamic>>? iceServers,
  }) : iceServers = iceServers ?? _defaultIceServers;

  /// O mesmo WebSocket que traz os frames JPEG.
  final WebSocketChannel channel;

  /// Se a oferta pede uma faixa de som além da tela.
  ///
  /// Desligado por padrão, e é uma decisão sobre risco: quem abre o app quer
  /// **ver** o computador. Uma faixa a mais na negociação é uma coisa a mais
  /// que pode falhar do lado do aparelho — e falhou: pedir som em toda sessão
  /// derrubou o vídeo inteiro para o JPEG. Sem som pedido, a oferta é igual à
  /// que sempre funcionou; com som, a sessão é renegociada na hora em que a
  /// pessoa liga.
  final bool withAudio;

  /// STUN e, quando o servidor tem, TURN com credencial temporária. O TURN é
  /// o que faz o vídeo direto fechar quando os dois lados estão atrás de NAT
  /// que não deixa nada entrar (celular no 5G, computador atrás do roteador).
  final List<Map<String, dynamic>> iceServers;

  static const _defaultIceServers = <Map<String, dynamic>>[
    {'urls': 'stun:stun.l.google.com:19302'},
  ];

  /// Precisa casar com `INPUT_CHANNEL` no agente.
  static const _inputChannel = 'input';

  /// Quanto se espera pela negociação antes de desistir e ficar no JPEG.
  ///
  /// O S1 mostrou a pilha fechando em 32 ms dentro do aparelho; pela rede é
  /// bem mais, mas 20 s é folga larga para qualquer caminho que ainda vá dar
  /// certo. Passar disso é sinal de que não vai.
  static const _negotiationTimeout = Duration(seconds: 20);

  /// Quanto se espera por um quadro **desenhado** depois de a **conexão** ficar
  /// de pé.
  ///
  /// Existe por causa de uma falha real: a conexão fecha, a faixa chega e a
  /// tela fica **preta** — sem um quadro-chave o decodificador não tem por onde
  /// começar. "Recebeu a faixa" não é o mesmo que "está mostrando imagem", e só
  /// o segundo justifica abandonar o JPEG.
  ///
  /// O prazo conta a partir da conexão, e não da chegada da faixa, porque a
  /// faixa aparece quando a resposta é aplicada — **antes** de existir caminho
  /// até o computador. Contando do momento errado, o prazo estourava enquanto o
  /// ICE ainda estava fechando, e matava uma sessão que ia funcionar: era o
  /// "vídeo direto falhou" com o ICE em `Connected` na mensagem.
  static const _firstFrameTimeout = Duration(seconds: 8);

  VideoState state = VideoState.idle;
  String? error;

  /// O renderizador com o vídeo, pronto para o `RTCVideoView`. Só é válido
  /// quando [state] é [VideoState.live].
  final RTCVideoRenderer renderer = RTCVideoRenderer();

  /// Proporção do vídeo recebido, quando o renderizador já a conhece.
  double? aspectRatio;

  /// Canal de dados para mouse e teclado (Fase 6).
  ///
  /// Aberto com `ordered: false` e retransmissão ligada — cada metade resolve
  /// um problema: sem ordenação, um pacote perdido não segura o que vem atrás
  /// (um movimento perdido travaria o clique seguinte); com retransmissão,
  /// porque perder um clique é inaceitável. O número de sequência deixa o
  /// agente descartar movimentos que cheguem fora de ordem.
  RTCDataChannel? _input;
  int _seq = 0;

  /// Se dá para enviar entrada pelo caminho direto agora.
  bool get inputReady =>
      _input?.state == RTCDataChannelState.RTCDataChannelOpen;

  RTCPeerConnection? _peer;
  Timer? _timeout;
  bool _disposed = false;
  bool _rendererReady = false;

  /// Candidatos que chegaram antes de a resposta ser aplicada.
  ///
  /// A ordem não é garantida: o agente começa a emitir candidatos ao aplicar a
  /// descrição local, o que acontece **antes** de a resposta ser despachada.
  /// E `addCandidate` antes de `setRemoteDescription` falha. Então tudo que
  /// chega cedo espera aqui e entra de uma vez.
  final List<RTCIceCandidate> _pendingCandidates = [];

  /// Se a resposta do agente já foi aplicada (aí sim dá para adicionar
  /// candidatos). Só vira `true` quando o `await` termina, não antes.
  bool _remoteReady = false;

  bool get isLive => state == VideoState.live;

  /// Em que pé está o ICE (a busca por um caminho até o computador), e
  /// quantos candidatos cada lado ofereceu.
  ///
  /// É o que separa as duas falhas que parecem iguais na tela: "não achei
  /// caminho" (candidatos existem, nenhum par fecha - rede hostil, precisa de
  /// TURN) e "não tenho por onde tentar" (nenhum candidato local, tipicamente
  /// o iOS bloqueando a rede local).
  String _iceState = 'novo';
  final Map<String, int> _localCandidates = {};
  final Map<String, int> _remoteCandidates = {};

  /// Conta um candidato pelo **tipo**, que é o que diz de onde ele veio:
  /// `host` é um endereço da própria rede, `srflx` é o que o STUN descobriu
  /// (o IP público), `relay` é um TURN. A soma não basta: 27 candidatos que
  /// não fecham não dizem nada, mas "os dois lados têm host e mesmo assim não
  /// fecha" aponta para bloqueio (firewall ou permissão), enquanto "só srflx
  /// dos dois lados" aponta para redes diferentes, que é onde TURN entra.
  static void _count(Map<String, int> onde, String? candidato) {
    if (candidato == null || candidato.isEmpty) return;
    final tipo = RegExp(r'typ (\w+)').firstMatch(candidato)?.group(1) ?? '?';
    onde[tipo] = (onde[tipo] ?? 0) + 1;
  }

  static String _describe(Map<String, int> onde) => onde.isEmpty
      ? 'nenhum'
      : onde.entries.map((e) => '${e.value} ${e.key}').join(' + ');

  /// Resumo do ICE para as mensagens de erro.
  String get iceSummary => 'ICE $_iceState; celular: ${_describe(_localCandidates)}; '
      'computador: ${_describe(_remoteCandidates)}';

  /// Se a conexão ainda existe. Falhar por falta de imagem **não** a derruba,
  /// e o som continua indo por ela.
  bool get peerAlive => _peer != null;

  /// Se a faixa de som do computador chegou de verdade.
  ///
  /// Diferente de "o usuário ligou o som": o app pede pelo servidor, e a faixa
  /// vem pela conexão direta. Quando um dos dois lados está desatualizado, o
  /// pedido dá certo e a faixa nunca chega — e sem este sinal isso apareceria
  /// como um botão aceso e silêncio.
  bool audioLive = false;

  /// Negocia a sessão: cria a conexão, manda a oferta e espera.
  Future<void> start() async {
    if (state != VideoState.idle) return;
    _set(VideoState.negotiating);
    _timeout = Timer(_negotiationTimeout, () {
      _fail(
        'a negociação não fechou em ${_negotiationTimeout.inSeconds}s — '
        '$iceSummary',
      );
    });

    try {
      await renderer.initialize();
      _rendererReady = true;

      final peer = await createPeerConnection(<String, dynamic>{
        'iceServers': iceServers,
      });
      _peer = peer;

      // O canal de dados nasce **antes** da oferta, de propósito: assim ele
      // entra no SDP e o agente o recebe sem precisar renegociar a sessão.
      final init = RTCDataChannelInit()..ordered = false;
      _input = await peer.createDataChannel(_inputChannel, init);

      // Só receber: o celular não manda vídeo nenhum.
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.RecvOnly,
        ),
      );

      // Faixa de som — só quando alguém pediu. Uma faixa não pode ser
      // acrescentada a uma sessão já negociada, então ligar o som refaz a
      // sessão (é o que a tela de controle manda fazer).
      //
      // Em bloco próprio porque **o som não pode derrubar a tela**. Ver o
      // computador é a função do app; ouvi-lo é um extra. Se esta parte
      // falhar — ou demorar —, a sessão segue só com vídeo, em vez de a
      // imagem cair no JPEG por causa do áudio.
      if (withAudio) {
        try {
          // O modo da sessão vem **antes** da faixa: o módulo de áudio do
          // sistema nasce quando a faixa aparece, e nasce no modo que
          // encontrar. Se encontrar o padrão do WebRTC (ligação telefônica),
          // ele pede o microfone — que este app não usa e pode nem ter
          // permissão para usar.
          //
          // Com prazo, porque isto fala com o sistema operacional: um ajuste
          // de aparelho que não responde não pode segurar a oferta.
          await _prepareAudioOutput().timeout(const Duration(seconds: 2));
          await peer
              .addTransceiver(
                kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
                init: RTCRtpTransceiverInit(
                  direction: TransceiverDirection.RecvOnly,
                ),
              )
              .timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('Deskside: sessão sem faixa de som — $e');
        }
      }

      // O único sinal que autoriza abandonar o JPEG: um quadro efetivamente
      // desenhado. Chegar a faixa não basta.
      renderer.onFirstFrameRendered = () {
        _timeout?.cancel();
        // Vale inclusive vindo de `failed`: a sessão pode ter sido marcada
        // assim por falta de imagem e se recuperado depois, com o quadro-chave
        // que o telefone pediu. Chegou imagem, está ao vivo.
        error = null;
        if (state != VideoState.live) _set(VideoState.live);
      };

      peer.onTrack = (event) {
        if (event.streams.isEmpty) return;
        if (event.track.kind == 'audio') {
          audioLive = true;
          if (!_disposed) notifyListeners();
          // Som toca sozinho, sem renderizador. O que ele precisa é sair pelo
          // alto-falante: sem isto o iPhone toca no alto-falante de encostar
          // no ouvido, porque o WebRTC nasce pensando em ligação telefônica.
          // Também não pode reiniciar o prazo do primeiro quadro abaixo - a
          // espera é por imagem, e a faixa de som chegaria antes.
          // Sem `await`: preparar a saída de som é ajuste de aparelho, e o
          // que este retorno protege é o prazo do primeiro quadro de vídeo,
          // logo abaixo. Nada aqui pode ficar no caminho da imagem.
          unawaited(_prepareAudioOutput());
          return;
        }
        // A faixa chegou; o prazo de desenhar começa quando a **conexão**
        // fechar (em `onConnectionState`), não aqui.
        renderer.srcObject = event.streams.first;
      };

      peer.onIceConnectionState = (estado) {
        // O nome do enum já é o suficiente: o que importa aqui é onde parou.
        _iceState = estado.name.replaceFirst('RTCIceConnectionState', '');
      };

      peer.onIceCandidate = (candidate) {
        _count(_localCandidates, candidate.candidate);
        _send({
          'type': 'webrtc_ice',
          // Candidato vazio é o "acabaram os meus" e precisa ser enviado:
          // sem ele a outra ponta fica esperando.
          'candidate': candidate.candidate ?? '',
          'sdp_mid': candidate.sdpMid,
          'sdp_mline_index': candidate.sdpMLineIndex,
        });
      };

      peer.onConnectionState = (peerState) {
        switch (peerState) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            // Daqui em diante a mídia pode fluir de verdade. É o momento certo
            // para cobrar um quadro desenhado.
            _timeout?.cancel();
            _timeout = Timer(_firstFrameTimeout, _semImagem);
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _fail('a conexão de vídeo falhou — $iceSummary');
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            // Fechamento pedido por nós não é falha.
            if (state == VideoState.negotiating) {
              _fail('a conexão de vídeo fechou antes de completar');
            }
          default:
            break;
        }
      };

      renderer.onResize = () {
        final width = renderer.videoWidth;
        final height = renderer.videoHeight;
        if (width > 0 && height > 0) {
          aspectRatio = width / height;
          if (!_disposed) notifyListeners();
        }
      };

      final offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      _send({'type': 'webrtc_offer', 'sdp': offer.sdp});
    } catch (e) {
      _fail('$e');
    }
  }

  /// Prepara o aparelho para **só ouvir**.
  ///
  /// Sem isto o iPhone fica calado, e o motivo é o padrão do WebRTC: ele
  /// assume ligação telefônica e põe a sessão de áudio em `playAndRecord` com
  /// modo de voz. Isso liga o microfone (permissão que este app nunca pede),
  /// joga a saída no alto-falante de encostar no ouvido, usa o volume de
  /// chamada — que o botão lateral controla à parte — e trata música como voz.
  ///
  /// `remoteOnly` diz o que é verdade aqui: o som só chega, nunca sai. A
  /// sessão vira `playback`, que sai pelo alto-falante de música, com o volume
  /// de mídia e sem processamento nenhum.
  Future<void> _prepareAudioOutput() async {
    try {
      await Helper.setAppleAudioIOMode(AppleAudioIOMode.remoteOnly);
    } catch (e) {
      // Em plataformas sem sessão de áudio da Apple isto não existe, e o som
      // já sai pela saída padrão: não é motivo para derrubar o vídeo.
      debugPrint('Deskside: saída de áudio padrão — $e');
    }
  }

  /// Envia uma ação de entrada pelo caminho direto.
  ///
  /// Devolve `false` se o canal não está pronto — e nesse caso quem chamou
  /// **precisa** usar o caminho antigo (HTTP). Entrada é a função principal do
  /// app: ela não pode depender de o vídeo ter dado certo.
  bool sendInput(Map<String, dynamic> action) {
    final channel = _input;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    try {
      channel.send(RTCDataChannelMessage(
        jsonEncode({'seq': ++_seq, 'action': action}),
      ));
      return true;
    } catch (e) {
      debugPrint('Deskside: falha ao enviar entrada pelo canal — $e');
      return false;
    }
  }

  /// Trata uma mensagem de texto do WebSocket. Devolve `false` se não era
  /// sinalização — nesse caso quem chamou decide o que fazer com ela.
  bool handleSignal(String raw) {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      message = decoded;
    } catch (_) {
      return false;
    }

    switch (message['type']) {
      case 'webrtc_answer':
        _applyAnswer(message['sdp'] as String?);
        return true;
      case 'webrtc_ice':
        _applyCandidate(message);
        return true;
      case 'error':
        // Erro do backend no meio da negociação (ex.: computador desconectou).
        if (state == VideoState.negotiating) {
          _fail('${message['message'] ?? 'erro do servidor'}');
        }
        return true;
      default:
        return false;
    }
  }

  Future<void> _applyAnswer(String? sdp) async {
    final peer = _peer;
    if (peer == null || sdp == null) return;
    try {
      await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteReady = true;
      // Agora os candidatos que chegaram adiantados podem entrar.
      final queued = List<RTCIceCandidate>.from(_pendingCandidates);
      _pendingCandidates.clear();
      for (final candidate in queued) {
        await _addCandidate(peer, candidate);
      }
    } catch (e) {
      _fail('resposta do computador recusada: $e');
    }
  }

  Future<void> _applyCandidate(Map<String, dynamic> message) async {
    final peer = _peer;
    if (peer == null) return;
    final candidate = message['candidate'] as String? ?? '';
    // Candidato vazio significa que o outro lado terminou: nada a adicionar.
    if (candidate.isEmpty) return;
    final ice = RTCIceCandidate(
      candidate,
      message['sdp_mid'] as String?,
      message['sdp_mline_index'] as int?,
    );
    if (!_remoteReady) {
      _pendingCandidates.add(ice);
      return;
    }
    await _addCandidate(peer, ice);
  }

  Future<void> _addCandidate(
      RTCPeerConnection peer, RTCIceCandidate candidate) async {
    try {
      await peer.addCandidate(candidate);
      _count(_remoteCandidates, candidate.candidate);
    } catch (e) {
      // Um candidato recusado não derruba a sessão — o ICE tenta os outros —
      // mas engolir isso em silêncio esconderia justamente o tipo de problema
      // que faz a conexão nunca fechar.
      debugPrint('Deskside: candidato ICE recusado — $e');
    }
  }

  void _send(Map<String, dynamic> message) {
    if (_disposed) return;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (_) {
      // Socket já caiu; o estado de falha vem pelo caminho da conexão.
    }
  }

  /// A conexão fechou e mesmo assim nenhum quadro apareceu.
  ///
  /// **Não derruba a conexão.** Ela está de pé, o som (se ligado) está indo por
  /// ela, e o decodificador pode se recuperar sozinho — o telefone pede um
  /// quadro-chave por RTCP, e o computador agora atende esse pedido. O que se
  /// faz aqui é continuar mostrando o JPEG e dizer o motivo; se a imagem
  /// aparecer depois, `onFirstFrameRendered` promove a sessão a "ao vivo".
  void _semImagem() {
    if (_disposed || state == VideoState.live) return;
    error = 'a conexão fechou mas nenhum quadro foi desenhado em '
        '${_firstFrameTimeout.inSeconds}s — $iceSummary';
    debugPrint('Deskside: sem imagem pelo WebRTC — $error');
    _set(VideoState.failed);
  }

  void _fail(String reason) {
    if (_disposed || state == VideoState.failed) return;
    error = reason;
    // Sem isso o motivo se perde: o usuário só veria a tela seguir em JPEG,
    // sem pista nenhuma de por que o vídeo não entrou.
    debugPrint('Deskside: vídeo por WebRTC indisponível — $reason');
    _timeout?.cancel();
    _set(VideoState.failed);
    // Solta a conexão, mas mantém o renderizador: a tela pode estar no meio de
    // um quadro, e destruí-lo aqui arriscaria pintar em cima de nada.
    _peer?.close();
    _peer = null;
  }

  void _set(VideoState next) {
    state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timeout?.cancel();
    _input?.close();
    _input = null;
    _peer?.close();
    _peer = null;
    if (_rendererReady) {
      renderer.srcObject = null;
      renderer.dispose();
    }
    super.dispose();
  }
}
