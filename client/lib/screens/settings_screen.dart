import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/stream_quality.dart';
import '../services/app_state.dart';
import '../widgets/brand.dart';
import 'gesture_tutorial_screen.dart';
import 'two_factor_screen.dart';
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
      appBar: AppBar(title: Text(state.t.settings)),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final t = state.t;
          return ListView(
            children: [
              _SectionHeader(t.appearance),
              _themeTile(t.themeAuto, ThemeMode.system),
              _themeTile(t.themeLight, ThemeMode.light),
              _themeTile(t.themeDark, ThemeMode.dark),
              const Divider(),
              _SectionHeader(t.language),
              _langTile(t.languageSystem, AppLanguage.system),
              _langTile('Português', AppLanguage.ptBr),
              _langTile('English', AppLanguage.en),
              _langTile('中文', AppLanguage.zh),
              _langTile('Français', AppLanguage.fr),
              _langTile('Español', AppLanguage.es),
              const Divider(),
              _SectionHeader(t.screenQuality),
              for (final q in StreamQuality.values) _qualityTile(q),
              const Divider(),
              _SectionHeader(t.security),
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline),
                title: Text(t.faceIdLock),
                subtitle: Text(t.faceIdLockSub),
                value: state.appLockEnabled,
                onChanged: state.setAppLockEnabled,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.verified_user_outlined),
                title: Text(t.twoFactor),
                subtitle: Text(t.twoFactorSub),
                value: state.twoFactorEnabled,
                onChanged: (value) => value
                    ? _startTwoFactor(context)
                    : _disableTwoFactor(context),
              ),
              const Divider(),
              _SectionHeader(t.account),
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: Text(t.changeEmail),
                onTap: () => _showChangeEmail(context),
              ),
              ListTile(
                leading: const Icon(Icons.password),
                title: Text(t.changePassword),
                onTap: () => _showChangePassword(context),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(t.signOut),
                onTap: () {
                  state.logout();
                  Navigator.of(context).pop();
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_forever,
                    color: Theme.of(context).colorScheme.error),
                title: Text(t.deleteAccount,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () => _showDeleteAccount(context),
              ),
              const Divider(),
              _SectionHeader(t.help),
              ListTile(
                leading: const Icon(Icons.touch_app),
                title: Text(t.howToControl),
                subtitle: Text(t.howToControlSub),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => GestureTutorialScreen(state: state)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.power),
                title: Text(t.turnOnPc),
                subtitle: Text(t.turnOnPcSub),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => WakeOnLanScreen(state: state)),
                ),
              ),
              const Divider(),
              _SectionHeader(t.about),
              ListTile(
                leading: const RemoteOneMark(size: 40),
                title: const Text('RemoteOne'),
                subtitle: Text(t.version(_appVersion)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _langTile(String label, AppLanguage lang) {
    final selected = state.language == lang;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(label),
      onTap: () => state.setLanguage(lang),
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
      title: Text(state.t.qualityLabel(quality)),
      subtitle: Text(state.t.qualitySubtitle(quality)),
      onTap: () => state.setStreamQuality(quality),
    );
  }

  // --- verificação em duas etapas --------------------------------------------

  Future<void> _startTwoFactor(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TwoFactorScreen(state: state)),
    );
  }

  Future<void> _disableTwoFactor(BuildContext context) async {
    final t = state.t;
    final password = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.disableTwoFactor),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.disableTwoFactorBody),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: t.password),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.disable),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.disableTwoFactor(password.text);
      messenger.showSnackBar(
        SnackBar(content: Text(t.twoFactorDisabled)),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // --- diálogos de conta -----------------------------------------------------

  Future<void> _showChangeEmail(BuildContext context) async {
    final t = state.t;
    final email = TextEditingController();
    final password = TextEditingController();
    // Captura antes do await para não usar o context após o gap assíncrono.
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.changeEmail),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: t.newEmail),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: InputDecoration(labelText: t.currentPassword),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.save),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      messenger,
      () => state.updateEmail(password.text, email.text.trim()),
      t.emailUpdated,
    );
  }

  Future<void> _showChangePassword(BuildContext context) async {
    final t = state.t;
    final current = TextEditingController();
    final next = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.changePassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: t.currentPassword),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: InputDecoration(labelText: t.newPasswordMin),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.save),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      messenger,
      () => state.updatePassword(current.text, next.text),
      t.passwordUpdated,
    );
  }

  Future<void> _showDeleteAccount(BuildContext context) async {
    final t = state.t;
    final password = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.deleteAccount),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.deleteAccountBody),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: t.confirmPassword),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.delete),
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
