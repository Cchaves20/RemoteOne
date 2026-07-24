import 'package:flutter/material.dart';

import '../services/app_state.dart';

/// Explica, em linguagem simples, como o "Ligar" (Wake-on-LAN) funciona, e
/// traz o modo avançado (roteador) com um aviso de segurança claro.
class WakeOnLanScreen extends StatelessWidget {
  const WakeOnLanScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = state.t;
    return Scaffold(
      appBar: AppBar(title: Text(t.wolTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.wolHowTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(t.wolHowBody),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t.wolNote)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(t.wolPrepareTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(t.wolPrepareBody),
          const SizedBox(height: 16),
          _RouterAdvanced(state: state),
        ],
      ),
    );
  }
}

/// Modo avançado: ligar o PC de fora de casa. Recolhido por padrão, com aviso
/// de segurança em linguagem simples.
class _RouterAdvanced extends StatelessWidget {
  const _RouterAdvanced({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = state.t;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.router),
        title: Text(t.wolRouterTitle),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.wolRouterWarning,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(t.wolRouterBody),
          const SizedBox(height: 12),
          Text(t.wolRouterIdeaTitle, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(t.wolRouterIdea),
          const SizedBox(height: 12),
          Text(
            t.wolRouterFuture,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
