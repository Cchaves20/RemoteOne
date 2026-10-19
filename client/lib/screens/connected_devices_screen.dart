import 'package:flutter/material.dart';

import '../models/sessao.dart';
import '../services/app_state.dart';

/// Aparelhos conectados: onde a conta está aberta, e sair de um ou de todos.
///
/// Sem cidade, de propósito: localizar pelo IP pediria uma base de dados
/// externa ou mandar o endereço de cada pessoa a um serviço de terceiros.
class ConnectedDevicesScreen extends StatefulWidget {
  const ConnectedDevicesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ConnectedDevicesScreen> createState() => _ConnectedDevicesScreenState();
}

class _ConnectedDevicesScreenState extends State<ConnectedDevicesScreen> {
  List<Sessao>? _sessoes;
  String? _erro;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final sessoes = await widget.state.listSessions();
      if (!mounted) return;
      setState(() {
        // Este aparelho primeiro; os outros, do uso mais recente ao mais
        // antigo, como o servidor já manda.
        _sessoes = [
          ...sessoes.where((s) => s.atual),
          ...sessoes.where((s) => !s.atual),
        ];
        _erro = null;
      });
    } catch (e) {
      if (mounted) setState(() => _erro = e.toString());
    }
  }

  Future<bool> _confirmar(String titulo, String corpo, String botao) async {
    final t = widget.state.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(titulo),
        content: Text(corpo),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(botao),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _executar(Future<void> Function() acao, String sucesso) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _ocupado = true);
    try {
      await acao();
      messenger.showSnackBar(SnackBar(content: Text(sucesso)));
      await _carregar();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _sairDe(Sessao sessao) async {
    final t = widget.state.t;
    if (!await _confirmar(t.endSessionTitle(_nome(sessao)), t.endSessionBody,
        t.signOutDevice)) {
      return;
    }
    await _executar(() => widget.state.endSession(sessao.id), t.sessionEnded);
  }

  Future<void> _sairDosOutros() async {
    final t = widget.state.t;
    if (!await _confirmar(t.signOutOthers, t.endOthersBody, t.signOutDevice)) {
      return;
    }
    await _executar(widget.state.endOtherSessions, t.othersEnded);
  }

  String _nome(Sessao sessao) =>
      sessao.aparelho.isEmpty ? widget.state.t.oldAppDevice : sessao.aparelho;

  IconData _icone(Sessao sessao) {
    final nome = sessao.aparelho.toLowerCase();
    if (nome.contains('ipad') || nome.contains('tablet')) {
      return Icons.tablet_mac_outlined;
    }
    if (nome.contains('mac') || nome.contains('windows') || nome.contains('linux')) {
      return Icons.laptop_outlined;
    }
    return Icons.smartphone_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final theme = Theme.of(context);
    final sessoes = _sessoes;
    final outras = sessoes?.where((s) => !s.atual).length ?? 0;

    Widget corpo;
    if (sessoes == null && _erro == null) {
      corpo = const Center(child: CircularProgressIndicator());
    } else if (sessoes == null) {
      corpo = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_erro!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _carregar, child: Text(t.retry)),
            ],
          ),
        ),
      );
    } else {
      corpo = RefreshIndicator(
        onRefresh: _carregar,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            for (final sessao in sessoes)
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: ListTile(
                  leading: Icon(_icone(sessao)),
                  title: Text(_nome(sessao)),
                  subtitle: Text(
                    t.usadoHa(DateTime.now().difference(sessao.ultimoUso)),
                  ),
                  trailing: sessao.atual
                      ? Text(
                          t.thisDevice,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.primary),
                        )
                      : TextButton(
                          onPressed: _ocupado ? null : () => _sairDe(sessao),
                          child: Text(t.signOutDevice),
                        ),
                ),
              ),
            const SizedBox(height: 16),
            if (outras > 0)
              OutlinedButton.icon(
                onPressed: _ocupado ? null : _sairDosOutros,
                icon: const Icon(Icons.logout),
                label: Text(t.signOutOthers),
              )
            else
              Text(
                t.onlyThisDevice,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(t.connectedDevices)),
      body: corpo,
    );
  }
}
