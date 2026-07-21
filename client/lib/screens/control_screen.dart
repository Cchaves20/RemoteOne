import 'dart:async';

import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_state.dart';
import '../widgets/touchpad.dart';
import 'screen_view_screen.dart';

/// Tela de controle remoto: touchpad (mouse), botões e entrada de texto.
class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  static const _sensitivity = 1.6;
  // Pixels de arraste com 2 dedos por "passo" de rolagem.
  static const _scrollDivisor = 24.0;

  final _text = TextEditingController();

  // Acumula movimento e rolagem e envia em lote, para não gerar uma
  // requisição por evento de arraste.
  double _pendingDx = 0;
  double _pendingDy = 0;
  double _pendingScroll = 0;
  Timer? _flushTimer;

  @override
  void initState() {
    super.initState();
    _flushTimer =
        Timer.periodic(const Duration(milliseconds: 60), (_) => _flush());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _accumulateMove(double dx, double dy) {
    _pendingDx += dx * _sensitivity;
    _pendingDy += dy * _sensitivity;
  }

  void _accumulateScroll(double dy) {
    _pendingScroll += dy;
  }

  void _flush() {
    final dx = _pendingDx.truncate();
    final dy = _pendingDy.truncate();
    if (dx != 0 || dy != 0) {
      _pendingDx -= dx;
      _pendingDy -= dy;
      _send({'kind': 'mouse_move', 'dx': dx, 'dy': dy}, silent: true);
    }

    final steps = (_pendingScroll / _scrollDivisor).truncate();
    if (steps != 0) {
      _pendingScroll -= steps * _scrollDivisor;
      // 2 dedos para cima (dy negativo) → rolar para cima (dy positivo).
      _send({'kind': 'mouse_scroll', 'dy': -steps}, silent: true);
    }
  }

  Future<void> _send(Map<String, dynamic> action, {bool silent = false}) async {
    try {
      await widget.state.api.sendInput(widget.device.deviceId, action);
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  void _sendText() {
    final text = _text.text;
    if (text.isEmpty) return;
    _send({'kind': 'key_text', 'text': text});
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          IconButton(
            tooltip: 'Ver a tela',
            icon: const Icon(Icons.desktop_windows),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ScreenViewScreen(
                  state: widget.state,
                  device: widget.device,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: Touchpad(
                onMove: _accumulateMove,
                onScroll: _accumulateScroll,
                onLeftClick: () =>
                    _send({'kind': 'mouse_click', 'button': 'left'}),
                onRightClick: () =>
                    _send({'kind': 'mouse_click', 'button': 'right'}),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        _send({'kind': 'mouse_click', 'button': 'left'}),
                    icon: const Icon(Icons.mouse),
                    label: const Text('Esquerdo'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        _send({'kind': 'mouse_click', 'button': 'right'}),
                    icon: const Icon(Icons.mouse_outlined),
                    label: const Text('Direito'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _send({'kind': 'mouse_scroll', 'dy': 3}),
                    child: const Text('Rolar ↑'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _send({'kind': 'mouse_scroll', 'dy': -3}),
                    child: const Text('Rolar ↓'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    onSubmitted: (_) => _sendText(),
                    decoration: const InputDecoration(
                      labelText: 'Digitar no computador',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Enviar texto',
                  onPressed: _sendText,
                  icon: const Icon(Icons.send),
                ),
                IconButton(
                  tooltip: 'Enter',
                  onPressed: () =>
                      _send({'kind': 'key_press', 'key': 'enter'}),
                  icon: const Icon(Icons.keyboard_return),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
