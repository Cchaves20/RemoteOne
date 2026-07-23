import 'package:flutter/material.dart';

import '../models/stream_quality.dart';
import '../services/app_state.dart';
import 'wake_on_lan_screen.dart';

/// Configurações do app e da conta: tema, qualidade da tela, segurança,
/// gerenciamento de conta (e-mail, senha, excluir) e "Sobre".
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
              const _SectionHeader('Qualidade da tela'),
              for (final q in StreamQuality.values) _qualityTile(q),
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
                leading: const Icon(Icons.alternate_email),
                title: const Text('Alterar e-mail'),
                onTap: () => _showChangeEmail(context),
              ),
              ListTile(
                leading: const Icon(Icons.password),
                title: const Text('Alterar senha'),
                onTap: () => _showChangePassword(context),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sair'),
                onTap: () {
                  state.logout();
                  Navigator.of(context).pop();
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_forever,
                    color: Theme.of(context).colorScheme.error),
                title: Text('Excluir conta',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () => _showDeleteAccount(context),
              ),
              const Divider(),
              const _SectionHeader('Ajuda'),
              ListTile(
                leading: const Icon(Icons.power),
                title: const Text('Ligar o PC (Wake-on-LAN)'),
                subtitle: const Text('Como acordar um computador desligado'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WakeOnLanScreen()),
                ),
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

  Widget _qualityTile(StreamQuality quality) {
    final selected = state.streamQuality == quality;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(quality.label),
      subtitle: Text(
        '${quality.fps} fps · até ${quality.maxWidth}px · qualidade ${quality.quality}',
      ),
      onTap: () => state.setStreamQuality(quality),
    );
  }

  // --- diálogos de conta -----------------------------------------------------

  Future<void> _showChangeEmail(BuildContext context) async {
    final email = TextEditingController();
    final password = TextEditingController();
    // Captura antes do await para não usar o context após o gap assíncrono.
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alterar e-mail'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Novo e-mail'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Senha atual'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      messenger,
      () => state.updateEmail(password.text, email.text.trim()),
      'E-mail atualizado.',
    );
  }

  Future<void> _showChangePassword(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alterar senha'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Senha atual'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Nova senha (mín. 8 caracteres)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      messenger,
      () => state.updatePassword(current.text, next.text),
      'Senha atualizada.',
    );
  }

  Future<void> _showDeleteAccount(BuildContext context) async {
    final password = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir conta'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Isso remove sua conta e todos os computadores pareados. '
              'A ação não pode ser desfeita.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Confirme a senha'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.deleteAccount(password.text);
      // Conta excluída: volta à raiz (LoginScreen assume via isAuthenticated).
      navigator.popUntil((route) => route.isFirst);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Executa uma ação assíncrona mostrando erro/sucesso via SnackBar. Recebe o
  /// messenger já resolvido (capturado antes de qualquer await no chamador).
  Future<void> _run(
    ScaffoldMessengerState messenger,
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
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
