import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';
import '../models/remote_app.dart';
import '../services/app_state.dart';
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
    with SingleTickerProviderStateMixin {
  static const _scrollDivisor = 24.0;

  Uint8List? _frame;
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
    _sub = channel.stream.listen(
      (event) {
        if (event is! List<int>) return; // ignora mensagens de texto
        final frame =
            event is Uint8List ? event : Uint8List.fromList(event);
        if (!mounted) return;
        _frameCount++;
        setState(() {
          _frame = frame;
          _error = null;
        });
        _resolveAspect(frame);
      },
      onError: (Object _) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
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

  void _resolveAspect(Uint8List bytes) {
    if (_aspectResolved) return;
    _aspectResolved = true;
    ui.decodeImageFromList(bytes, (image) {
      if (mounted && image.height > 0) {
        setState(() => _aspectRatio = image.width / image.height);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _fpsTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _transform.dispose();
    _dockAnim.dispose();
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

  Future<void> _send(Map<String, dynamic> action) async {
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
      decoration: BoxDecoration(
        color: const Color(0xE61A1D33), // escuro translúcido
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withAlpha(30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(120),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
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

  Widget _dockList(List<RemoteApp> apps, {required bool vertical}) {
    return ListView.builder(
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: apps.length,
      itemBuilder: (context, i) => _dockTile(apps[i]),
    );
  }

  /// Ícone do aplicativo: quadrado com o gradiente da marca e a inicial. O nome
  /// aparece ao segurar (tooltip), mantendo a dock compacta.
  Widget _dockTile(RemoteApp app) {
    final initial =
        app.name.isEmpty ? '?' : app.name.substring(0, 1).toUpperCase();
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Tooltip(
        message: app.name,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _launchFromDock(app),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: auroraGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ),
        ),
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
      child: _frame == null
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
              final image = Image.memory(
                _frame!,
                gaplessPlayback: true,
                fit: BoxFit.fill,
                // Suaviza a imagem quando ampliada (menos "quadradinhos").
                filterQuality: FilterQuality.medium,
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
              return ClipRect(
                child: Transform(
                  transform: _transform.value,
                  transformHitTests: true,
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(showToggle: !isPortrait),
            Expanded(
              // A dock flutua SOBRE a tela (não rouba espaço): em pé à direita
              // na horizontal, deitada embaixo (acima do teclado) na vertical.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final area = Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    // expand é essencial: sem ele o Stack se dimensiona pelo
                    // filho não posicionado (a dock) e, quando ela está vazia,
                    // a tela inteira encolheria para um ponto.
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(child: _liveView()),
                      // No modo lupa a dock sai da frente, para não atrapalhar.
                      if (!_zoomMode)
                        _appDock(vertical: !isPortrait, area: area),
                    ],
                  );
                },
              ),
            ),
            if (showKeyboard)
              RemoteKeyboard(
                onText: (text) => _send({'kind': 'key_text', 'text': text}),
                onKey: (key) => _send({'kind': 'key_press', 'key': key}),
                onCombo: (mods, key) =>
                    _send({'kind': 'key_combo', 'modifiers': mods, 'key': key}),
              ),
          ],
        ),
      ),
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
                '$_fps fps',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
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
