import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';
import '../models/remote_app.dart';
import '../models/system_stats.dart';
import '../services/app_state.dart';
import '../services/video_session.dart';
import '../theme.dart';
import '../widgets/remote_keyboard.dart';
import '../widgets/transitions.dart';
import 'gesture_tutorial_screen.dart';

/// Controle remoto por toque direto: a tela do computador ocupa a tela inteira
/// e o toque age como num touchscreen — tocar leva o cursor ao ponto e clica.
///
/// - Toque: move o cursor ao ponto + clique esquerdo
/// - Arrastar (1 dedo): o cursor segue o dedo
/// - Segurar: clique direito no ponto
/// - 2 dedos: rolar
/// - Botão de teclado: abre o teclado com teclas especiais
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with TickerProviderStateMixin {
  static const _scrollDivisor = 24.0;

  /// Tamanho do ícone e a espessura da dock (ícone + respiro).
  static const double _dockIcon = 42;
  static const double _dockThickness = _dockIcon + 8;

  /// Largura de uma medida no painel do computador. Fixa para que "Memória" e
  /// "Disco" caibam com o valor inteiro (`7,8 GB / 16,0 GB`) sem reticências.
  static const double _metricWidth = 150;

  /// Frame ao vivo, já decodificado. É um `ValueNotifier` de propósito: só o
  /// widget da imagem se reconstrói a cada frame, em vez da tela inteira
  /// (dock, botões, gestos) — o que economiza trabalho da CPU do celular e,
  /// com isso, latência.
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  /// Se já chegou algum frame (troca "aguardando" → "ao vivo" uma única vez).
  bool _hasFrame = false;

  /// Um frame de cada vez: se um novo chega enquanto o anterior é decodificado,
  /// o antigo é descartado. Melhor mostrar a imagem mais recente do que
  /// acumular uma fila e ficar para trás.
  bool _decoding = false;

  /// Tentativa de receber a tela por WebRTC. Enquanto ela não estiver ao vivo,
  /// o que aparece é o JPEG — que o agente continua mandando exatamente até o
  /// vídeo conectar. É esse encaixe que faz o fallback ser automático.
  VideoSession? _video;

  /// Avisa uma vez por sessão, não a cada mudança de estado.
  bool _videoFailureShown = false;

  double _aspectRatio = 16 / 9;
  bool _aspectResolved = false;
  String? _error;
  bool _keyboardVisible = false;

  double _pendingScroll = 0;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _flushTimer;

  int _frameCount = 0;
  int _fps = 0;
  Timer? _fpsTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;

  // Zoom (acessibilidade): em "modo lupa" os gestos ampliam/movem a tela; fora
  // dele, os gestos controlam o mouse. Como o GestureDetector fica DENTRO do
  // InteractiveViewer, o mapeamento do cursor continua correto mesmo ampliado.
  bool _zoomMode = false;
  final TransformationController _transform = TransformationController();
  Size _viewBox = Size.zero;

  // Dock de aplicativos, no estilo do macOS: uma barra flutuante sempre
  // visível sobre a tela, compacta (só ícones) e que se arrasta pela alça —
  // para cima/baixo quando está em pé, para os lados quando está deitada.
  late final AnimationController _dockAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  List<RemoteApp>? _dockApps;
  bool _dockLoading = false;
  /// Posição ao longo da borda, de -1 (topo/esquerda) a 1 (base/direita).
  double _dockPos = 0;

  // Painéis retráteis: as métricas do computador e o controle de mídia. Ficam
  // fechados, e cada um tem um botão só seu — o que está em jogo aqui é a tela
  // do computador, e tudo o que fica permanentemente em cima dela come área
  // útil. Abrir é uma decisão do usuário, para o momento em que ele quer.
  late final AnimationController _statsAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final AnimationController _mediaAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  /// As curvas vivem aqui, e não no `build`: criadas a cada quadro, cada uma
  /// deixaria um ouvinte no controlador até o coletor de lixo passar.
  late final Animation<double> _statsCurve = CurvedAnimation(
    parent: _statsAnim,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _mediaCurve = CurvedAnimation(
    parent: _mediaAnim,
    curve: Curves.easeOutCubic,
  );
  bool _statsOpen = false;
  bool _mediaOpen = false;
  SystemStats? _stats;
  bool _statsFailed = false;
  /// Um pedido de cada vez: numa rede lenta os pedidos de 2 em 2 s se
  /// empilhariam, e a resposta que chegasse por último venceria — que pode ser
  /// a mais velha.
  bool _statsInFlight = false;
  Timer? _statsTimer;

  /// O que está sendo digitado, para a barra de sugestões do teclado. Vive aqui
  /// porque quem move o cursor é esta tela, e mover o cursor invalida o rastro.
  final TypedWord _typedWord = TypedWord();

  @override
  void initState() {
    super.initState();
    // Mantém a tela do celular acesa durante a sessão de controle (#13).
    WakelockPlus.enable();
    _connect();
    _flushTimer =
        Timer.periodic(const Duration(milliseconds: 60), (_) => _flushScroll());
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _fps = _frameCount;
          _frameCount = 0;
        });
      }
    });
    // A dock de aplicativos carrega em segundo plano, sem travar a tela.
    _loadDockApps();
    // Na primeira vez que se controla um PC, mostra o tutorial de gestos (#20).
    if (!widget.state.gestureTutorialSeen) {
      widget.state.markGestureTutorialSeen();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          fadeThroughRoute(GestureTutorialScreen(state: widget.state)),
        );
      });
    }
  }

  void _connect() {
    _sub?.cancel();
    final q = widget.state.streamQuality;
    final channel = widget.state.api.connectScreen(
      widget.device.deviceId,
      fps: q.fps,
      quality: q.quality,
      maxWidth: q.maxWidth,
    );
    _channel = channel;

    // O mesmo socket carrega os frames JPEG (binário) e a sinalização de
    // WebRTC (texto). A sessão de vídeo é criada aqui e negocia em paralelo.
    _video?.dispose();
    _videoFailureShown = false;
    final video = widget.state.webrtcVideoEnabled
        ? (VideoSession(channel: channel)..addListener(_onVideoChanged))
        : null;
    _video = video;

    _sub = channel.stream.listen(
      (event) {
        if (!mounted) return;
        // Texto = sinalização de WebRTC.
        if (event is String) {
          video?.handleSignal(event);
          return;
        }
        if (event is! List<int>) return;
        final frame = event is Uint8List ? event : Uint8List.fromList(event);
        _frameCount++;
        _decodeFrame(frame);
      },
      onError: (Object _) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );

    // Só depois de o ouvinte estar no ar, senão a resposta do agente poderia
    // chegar antes de haver quem a tratasse.
    video?.start();
  }

  /// A sessão de vídeo mudou de estado: pode ser hora de trocar o que aparece.
  void _onVideoChanged() {
    final video = _video;
    if (!mounted || video == null) return;
    setState(() {
      if (video.isLive) {
        _hasFrame = true; // já há imagem, mesmo que nenhum JPEG tenha chegado
        _error = null;
        final ratio = video.aspectRatio;
        if (ratio != null && ratio > 0) {
          _aspectRatio = ratio;
          _aspectResolved = true;
        }
      }
    });

    // Falha no vídeo não pode ser silenciosa. A tela continua funcionando por
    // JPEG, então nada "quebra" visivelmente — e sem este aviso o motivo ficaria
    // só no log do aparelho, que num app instalado por sideload ninguém lê.
    if (video.state == VideoState.failed && !_videoFailureShown) {
      _videoFailureShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            '${widget.state.t.videoUnavailable}\n${video.error ?? ''}'.trim(),
          ),
        ),
      );
    }
  }

  /// Reconecta automaticamente se a conexão de tela cair (#12).
  void _scheduleReconnect() {
    if (_disposed) return;
    if (mounted) setState(() => _error = widget.state.t.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!_disposed) _connect();
    });
  }

  /// Decodifica o JPEG e publica o frame.
  ///
  /// Usa `decodeImageFromList` em vez de `Image.memory`: a imagem não passa
  /// pelo cache de imagens do Flutter, que trataria cada frame como uma
  /// imagem nova e encheria a memória em poucos segundos de transmissão.
  Future<void> _decodeFrame(Uint8List bytes) async {
    if (_decoding) return; // ainda desenhando o anterior: descarta este
    _decoding = true;
    try {
      final image = await decodeImageFromList(bytes);
      if (!mounted) {
        image.dispose();
        return;
      }
      final previous = _frame.value;
      _frame.value = image;
      // Libera o frame anterior só depois que o novo já foi ao ar.
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
      if (!_aspectResolved && image.height > 0) {
        _aspectResolved = true;
        setState(() => _aspectRatio = image.width / image.height);
      }
      if (!_hasFrame || _error != null) {
        setState(() {
          _hasFrame = true;
          _error = null;
        });
      }
    } catch (_) {
      // Frame corrompido (ex.: conexão instável): ignora e espera o próximo.
    } finally {
      _decoding = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _fpsTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _video?.removeListener(_onVideoChanged);
    _video?.dispose();
    _transform.dispose();
    _dockAnim.dispose();
    _statsTimer?.cancel();
    _statsAnim.dispose();
    _mediaAnim.dispose();
    _typedWord.dispose();
    // Guarda o vocabulário aprendido nesta sessão. Aqui, e não a cada palavra:
    // escrever no disco a cada tecla custaria caro e não adiantaria nada.
    widget.state.saveLearnedWords();
    _frame.value?.dispose();
    _frame.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // --- dock de aplicativos ----------------------------------------------------

  /// Carrega os aplicativos do computador em segundo plano. Se falhar (ex.:
  /// agente antigo), a dock simplesmente não aparece — sem atrapalhar o
  /// controle remoto.
  Future<void> _loadDockApps() async {
    if (_dockLoading) return;
    setState(() => _dockLoading = true);
    try {
      // Só os atalhos da área de trabalho: é o conjunto que a pessoa escolheu
      // deixar à mão, então a dock fica curta e útil.
      final apps = await widget.state.listApps(widget.device, kind: 'desktop');
      if (!mounted) return;
      setState(() => _dockApps = apps);
      if (apps.isNotEmpty) _dockAnim.forward();
    } catch (_) {
      // Silencioso: a tela de Aplicativos mostra o erro em detalhe.
    } finally {
      if (mounted) setState(() => _dockLoading = false);
    }
  }

  Future<void> _launchFromDock(RemoteApp app) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.of(context);
    final t = widget.state.t;
    try {
      await widget.state.launchApp(widget.device, app.id);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(t.appOpening(app.name)),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // --- métricas do computador e mídia -----------------------------------------

  /// Abre ou fecha o painel de métricas.
  ///
  /// A consulta só existe enquanto o painel está aberto: medir custa uma ida e
  /// volta ao computador, e ninguém deve pagar isso por um painel fechado.
  void _toggleStats() {
    HapticFeedback.selectionClick();
    setState(() => _statsOpen = !_statsOpen);
    if (_statsOpen) {
      _statsAnim.forward();
      _refreshStats();
      _statsTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _refreshStats(),
      );
    } else {
      _statsAnim.reverse();
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }

  Future<void> _refreshStats() async {
    if (_statsInFlight || !mounted) return;
    _statsInFlight = true;
    try {
      final stats = await widget.state.systemStats(widget.device);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _statsFailed = false;
      });
    } catch (_) {
      // Sem SnackBar: o painel pergunta a cada 2 s, e um erro de rede viraria
      // uma fila de avisos. O próprio painel mostra que não conseguiu.
      if (mounted) setState(() => _statsFailed = true);
    } finally {
      _statsInFlight = false;
    }
  }

  void _toggleMedia() {
    HapticFeedback.selectionClick();
    setState(() => _mediaOpen = !_mediaOpen);
    if (_mediaOpen) {
      _mediaAnim.forward();
    } else {
      _mediaAnim.reverse();
    }
  }

  Future<void> _media(String action) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.state.mediaKey(widget.device, action);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(e.toString()),
      ));
    }
  }

  // --- zoom (lupa) ------------------------------------------------------------

  // A transformação é uma escala uniforme + deslocamento. Lemos/escrevemos
  // direto no armazenamento (coluna-major): [0]=escala, [12]/[13]=deslocamento.
  double get _scale => _transform.value[0];

  /// Amplia/reduz em torno do centro da tela, preservando o deslocamento atual.
  void _zoomBy(double factor) {
    if (_viewBox == Size.zero) return;
    final current = _scale;
    final target = (current * factor).clamp(1.0, 5.0);
    final f = target / current;
    if ((f - 1).abs() < 0.001) return;

    final tx = _transform.value[12];
    final ty = _transform.value[13];
    final focalX = _viewBox.width / 2;
    final focalY = _viewBox.height / 2;
    // Mantém o ponto central fixo: t' = foco − f·(foco − t)...
    var ntx = focalX - f * (focalX - tx);
    var nty = focalY - f * (focalY - ty);
    // ...e reenquadra: no novo zoom a imagem tem que continuar cobrindo a tela
    // (em 1× o deslocamento vira 0, então ela volta ao lugar).
    final minTx = _viewBox.width * (1 - target);
    final minTy = _viewBox.height * (1 - target);
    ntx = ntx.clamp(minTx, 0.0);
    nty = nty.clamp(minTy, 0.0);
    final m = Matrix4.identity();
    m[0] = target;
    m[5] = target;
    m[12] = ntx;
    m[13] = nty;
    _transform.value = m;
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

  /// Desloca a visão ampliada (setas), com limite para não passar das bordas.
  /// Frações positivas revelam conteúdo à esquerda/acima.
  void _pan(double dxFraction, double dyFraction) {
    if (_viewBox == Size.zero) return;
    final s = _scale;
    if (s <= 1.0) return; // sem zoom, não há para onde mover
    // Deslocamento válido: t ∈ [dim·(1−s), 0] mantém a imagem cobrindo a tela.
    final minTx = _viewBox.width * (1 - s);
    final minTy = _viewBox.height * (1 - s);
    final m = _transform.value.clone();
    m[12] = (m[12] + _viewBox.width * dxFraction).clamp(minTx, 0.0);
    m[13] = (m[13] + _viewBox.height * dyFraction).clamp(minTy, 0.0);
    _transform.value = m;
  }

  void _toggleZoomMode() {
    setState(() => _zoomMode = !_zoomMode);
    // Enquanto ampliado, pede um vídeo de maior qualidade (mais detalhe onde
    // importa); ao sair, volta à qualidade escolhida (economiza banda).
    _setStreamBoost(_zoomMode);
    if (_zoomMode) {
      // Ao entrar no modo lupa, já amplia um pouco (ajuda quem não usa pinça).
      if (_scale < 1.05) _zoomBy(2.0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(widget.state.t.zoomHint),
        ),
      );
    }
  }

  /// Aumenta a resolução/qualidade do vídeo no modo lupa e restaura ao sair.
  Future<void> _setStreamBoost(bool boosted) async {
    final q = widget.state.streamQuality;
    try {
      await widget.state.api.startScreen(
        widget.device.deviceId,
        fps: q.fps,
        quality: boosted ? 85 : q.quality,
        maxWidth: boosted ? 1920 : q.maxWidth,
      );
    } catch (_) {
      // Sem rede/agente: mantém o que está; não é crítico.
    }
  }

  // --- envio de comandos ------------------------------------------------------

  /// Envia um comando de entrada pelo caminho mais curto disponível.
  ///
  /// Com a conexão P2P de pé, vai pelo canal de dados: **um salto direto** até o
  /// computador. Sem ela, cai no HTTP, que atravessa `celular → VPS → agente`.
  /// A ordem importa — entrada é a função principal do app e não pode depender
  /// de o vídeo ter dado certo.
  Future<void> _send(Map<String, dynamic> action) async {
    // Mexer no mouse leva o cursor para outro lugar: a palavra que o app achava
    // que estava sendo digitada deixa de corresponder ao que há na tela do
    // computador, e sugerir a partir dela seria sugerir sobre nada.
    final kind = action['kind'] as String?;
    if (kind != null && kind.startsWith('mouse')) _typedWord.reset();
    if (_video?.sendInput(action) == true) return;
    try {
      await widget.state.api.sendInput(widget.device.deviceId, action);
    } catch (_) {
      // Silencioso: comandos de controle são de alta frequência.
    }
  }

  ({double x, double y}) _norm(Offset local, Size box) => (
        x: (local.dx / box.width).clamp(0.0, 1.0),
        y: (local.dy / box.height).clamp(0.0, 1.0),
      );

  void _tapAt(Offset local, Size box) {
    HapticFeedback.selectionClick();
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    _send({'kind': 'mouse_click', 'button': 'left'});
  }

  void _rightClickAt(Offset local, Size box) {
    HapticFeedback.mediumImpact();
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    _send({'kind': 'mouse_click', 'button': 'right'});
  }

  void _moveTo(Offset local, Size box) {
    final now = DateTime.now();
    if (now.difference(_lastMove).inMilliseconds < 40) return;
    _lastMove = now;
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
  }

  void _flushScroll() {
    final steps = (_pendingScroll / _scrollDivisor).truncate();
    if (steps == 0) return;
    _pendingScroll -= steps * _scrollDivisor;
    _send({'kind': 'mouse_scroll', 'dy': -steps});
  }

  // --- UI ---------------------------------------------------------------------

  /// Dock flutuante de aplicativos, no estilo do macOS: sempre visível sobre a
  /// tela, compacta (só ícones) e móvel — arraste pela alça para deslocá-la ao
  /// longo da borda. Em pé quando o celular está na horizontal; deitada quando
  /// está na vertical.
  Widget _appDock({required bool vertical, required Size area}) {
    final apps = _dockApps ?? const <RemoteApp>[];
    if (apps.isEmpty) return const SizedBox.shrink();

    // Limita o comprimento a ~65% da tela: fica curta e não cobre demais.
    final maxLength = (vertical ? area.height : area.width) * 0.65;
    final curved = CurvedAnimation(parent: _dockAnim, curve: Curves.easeOutBack);

    final pill = Container(
      decoration: _glass(),
      padding: const EdgeInsets.all(6),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: vertical ? maxLength : double.infinity,
          maxWidth: vertical ? double.infinity : maxLength,
        ),
        child: vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                _dockGrip(vertical: true, area: area),
                Flexible(child: _dockList(apps, vertical: true)),
              ])
            : Row(mainAxisSize: MainAxisSize.min, children: [
                _dockGrip(vertical: false, area: area),
                Flexible(child: _dockList(apps, vertical: false)),
              ]),
      ),
    );

    return Align(
      // A posição ao longo da borda vem de _dockPos (-1 a 1); o Align já
      // mantém a dock dentro da área visível.
      alignment: vertical ? Alignment(1, _dockPos) : Alignment(_dockPos, 1),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ScaleTransition(
          scale: curved,
          child: FadeTransition(opacity: _dockAnim, child: pill),
        ),
      ),
    );
  }

  /// Vidro escuro translúcido: o material da dock, o único elemento que
  /// flutua sobre a tela do computador.
  BoxDecoration _glass() => BoxDecoration(
        color: const Color(0xE61A1D33),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withAlpha(30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(120),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      );

  /// Alça de arrastar. Fica só nela para não brigar com a rolagem da lista.
  Widget _dockGrip({required bool vertical, required Size area}) {
    return GestureDetector(
      onPanUpdate: (d) {
        // Converte o arrasto em deslocamento relativo à metade da área.
        final half = (vertical ? area.height : area.width) / 2;
        if (half <= 0) return;
        final delta = (vertical ? d.delta.dy : d.delta.dx) / half;
        setState(() => _dockPos = (_dockPos + delta).clamp(-1.0, 1.0));
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          vertical ? Icons.drag_handle : Icons.drag_indicator,
          size: 18,
          color: Colors.white38,
        ),
      ),
    );
  }

  /// Lista de ícones. O tamanho no eixo cruzado é fixo: sem isso a lista
  /// ocuparia todo o espaço disponível e esticaria os ícones.
  Widget _dockList(List<RemoteApp> apps, {required bool vertical}) {
    return SizedBox(
      width: vertical ? _dockThickness : null,
      height: vertical ? null : _dockThickness,
      child: ListView.builder(
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: apps.length,
        itemBuilder: (context, i) => _dockTile(apps[i]),
      ),
    );
  }

  /// Ícone do aplicativo: o ícone real do programa quando o computador
  /// conseguiu enviá-lo; senão, a inicial no gradiente da marca. O nome aparece
  /// ao segurar (tooltip), mantendo a dock compacta.
  Widget _dockTile(RemoteApp app) {
    final icon = app.iconBytes;
    final Widget content = icon != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              icon,
              width: _dockIcon,
              height: _dockIcon,
              fit: BoxFit.contain,
              // Os ícones vêm em 128px e são exibidos em ~42: a reamostragem
              // de melhor qualidade evita serrilhado.
              filterQuality: FilterQuality.high,
              // Ícone ilegível: cai para a inicial, sem quebrar a dock.
              errorBuilder: (_, __, ___) => _initialTile(app),
            ),
          )
        : _initialTile(app);

    return Padding(
      padding: const EdgeInsets.all(3),
      child: Tooltip(
        message: app.name,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _launchFromDock(app),
          // Center evita que a restrição justa do eixo cruzado da lista
          // estique o ícone (era o motivo das "barras" alongadas).
          child: Center(
            child: SizedBox(width: _dockIcon, height: _dockIcon, child: content),
          ),
        ),
      ),
    );
  }

  /// Alternativa quando não há ícone: inicial do nome no gradiente da marca.
  Widget _initialTile(RemoteApp app) {
    final initial =
        app.name.isEmpty ? '?' : app.name.substring(0, 1).toUpperCase();
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: auroraGradient,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
    );
  }

  // --- faixas retráteis (métricas e mídia) ------------------------------------

  /// Faixa das métricas do computador.
  ///
  /// `vertical` = coluna ao lado da imagem (celular deitado, onde a altura é
  /// escassa); horizontal = faixa sob a barra de cima (celular em pé, onde
  /// sobra altura). Nos dois casos ela **empurra** a imagem em vez de cobri-la.
  Widget _statsStrip({required bool vertical}) {
    return _strip(
      anim: _statsAnim,
      curved: _statsCurve,
      axis: vertical ? Axis.horizontal : Axis.vertical,
      // Sempre a partir da borda em que encosta: da esquerda quando é coluna,
      // de cima quando é faixa.
      from: vertical ? Alignment.centerLeft : Alignment.topCenter,
      border: vertical
          ? const Border(right: BorderSide(color: Colors.white12))
          : const Border(bottom: BorderSide(color: Colors.white12)),
      child: _statsCard(vertical: vertical),
    );
  }

  /// Faixa dos botões de mídia: no topo com o celular deitado, embaixo (acima
  /// do teclado) com ele em pé.
  Widget _mediaStrip({required bool atBottom}) {
    return _strip(
      anim: _mediaAnim,
      curved: _mediaCurve,
      axis: Axis.vertical,
      // Em pé ela nasce embaixo e sobe; deitada, nasce em cima e desce.
      from: atBottom ? Alignment.bottomCenter : Alignment.topCenter,
      border: const Border(
        top: BorderSide(color: Colors.white12),
        bottom: BorderSide(color: Colors.white12),
      ),
      child: _mediaCard(),
    );
  }

  /// Moldura comum das faixas: abre e fecha crescendo no próprio eixo, o que
  /// faz a imagem ceder espaço em vez de ficar coberta. Fechada, **não existe**
  /// na árvore — nem ocupa espaço, nem intercepta toque.
  ///
  /// O `SizeTransition` faria isto, mas o parâmetro que escolhe a borda de
  /// crescimento mudou de nome nas versões novas do Flutter: o antigo virou
  /// aviso aqui, e o novo não existiria no Flutter do Codemagic. `ClipRect` +
  /// `Align` é o que o próprio `SizeTransition` faz por dentro, com API que não
  /// mudou — e assim o efeito é o mesmo nas duas pontas.
  Widget _strip({
    required AnimationController anim,
    required Animation<double> curved,
    required Axis axis,
    required Alignment from,
    required Border border,
    required Widget child,
  }) {
    return AnimatedBuilder(
      animation: anim,
      child: child,
      builder: (context, inner) {
        if (anim.isDismissed) return const SizedBox.shrink();
        final fator = curved.value.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(
            alignment: from,
            heightFactor: axis == Axis.vertical ? fator : null,
            widthFactor: axis == Axis.horizontal ? fator : null,
            child: FadeTransition(
              opacity: curved,
              child: Container(
                // Mesma faixa escura da barra de cima: é parte da moldura do
                // app, não um cartão flutuando.
                decoration: BoxDecoration(
                  color: const Color(0xFF14162C),
                  border: border,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: inner,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Conteúdo do painel de métricas.
  ///
  /// `vertical` = uma coluna estreita (ao lado da imagem); horizontal = as
  /// medidas em `Wrap`, que vira duas colunas num celular e quatro num tablet
  /// — uma linha só de quatro cortaria "7,8 GB / 16,0 GB" com reticências.
  Widget _statsCard({required bool vertical}) {
    final t = widget.state.t;
    final stats = _stats;
    if (stats == null) {
      return SizedBox(
        width: vertical ? _metricWidth : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_statsFailed) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                _statsFailed ? t.systemUnavailable : '${t.systemPanel}…',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    final tiles = <Widget>[
      _metric(
        label: t.systemCpu,
        value: '${stats.cpuPercent.round()}%',
        fraction: stats.cpuPercent / 100,
        vertical: vertical,
      ),
      _metric(
        label: t.systemMemory,
        value: '${SystemStats.formatBytes(stats.memoryUsed)}'
            ' / ${SystemStats.formatBytes(stats.memoryTotal)}',
        fraction: stats.memoryFraction,
        vertical: vertical,
      ),
      _metric(
        label: stats.diskName.isEmpty
            ? t.systemDisk
            : '${t.systemDisk} ${stats.diskName}',
        value: '${SystemStats.formatBytes(stats.diskUsed)}'
            ' / ${SystemStats.formatBytes(stats.diskTotal)}',
        fraction: stats.diskFraction,
        vertical: vertical,
      ),
      _metric(
        label: t.systemUptime,
        value: stats.uptimeLabel(
          days: t.unitDay,
          hours: t.unitHour,
          minutes: t.unitMinute,
        ),
        fraction: null,
        vertical: vertical,
      ),
    ];

    final Widget medidas = vertical
        ? SizedBox(
            width: _metricWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: tiles,
            ),
          )
        : Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            runSpacing: 10,
            children: [
              for (final tile in tiles)
                SizedBox(width: _metricWidth, child: tile),
            ],
          );

    // Uma medida que falhou não apaga a última leitura boa: o painel segue
    // mostrando o que sabe, com o aviso embaixo.
    if (!_statsFailed) return medidas;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        medidas,
        const SizedBox(height: 6),
        Text(
          t.systemUnavailable,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }

  /// Uma medida: rótulo, valor e (quando faz sentido) a barra de proporção.
  Widget _metric({
    required String label,
    required String value,
    required double? fraction,
    required bool vertical,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: vertical ? 5 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (fraction != null) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.white12,
                // Vermelho quando aperta: a cor é a informação que se lê de
                // longe, antes de ler o número.
                valueColor: AlwaysStoppedAnimation(
                  fraction >= 0.9
                      ? const Color(0xFFEF5350)
                      : fraction >= 0.7
                          ? const Color(0xFFFFB74D)
                          : auroraCyan,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Botões de mídia. As teclas são globais no computador: valem para quem
  /// estiver tocando som, sem precisar deixar o player em foco.
  Widget _mediaCard() {
    final t = widget.state.t;
    return Row(
      // A faixa ocupa a largura toda; os botões ficam centrados nela.
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _mediaButton(Icons.volume_down, t.mediaVolumeDown, 'volume_down'),
        _mediaButton(Icons.volume_off, t.mediaMute, 'mute'),
        _mediaButton(Icons.skip_previous, t.mediaPrevious, 'previous'),
        _mediaButton(Icons.play_arrow, t.mediaPlayPause, 'play_pause',
            big: true),
        _mediaButton(Icons.skip_next, t.mediaNext, 'next'),
        _mediaButton(Icons.volume_up, t.mediaVolumeUp, 'volume_up'),
      ],
    );
  }

  Widget _mediaButton(
    IconData icon,
    String tooltip,
    String action, {
    bool big = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        // Toque generoso: são botões que se aperta sem olhar.
        iconSize: big ? 34 : 26,
        constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
        padding: EdgeInsets.zero,
        color: Colors.white,
        icon: Icon(icon),
        onPressed: () => _media(action),
      ),
    );
  }

  /// Seta de deslocamento posicionada numa borda (só no modo lupa).
  Widget _panArrow(Alignment alignment, IconData icon, VoidCallback onTap) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: IconButton(
            iconSize: 32,
            icon: Icon(icon, color: Colors.white),
            onPressed: onTap,
          ),
        ),
      ),
    );
  }

  /// Alterna entre "aguardando" e a tela ao vivo com um fade suave. As chaves
  /// são estáveis, então a animação ocorre só na troca de estado — não a cada
  /// frame recebido.
  Widget _liveView() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: !_hasFrame
          ? _waitingView(const ValueKey('waiting'))
          : _screenView(const ValueKey('live')),
    );
  }

  Widget _waitingView(Key key) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          _error ?? widget.state.t.waitingScreen,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }

  Widget _screenView(Key key) {
    return Center(
      key: key,
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: Container(
          // Borda visível delimitando a tela do computador (A1).
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final box = Size(constraints.maxWidth, constraints.maxHeight);
              _viewBox = box;
              // A imagem é a única folha que troca: vídeo por WebRTC quando ele
              // está ao vivo, JPEG no resto do tempo. Tudo em volta (zoom,
              // gestos, dock, mapeamento do cursor) fica igual nos dois casos —
              // é por isso que a substituição acontece só aqui.
              final video = _video;
              final Widget image = video != null && video.isLive
                  ? RTCVideoView(
                      video.renderer,
                      // `contain`, e não `cover`: o AspectRatio acima já usa a
                      // proporção do próprio vídeo, então as duas coincidem e a
                      // imagem preenche a caixa exatamente. Se houver
                      // descasamento momentâneo (antes de o tamanho do vídeo ser
                      // conhecido), `contain` mostra o quadro inteiro em vez de
                      // cortar — cortar esconderia parte da área de trabalho e
                      // faria o toque apontar para pixels invisíveis.
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      filterQuality: FilterQuality.medium,
                    )
                  : ValueListenableBuilder<ui.Image?>(
                      // Só esta folha se reconstrói quando chega um frame novo.
                      valueListenable: _frame,
                      builder: (context, frame, _) {
                        if (frame == null) return const SizedBox.expand();
                        return RawImage(
                          image: frame,
                          fit: BoxFit.fill,
                          // Suaviza quando ampliada (menos "quadradinhos").
                          filterQuality: FilterQuality.medium,
                        );
                      },
                    );

              // Modo lupa: o InteractiveViewer amplia/move (pinça e botões +/−),
              // e as setas nas bordas deslocam a visão sem precisar arrastar.
              if (_zoomMode) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: 1.0,
                        maxScale: 5.0,
                        child: image,
                      ),
                    ),
                    _panArrow(Alignment.centerLeft, Icons.chevron_left,
                        () => _pan(0.30, 0)),
                    _panArrow(Alignment.centerRight, Icons.chevron_right,
                        () => _pan(-0.30, 0)),
                    _panArrow(Alignment.topCenter, Icons.expand_less,
                        () => _pan(0, 0.30)),
                    _panArrow(Alignment.bottomCenter, Icons.expand_more,
                        () => _pan(0, -0.30)),
                  ],
                );
              }

              // Modo controle: aplica a mesma transformação de forma estática
              // (Transform) e deixa o GestureDetector receber os toques. Como o
              // detector fica DENTRO do Transform, o toque chega em coordenadas
              // da imagem — o zoom não distorce o mapeamento do cursor.
              // Escuta o controlador de zoom em vez de depender de um
              // `setState` da tela: fora do modo lupa nada mais redesenha.
              return ClipRect(
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _transform,
                  builder: (context, matrix, child) => Transform(
                    transform: matrix,
                    transformHitTests: true,
                    child: child,
                  ),
                  child: GestureDetector(
                    onTapUp: (d) => _tapAt(d.localPosition, box),
                    onLongPressStart: (d) => _rightClickAt(d.localPosition, box),
                    onScaleUpdate: (d) {
                      if (d.pointerCount >= 2) {
                        _pendingScroll += d.focalPointDelta.dy;
                      } else {
                        _moveTo(d.localFocalPoint, box);
                      }
                    },
                    child: image,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    // Na vertical, o teclado aparece automaticamente (modo digitação); na
    // horizontal, é opcional (mais tela). Layout em Column: a barra de
    // controles e o teclado ficam FORA da imagem, sem cobri-la.
    final showKeyboard = isPortrait || _keyboardVisible;
    // A dock continua flutuando sobre a imagem (é o comportamento de dock, e
    // ela é estreita); os painéis, não. Eles ocupam espaço próprio e empurram
    // a imagem, do mesmo jeito que o teclado — assim nada fica por cima da
    // tela do computador, que é o que a pessoa veio olhar.
    final Widget viewArea = LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          // expand é essencial: sem ele o Stack se dimensiona pelo filho não
          // posicionado (a dock) e, quando ela está vazia, a tela inteira
          // encolheria para um ponto.
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _liveView()),
            // No modo lupa a dock sai da frente, para não atrapalhar quem
            // está ampliando a imagem.
            if (!_zoomMode) _appDock(vertical: !isPortrait, area: area),
          ],
        );
      },
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(showToggle: !isPortrait),
            // Deitado, as métricas viram uma coluna ao lado da imagem: a tela
            // é baixa e uma faixa horizontal comeria altura demais. Em pé, o
            // contrário — sobra altura, e a faixa fica no topo.
            if (isPortrait) _statsStrip(vertical: false),
            if (!isPortrait) _mediaStrip(atBottom: false),
            Expanded(
              child: isPortrait
                  ? viewArea
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _statsStrip(vertical: true),
                        Expanded(child: viewArea),
                      ],
                    ),
            ),
            if (isPortrait) _mediaStrip(atBottom: true),
            if (showKeyboard)
              RemoteKeyboard(
                onText: (text) => _send({'kind': 'key_text', 'text': text}),
                onKey: (key) => _send({'kind': 'key_press', 'key': key}),
                onCombo: (mods, key) =>
                    _send({'kind': 'key_combo', 'modifiers': mods, 'key': key}),
                onReplace: (backspaces, text) => _send({
                  'kind': 'key_replace',
                  'backspaces': backspaces,
                  'text': text,
                }),
                typed: _typedWord,
                suggester: widget.state.suggestionsEnabled
                    ? widget.state.wordSuggester
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  /// Botão da barra de cima que abre/fecha um painel. Aceso quando aberto —
  /// é o que diz de onde veio a faixa que apareceu.
  Widget _barToggle({
    required IconData icon,
    required bool open,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      // Compacto: a barra já carrega voltar, nome, indicador, lupa e teclado.
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: open ? auroraCyan : Colors.white),
      onPressed: onPressed,
    );
  }

  Widget _topBar({required bool showToggle}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      // Faixa escura com um leve brilho da marca, separando a barra da tela.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF14162C), Colors.black],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              widget.device.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_zoomMode) ...[
            IconButton(
              tooltip: widget.state.t.zoomOut,
              icon: const Icon(Icons.remove_circle_outline, color: Colors.white),
              onPressed: () => _zoomBy(1 / 1.4),
            ),
            IconButton(
              tooltip: widget.state.t.zoomIn,
              icon: const Icon(Icons.add_circle_outline, color: Colors.white),
              onPressed: () => _zoomBy(1.4),
            ),
            IconButton(
              tooltip: widget.state.t.zoomFit,
              icon: const Icon(Icons.fit_screen, color: Colors.white),
              onPressed: _resetZoom,
            ),
            IconButton(
              tooltip: widget.state.t.zoomExit,
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: _toggleZoomMode,
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                // No vídeo por WebRTC não chegam frames JPEG, então o contador
                // fica em 0 por definição — mostrar "0 fps" pareceria defeito.
                _video?.isLive == true
                    ? (_video?.inputReady == true
                        ? widget.state.t.videoDirectMode
                        : widget.state.t.videoMode)
                    // 0 fps com a imagem no ar significa tela parada: o agente
                    // deixa de enviar frames idênticos para poupar rede/bateria.
                    : (_fps == 0 && _hasFrame
                        ? widget.state.t.screenStill
                        : '$_fps fps'),
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
            // Os dois painéis retráteis moram aqui, na moldura do app: fora
            // da imagem do computador, que é o que a pessoa veio olhar.
            _barToggle(
              icon: Icons.memory,
              open: _statsOpen,
              tooltip: widget.state.t.systemPanel,
              onPressed: _toggleStats,
            ),
            _barToggle(
              icon: Icons.music_note,
              open: _mediaOpen,
              tooltip: widget.state.t.mediaPanel,
              onPressed: _toggleMedia,
            ),
            IconButton(
              tooltip: widget.state.t.zoomEnter,
              icon: const Icon(Icons.zoom_in, color: Colors.white),
              onPressed: _toggleZoomMode,
            ),
            if (showToggle)
              IconButton(
                icon: Icon(
                  _keyboardVisible ? Icons.keyboard_hide : Icons.keyboard,
                  color: Colors.white,
                ),
                onPressed: () =>
                    setState(() => _keyboardVisible = !_keyboardVisible),
              ),
          ],
        ],
      ),
    );
  }
}
