import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/stream_quality.dart';
import '../services/app_state.dart';
import '../widgets/brand.dart';
import '../widgets/transitions.dart';
import 'gesture_tutorial_screen.dart';
import 'profiles_screen.dart';
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
          var i = 0;
          Widget staggered(Widget child) => FadeSlideIn(
                delay: Duration(milliseconds: 40 * i++),
                child: child,
              );
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              staggered(_card(context, t.appearance, Icons.palette_outlined, [
                _themeSelector(context),
                const SizedBox(height: 16),
                _label(context, t.language),
                const SizedBox(height: 8),
                _languageChips(context),
              ])),
              staggered(_card(context, t.screenQuality, Icons.hd_outlined, [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.bolt_outlined),
                  title: Text(t.webrtcVideo),
                  subtitle: Text(t.webrtcVideoSub),
                  value: state.webrtcVideoEnabled,
                  onChanged: state.setWebrtcVideoEnabled,
                ),
                const Divider(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.spellcheck),
                  title: Text(t.suggestions),
                  subtitle: Text(t.suggestionsSub),
                  value: state.suggestionsEnabled,
                  onChanged: state.setSuggestionsEnabled,
                ),
                const Divider(height: 20),
                _qualityChips(context),
                const SizedBox(height: 10),
                Text(
                  t.qualitySubtitle(state.streamQuality),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ])),
              staggered(_card(context, t.security, Icons.shield_outlined, [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.lock_outline),
                  title: Text(t.faceIdLock),
                  subtitle: Text(t.faceIdLockSub),
                  value: state.appLockEnabled,
                  onChanged: state.setAppLockEnabled,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.verified_user_outlined),
                  title: Text(t.twoFactor),
                  subtitle: Text(t.twoFactorSub),
                  value: state.twoFactorEnabled,
                  onChanged: (value) => value
                      ? _startTwoFactor(context)
                      : _disableTwoFactor(context),
                ),
              ])),
              staggered(_card(context, t.profilesTitle, Icons.tune, [
                _action(context, Icons.dashboard_customize, t.profilesTitle,
                    () => Navigator.of(context)
                        .push(fadeThroughRoute(ProfilesScreen(state: state))),
                    subtitle: t.profilesHint),
              ])),
              staggered(_card(context, t.account, Icons.person_outline, [
                _action(context, Icons.alternate_email, t.changeEmail,
                    () => _showChangeEmail(context)),
                _action(context, Icons.password, t.changePassword,
                    () => _showChangePassword(context)),
                _action(context, Icons.logout, t.signOut, () {
                  state.logout();
                  Navigator.of(context).pop();
                }),
                _action(context, Icons.delete_forever, t.deleteAccount,
                    () => _showDeleteAccount(context),
                    danger: true),
              ])),
              staggered(_card(context, t.help, Icons.help_outline, [
                _action(context, Icons.touch_app, t.howToControl,
                    () => Navigator.of(context)
                        .push(fadeThroughRoute(GestureTutorialScreen(state: state))),
                    subtitle: t.howToControlSub),
                _action(context, Icons.power, t.turnOnPc,
                    () => Navigator.of(context)
                        .push(fadeThroughRoute(WakeOnLanScreen(state: state))),
                    subtitle: t.turnOnPcSub),
              ])),
              staggered(_card(context, t.about, Icons.info_outline, [
                Row(
                  children: [
                    const RemoteOneMark(size: 44),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('RemoteOne',
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(t.version(_appVersion),
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),
              ])),
            ],
          );
        },
      ),
    );
  }

  // --- blocos visuais ---------------------------------------------------------

  /// Card de seção com título, ícone e conteúdo.
  Widget _card(
      BuildContext context, String title, IconData icon, List<Widget> children) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      );

  /// Linha de ação com ícone, título e (opcional) subtítulo.
  Widget _action(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap, {
    String? subtitle,
    bool danger = false,
  }) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }

  /// Tema em controle segmentado (Auto / Claro / Escuro).
  Widget _themeSelector(BuildContext context) {
    final t = state.t;
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: ThemeMode.system,
            icon: const Icon(Icons.brightness_auto, size: 18),
            label: Text(t.autoShort),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            icon: const Icon(Icons.light_mode_outlined, size: 18),
            label: Text(t.themeLight),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            icon: const Icon(Icons.dark_mode_outlined, size: 18),
            label: Text(t.themeDark),
          ),
        ],
        selected: {state.themeMode},
        onSelectionChanged: (s) => state.setThemeMode(s.first),
      ),
    );
  }

  /// Idiomas como chips (acomoda 6 opções sem estourar a largura).
  Widget _languageChips(BuildContext context) {
    final t = state.t;
    const options = <(AppLanguage, String)>[
      (AppLanguage.ptBr, 'Português'),
      (AppLanguage.en, 'English'),
      (AppLanguage.zh, '中文'),
      (AppLanguage.fr, 'Français'),
      (AppLanguage.es, 'Español'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: Text(t.autoShort),
          selected: state.language == AppLanguage.system,
          onSelected: (_) => state.setLanguage(AppLanguage.system),
        ),
        for (final (lang, label) in options)
          ChoiceChip(
            label: Text(label),
            selected: state.language == lang,
            onSelected: (_) => state.setLanguage(lang),
          ),
      ],
    );
  }

  /// Qualidade da tela como chips (o detalhe técnico vai abaixo, em texto).
  Widget _qualityChips(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final q in StreamQuality.values)
          ChoiceChip(
            label: Text(state.t.qualityLabel(q)),
            selected: state.streamQuality == q,
            onSelected: (_) => state.setStreamQuality(q),
          ),
      ],
    );
  }

  // --- verificação em duas etapas --------------------------------------------

  Future<void> _startTwoFactor(BuildContext context) async {
    await Navigator.of(context).push(
      fadeThroughRoute(TwoFactorScreen(state: state)),
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
