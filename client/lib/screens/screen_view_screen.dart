import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/app_state.dart';

/// Mostra a tela do computador: pede a transmissão ao entrar, faz polling dos
/// frames JPEG e os exibe. Ao sair, pede para parar.
class ScreenViewScreen extends StatefulWidget {
  const ScreenViewScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<ScreenViewScreen> createState() => _ScreenViewScreenState();
}

class _ScreenViewScreenState extends State<ScreenViewScreen> {
  Uint8List? _frame;
  String? _error;
  bool _fetching = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.state.api.startScreen(widget.device.deviceId);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_fetching) return; // evita requisições sobrepostas
    _fetching = true;
    try {
      final frame = await widget.state.api.fetchFrame(widget.device.deviceId);
      if (frame != null && mounted) {
        setState(() {
          _frame = frame;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _fetching = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Best-effort: para a transmissão ao sair.
    widget.state.api.stopScreen(widget.device.deviceId).catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Tela — ${widget.device.name}')),
      backgroundColor: Colors.black,
      body: Center(child: _body()),
    );
  }

  Widget _body() {
    if (_frame != null) {
      // gaplessPlayback evita piscar ao trocar de frame; InteractiveViewer
      // permite dar zoom/arrastar a imagem.
      return InteractiveViewer(
        maxScale: 5,
        child: Image.memory(
          _frame!,
          gaplessPlayback: true,
          fit: BoxFit.contain,
        ),
      );
    }
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
}
