import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import '../widgets/brand.dart';

/// Tela de login/cadastro. Também permite ajustar a URL do servidor, para
/// apontar o celular ao computador na mesma rede.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  late final TextEditingController _server =
      TextEditingController(text: widget.state.serverUrl);

  bool _registering = false;
  bool _busy = false;
  // Vira true quando a conta tem 2FA e o backend pede o código.
  bool _needsCode = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    widget.state.serverUrl = _server.text.trim();
    try {
      if (_registering) {
        await widget.state.register(_email.text.trim(), _password.text);
      } else {
        await widget.state.login(
          _email.text.trim(),
          _password.text,
          totpCode: _needsCode ? _code.text.trim() : null,
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == 'two_factor_required') {
        // Senha ok: agora pede o código do autenticador.
        setState(() => _needsCode = true);
      } else if (e.message == 'two_factor_invalid') {
        setState(() => _needsCode = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.state.t.invalidCode)),
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final theme = Theme.of(context);
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const RemoteOneMark(size: 84),
                    const SizedBox(height: 18),
                    Text('RemoteOne', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      _registering ? t.createAccountTitle : t.signInTitle,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            TextField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: t.email,
                                prefixIcon: const Icon(Icons.alternate_email),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _password,
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: t.password,
                                prefixIcon: const Icon(Icons.lock_outline),
                              ),
                            ),
                            if (_needsCode && !_registering) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _code,
                                keyboardType: TextInputType.number,
                                autofocus: true,
                                decoration: InputDecoration(
                                  labelText: t.twoFactorCode,
                                  helperText: t.twoFactorCodeHint,
                                  prefixIcon: const Icon(Icons.verified_user_outlined),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                              controller: _server,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: t.server,
                                helperText: t.serverHint,
                                prefixIcon: const Icon(Icons.dns_outlined),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_registering
                                ? t.createAccountButton
                                : t.signInButton),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _registering = !_registering),
                      child: Text(_registering ? t.haveAccount : t.createOne),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
