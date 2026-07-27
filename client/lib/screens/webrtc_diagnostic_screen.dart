// Tela temporária do spike S1 do plano de WebRTC (docs/webrtc-plano.md).
//
// A pergunta que ela responde: **o flutter_webrtc funciona num .ipa não
// assinado, instalado com Apple ID grátis?** Se a resposta for não, o plano
// inteiro muda, e é melhor descobrir agora.
//
// Os três testes são independentes e vão do mais básico ao mais revelador:
//
//  1. o framework nativo carrega (é o que quebra se a assinatura atrapalhar);
//  2. duas conexões falam entre si dentro do próprio aparelho — prova que
//     ICE, DTLS e o canal de dados funcionam de verdade, sem servidor nenhum;
//  3. um servidor STUN público devolve o IP externo — é o pré-requisito do
//     P2P, então já adianta parte da resposta do spike S3.
//
// De propósito só em português: é ferramenta de diagnóstico temporária, não
// recurso do produto, e não vale poluir as cinco traduções com ela. Sai junto
// com o spike.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum _Status { pending, running, ok, warn, fail }

class _Check {
  _Check(this.title, this.explanation);

  final String title;
  final String explanation;
  _Status status = _Status.pending;
  String detail = '';
}

class WebrtcDiagnosticScreen extends StatefulWidget {
  const WebrtcDiagnosticScreen({super.key});

  @override
  State<WebrtcDiagnosticScreen> createState() => _WebrtcDiagnosticScreenState();
}

class _WebrtcDiagnosticScreenState extends State<WebrtcDiagnosticScreen> {
  late final List<_Check> _checks = [
    _Check(
      '1. O framework carrega',
      'Cria e fecha uma conexão. Se falhar aqui, a biblioteca nativa não '
          'subiu — normalmente é a assinatura ou o mínimo de iOS.',
    ),
    _Check(
      '2. Duas conexões conversam',
      'Liga duas conexões uma na outra dentro do aparelho e manda uma '
          'mensagem de ida e volta. Prova que ICE, criptografia e o canal de '
          'dados funcionam, sem depender de rede nem de servidor.',
    ),
    _Check(
      '3. O STUN enxerga seu IP',
      'Pergunta a um servidor público qual é o seu IP externo. É o que o '
          'WebRTC precisa para tentar conexão direta com o computador.',
    ),
  ];

  bool _running = false;

  Future<void> _runAll() async {
    setState(() {
      _running = true;
      for (final c in _checks) {
        c.status = _Status.pending;
        c.detail = '';
      }
    });

    await _run(_checks[0], _testFramework);
    await _run(_checks[1], _testLoopback);
    await _run(_checks[2], _testStun);

    if (mounted) setState(() => _running = false);
  }

  /// Roda um teste, cuidando de estado e de erro. O teste devolve o texto do
  /// resultado; para avisar sem reprovar, lança [_Warning].
  Future<void> _run(_Check check, Future<String> Function() body) async {
    if (mounted) setState(() => check.status = _Status.running);
    try {
      final detail = await body();
      if (!mounted) return;
      setState(() {
        check.status = _Status.ok;
        check.detail = detail;
      });
    } on _Warning catch (w) {
      if (!mounted) return;
      setState(() {
        check.status = _Status.warn;
        check.detail = w.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        check.status = _Status.fail;
        check.detail = '$e';
      });
    }
  }

  // --- os testes --------------------------------------------------------------

  Future<String> _testFramework() async {
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[],
    });
    await pc.close();
    await pc.dispose();
    return 'Conexão criada e fechada sem erro.';
  }

  Future<String> _testLoopback() async {
    const config = <String, dynamic>{'iceServers': <Map<String, dynamic>>[]};
    final pc1 = await createPeerConnection(config);
    final pc2 = await createPeerConnection(config);

    // Candidatos podem aparecer antes de o outro lado ter a descrição remota;
    // nesse caso ficam na fila e entram assim que der.
    final queued1 = <RTCIceCandidate>[];
    final queued2 = <RTCIceCandidate>[];
    var remoteOn1 = false;
    var remoteOn2 = false;

    pc1.onIceCandidate = (candidate) async {
      if (remoteOn2) {
        await pc2.addCandidate(candidate);
      } else {
        queued1.add(candidate);
      }
    };
    pc2.onIceCandidate = (candidate) async {
      if (remoteOn1) {
        await pc1.addCandidate(candidate);
      } else {
        queued2.add(candidate);
      }
    };

    // O lado que recebe ecoa de volta o que chegar.
    pc2.onDataChannel = (channel) {
      channel.onMessage = (message) {
        channel.send(RTCDataChannelMessage('eco:${message.text}'));
      };
    };

    final echoed = Completer<String>();
    final channel = await pc1.createDataChannel(
      'spike',
      RTCDataChannelInit(),
    );
    channel.onMessage = (message) {
      if (!echoed.isCompleted) echoed.complete(message.text);
    };
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        channel.send(RTCDataChannelMessage('ping'));
      }
    };

    final started = DateTime.now();
    final offer = await pc1.createOffer();
    await pc1.setLocalDescription(offer);
    await pc2.setRemoteDescription(offer);
    remoteOn2 = true;
    for (final candidate in queued1) {
      await pc2.addCandidate(candidate);
    }
    queued1.clear();

    final answer = await pc2.createAnswer();
    await pc2.setLocalDescription(answer);
    await pc1.setRemoteDescription(answer);
    remoteOn1 = true;
    for (final candidate in queued2) {
      await pc1.addCandidate(candidate);
    }
    queued2.clear();

    try {
      final reply = await echoed.future.timeout(const Duration(seconds: 20));
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (reply != 'eco:ping') {
        throw StateError('resposta inesperada: "$reply"');
      }
      return 'Ida e volta completa em ${ms}ms.';
    } on TimeoutException {
      throw StateError(
        'A mensagem não voltou em 20s — as conexões não se conectaram.',
      );
    } finally {
      await pc1.close();
      await pc2.close();
      await pc1.dispose();
      await pc2.dispose();
    }
  }

  Future<String> _testStun() async {
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    final external = Completer<String>();
    var localCandidates = 0;
    pc.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (line == null) return;
      if (line.contains(' typ host')) localCandidates++;
      if (line.contains(' typ srflx') && !external.isCompleted) {
        // candidate:<id> <comp> <proto> <prio> <IP> <porta> typ srflx ...
        final parts = line.split(' ');
        external.complete(parts.length > 4 ? parts[4] : 'desconhecido');
      }
    };

    await pc.createDataChannel('stun', RTCDataChannelInit());
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    try {
      final ip = await external.future.timeout(const Duration(seconds: 15));
      return 'IP externo: $ip · $localCandidates endereço(s) local(is).';
    } on TimeoutException {
      throw _Warning(
        'O STUN não respondeu em 15s ($localCandidates endereço(s) local(is) '
        'encontrado(s)). Pode ser a rede bloqueando UDP. Os testes 1 e 2 são '
        'o que decide o spike; este aqui é bônus.',
      );
    } finally {
      await pc.close();
      await pc.dispose();
    }
  }

  // --- interface --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final done = _checks.every((c) => c.status != _Status.pending) && !_running;
    final blocking = _checks.take(2);
    final passed = blocking.every((c) => c.status == _Status.ok);

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico WebRTC')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Verificação temporária para decidir se o RemoteOne pode migrar o '
            'vídeo para WebRTC. Rode com o celular na rede que você usa no '
            'dia a dia.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          for (final check in _checks) _tile(check),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _running ? null : _runAll,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? 'Testando…' : 'Rodar os testes'),
          ),
          if (done) ...[
            const SizedBox(height: 20),
            _verdict(context, passed),
          ],
        ],
      ),
    );
  }

  Widget _verdict(BuildContext context, bool passed) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: passed ? scheme.primaryContainer : scheme.errorContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          passed
              ? 'Os dois testes que decidem passaram: o WebRTC funciona neste '
                  'aparelho, instalado deste jeito. O plano segue como está.'
              : 'Algum teste essencial falhou. Copie o texto do erro — é ele '
                  'que diz se dá para seguir com WebRTC ou se o vídeo continua '
                  'no caminho atual.',
          style: TextStyle(
            color: passed ? scheme.onPrimaryContainer : scheme.onErrorContainer,
          ),
        ),
      ),
    );
  }

  Widget _tile(_Check check) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _icon(check.status),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(check.title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    check.explanation,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (check.detail.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      check.detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: check.status == _Status.fail
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _icon(_Status status) {
    switch (status) {
      case _Status.pending:
        return const Icon(Icons.circle_outlined, color: Colors.grey);
      case _Status.running:
        return const SizedBox(
          width: 24,
          height: 24,
          child: Padding(
            padding: EdgeInsets.all(3),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _Status.ok:
        return const Icon(Icons.check_circle, color: Colors.green);
      case _Status.warn:
        return const Icon(Icons.error_outline, color: Colors.orange);
      case _Status.fail:
        return Icon(Icons.cancel, color: Theme.of(context).colorScheme.error);
    }
  }
}

/// Falha branda: o teste não passou, mas não reprova o spike.
class _Warning implements Exception {
  _Warning(this.message);
  final String message;

  @override
  String toString() => message;
}
