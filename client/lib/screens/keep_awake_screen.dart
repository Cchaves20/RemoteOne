import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/keep_awake.dart';
import '../services/app_state.dart';

/// Manter um computador pronto para ser alcançado.
///
/// A tela pende de cada computador, e não das configurações do aplicativo,
/// porque a escolha é **de um computador**: um desktop na sala e um notebook
/// que viaja pedem respostas diferentes.
class KeepAwakeScreen extends StatefulWidget {
  const KeepAwakeScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<KeepAwakeScreen> createState() => _KeepAwakeScreenState();
}

class _KeepAwakeScreenState extends State<KeepAwakeScreen> {
  KeepAwakeState? _estado;
  String? _erro;
  bool _salvando = false;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final estado = await widget.state.keepAwake(widget.device);
      if (!mounted) return;
      setState(() {
        _estado = estado;
        _erro = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _erro = e.toString());
    }
  }

  Future<void> _alternar(bool valor) async {
    final anterior = _estado;
    // Move a chave na hora e desfaz se o computador recusar. O caminho de ida
    // e volta passa pelo servidor e pelo agente, e uma chave que só reage
    // depois disso parece quebrada.
    setState(() {
      _salvando = true;
      _estado = KeepAwakeState(
        enabled: valor,
        holding: valor && anterior?.source != PowerSource.battery,
        source: anterior?.source ?? PowerSource.unknown,
      );
    });
    try {
      await widget.state.setKeepAwake(widget.device, valor);
      // Relê em vez de confiar no palpite: quem sabe se o pedido pegou é o
      // computador, não esta tela.
      await _carregar();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _estado = anterior;
        _erro = e.toString();
      });
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.state.t;
    final estado = _estado;
    return Scaffold(
      appBar: AppBar(title: Text('${t.keepAwakeTitle} — ${widget.device.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              value: estado?.enabled ?? false,
              onChanged: estado == null || _salvando ? null : _alternar,
              title: Text(t.keepAwakeSwitch),
              secondary: const Icon(Icons.bedtime_off),
            ),
          ),
          if (estado != null) ...[
            const SizedBox(height: 12),
            _Situacao(estado: estado, state: widget.state),
          ],
          if (_erro != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.device.online ? _erro! : t.keepAwakeOffline,
                        style: TextStyle(
                            color: theme.colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(t.keepAwakeWhy, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t.keepAwakeLimits)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A linha que diz o que está valendo **agora**.
///
/// Separada da chave de propósito: ligado e segurando não são a mesma coisa, e
/// é justamente na diferença entre os dois que mora a surpresa ruim - um
/// notebook na bateria com a chave ligada vai dormir do mesmo jeito.
class _Situacao extends StatelessWidget {
  const _Situacao({required this.estado, required this.state});

  final KeepAwakeState estado;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = state.t;
    final (icone, texto, cor) = switch (estado) {
      KeepAwakeState(holding: true) => (
          Icons.check_circle,
          t.keepAwakeHolding,
          theme.colorScheme.primary,
        ),
      KeepAwakeState(enabled: true) => (
          Icons.battery_alert,
          t.keepAwakeOnBattery,
          theme.colorScheme.tertiary,
        ),
      _ => (
          Icons.bedtime,
          t.keepAwakeOff,
          theme.colorScheme.onSurfaceVariant,
        ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icone, color: cor),
            const SizedBox(width: 12),
            Expanded(child: Text(texto)),
          ],
        ),
      ),
    );
  }
}
