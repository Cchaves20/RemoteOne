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
              _themeTile('Automático (sistema)', ThemeMode.system),
              _themeTile('Claro', ThemeMode.light),
              _themeTile('Escuro', ThemeMode.dark),
              const Divider(),
              const _SectionHeader('Segurança'),
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline),
                title: const Text('Bloquear com Face ID / biometria'),
                subtitle: const Text('Pede biometria ao abrir o app'),
                value: state.appLockEnabled,
                onChanged: state.setAppLockEnabled,
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

  Widget _themeTile(String label, ThemeMode mode) {
    final selected = state.themeMode == mode;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(label),
      onTap: () => state.setThemeMode(mode),
    );
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
