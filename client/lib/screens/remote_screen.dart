import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';
import '../services/app_state.dart';
import '../widgets/remote_keyboard.dart';
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

class _RemoteScreenState extends State<RemoteScreen> {
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
    // Na primeira vez que se controla um PC, mostra o tutorial de gestos (#20).
    if (!widget.state.gestureTutorialSeen) {
      widget.state.markGestureTutorialSeen();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const GestureTutorialScreen()),
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
    if (mounted) setState(() => _error = 'Reconectando…');
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
    WakelockPlus.disable();
    super.dispose();
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

  Widget _liveView() {
    if (_frame == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _error ?? 'Aguardando a tela do computador...',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      );
    }
    return Center(
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
              return GestureDetector(
                onTapUp: (d) => _tapAt(d.localPosition, box),
                onLongPressStart: (d) => _rightClickAt(d.localPosition, box),
                onScaleUpdate: (d) {
                  if (d.pointerCount >= 2) {
                    _pendingScroll += d.focalPointDelta.dy;
                  } else {
                    _moveTo(d.localFocalPoint, box);
                  }
                },
                child:
                    Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill),
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
            Expanded(child: _liveView()),
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
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 4),
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
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$_fps fps',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
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
      ),
    );
  }
}
