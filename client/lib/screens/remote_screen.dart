import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';
import '../services/app_state.dart';
import '../widgets/remote_keyboard.dart';

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

  @override
  void initState() {
    super.initState();
    _connect();
    _flushTimer =
        Timer.periodic(const Duration(milliseconds: 60), (_) => _flushScroll());
  }

  void _connect() {
    final channel = widget.state.api.connectScreen(widget.device.deviceId);
    _channel = channel;
    _sub = channel.stream.listen(
      (event) {
        if (event is! List<int>) return; // ignora mensagens de texto
        final frame =
            event is Uint8List ? event : Uint8List.fromList(event);
        if (!mounted) return;
        setState(() {
          _frame = frame;
          _error = null;
        });
        _resolveAspect(frame);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = 'Conexão de tela perdida');
      },
    );
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
    _flushTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
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
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    _send({'kind': 'mouse_click', 'button': 'left'});
  }

  void _rightClickAt(Offset local, Size box) {
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
              child: Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _liveView()),
          // Barra superior translúcida com voltar e alternar teclado.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  _RoundButton(
                    icon: _keyboardVisible ? Icons.keyboard_hide : Icons.keyboard,
                    onTap: () =>
                        setState(() => _keyboardVisible = !_keyboardVisible),
                  ),
                ],
              ),
            ),
          ),
          if (_keyboardVisible)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: RemoteKeyboard(
                  onText: (text) => _send({'kind': 'key_text', 'text': text}),
                  onKey: (key) => _send({'kind': 'key_press', 'key': key}),
                  onCombo: (mods, key) =>
                      _send({'kind': 'key_combo', 'modifiers': mods, 'key': key}),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onTap,
      ),
    );
  }
}
