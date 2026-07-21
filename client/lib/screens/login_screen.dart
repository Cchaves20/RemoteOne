import 'package:flutter/material.dart';

import '../services/app_state.dart';

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
  late final TextEditingController _server =
      TextEditingController(text: widget.state.serverUrl);

  bool _registering = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
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
        await widget.state.login(_email.text.trim(), _password.text);
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
    return Scaffold(
      appBar: AppBar(title: const Text('RemoteOne')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _registering ? 'Criar conta' : 'Entrar',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'E-mail'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Senha'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Servidor',
                    helperText: 'Ex.: http://192.168.0.10:8000',
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_registering ? 'Cadastrar' : 'Entrar'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _registering = !_registering),
                  child: Text(_registering
                      ? 'Já tenho conta'
                      : 'Criar uma conta'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
