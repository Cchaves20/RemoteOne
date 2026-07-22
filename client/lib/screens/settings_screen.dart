import 'package:flutter/material.dart';

import '../services/app_state.dart';

/// Configurações do app e da conta. Nesta primeira versão: tema, "Sobre" e
/// sair. Editar e-mail/senha e excluir conta entram na sequência.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  static const _appVersion = '0.1.0';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            children: [
              const _SectionHeader('Aparência'),
              RadioListTile<ThemeMode>(
                title: const Text('Automático (sistema)'),
                value: ThemeMode.system,
                groupValue: state.themeMode,
                onChanged: _setTheme,
              ),
              RadioListTile<ThemeMode>(
                title: const Text('Claro'),
                value: ThemeMode.light,
                groupValue: state.themeMode,
                onChanged: _setTheme,
              ),
              RadioListTile<ThemeMode>(
                title: const Text('Escuro'),
                value: ThemeMode.dark,
                groupValue: state.themeMode,
                onChanged: _setTheme,
              ),
              const Divider(),
              const _SectionHeader('Conta'),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sair'),
                onTap: () {
                  state.logout();
                  Navigator.of(context).pop();
                },
              ),
              const Divider(),
              const _SectionHeader('Sobre'),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('RemoteOne'),
                subtitle: Text('Versão $_appVersion'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _setTheme(ThemeMode? mode) {
    if (mode != null) state.setThemeMode(mode);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
