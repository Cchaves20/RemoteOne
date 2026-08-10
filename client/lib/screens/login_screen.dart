import 'package:flutter/material.dart';

import '../models/pais.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../widgets/brand.dart';
import 'forgot_password_screen.dart';
import 'signup_screen.dart';

/// Tela de login. Também permite ajustar a URL do servidor, para apontar o
/// celular ao computador na mesma rede.
///
/// O cadastro **saiu daqui** e virou tela própria: são sete campos, um seletor
/// de país e uma lista de regras de senha, e espremer isso num formulário que
/// também faz login faria as duas coisas piores.
///
/// Entrar aceita e-mail **ou** telefone. Duas formas, um campo de cada vez, com
/// um seletor em cima: um campo só que aceitasse as duas teria de adivinhar o
/// país quando o texto parecesse um número — e `987654321` não identifica
/// ninguém sem saber de onde é.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// O campo de identificação: guarda o e-mail **ou** o telefone, conforme o
  /// seletor. Um controlador só porque nunca há os dois ao mesmo tempo — dois
  /// campos fariam parecer que se pede as duas coisas.
  final _contato = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  late final TextEditingController _server =
      TextEditingController(text: widget.state.serverUrl);

  /// Se entra por telefone. Falso = e-mail.
  bool _porTelefone = false;
  Pais _pais = Pais.padrao;

  bool _busy = false;
  // Vira true quando a conta tem 2FA e o backend pede o código.
  bool _needsCode = false;

  @override
  void dispose() {
    _contato.dispose();
    _password.dispose();
    _code.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _criarConta() async {
    widget.state.serverUrl = _server.text.trim();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SignupScreen(state: widget.state)),
    );
  }

  Future<void> _esqueciSenha() async {
    // O servidor vale para os dois caminhos: quem digitou um endereço errado
    // aqui vai errar lá também se o app apontar para outro lugar.
    widget.state.serverUrl = _server.text.trim();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ForgotPasswordScreen(state: widget.state)),
    );
  }

  Future<void> _escolherPais() async {
    final escolhido = await showModalBottomSheet<Pais>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, controller) => ListView.builder(
            controller: controller,
            itemCount: Pais.todos.length,
            itemBuilder: (_, i) {
              final p = Pais.todos[i];
              return ListTile(
                leading: Text(p.bandeira, style: const TextStyle(fontSize: 24)),
                title: Text(p.nome),
                trailing: Text('+${p.ddi}'),
                selected: p == _pais,
                onTap: () => Navigator.of(sheet).pop(p),
              );
            },
          ),
        ),
      ),
    );
    if (escolhido != null) setState(() => _pais = escolhido);
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    widget.state.serverUrl = _server.text.trim();
    try {
      await widget.state.login(
        _password.text,
        email: _porTelefone ? null : _contato.text.trim(),
        phone: _porTelefone ? _contato.text.trim() : null,
        country: _porTelefone ? _pais.iso : null,
        totpCode: _needsCode ? _code.text.trim() : null,
      );
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
                    const DesksideMark(size: 84),
                    const SizedBox(height: 18),
                    Text('Deskside', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      t.signInTitle,
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
                            SegmentedButton<bool>(
                              segments: [
                                ButtonSegment(
                                  value: false,
                                  label: Text(t.email),
                                  icon: const Icon(Icons.alternate_email),
                                ),
                                ButtonSegment(
                                  value: true,
                                  label: Text(t.phone),
                                  icon: const Icon(Icons.smartphone),
                                ),
                              ],
                              selected: {_porTelefone},
                              onSelectionChanged: (v) => setState(() {
                                _porTelefone = v.first;
                                // Limpa: um e-mail no campo de telefone não é
                                // um telefone, e deixá-lo lá convidaria a
                                // mandar.
                                _contato.clear();
                              }),
                            ),
                            const SizedBox(height: 12),
                            if (_porTelefone)
                              Row(
                                children: [
                                  InkWell(
                                    onTap: _escolherPais,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 18),
                                      child: Text('${_pais.bandeira} +${_pais.ddi}'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: _contato,
                                      keyboardType: TextInputType.phone,
                                      decoration: InputDecoration(
                                        labelText: t.phone,
                                        hintText: t.phoneHint,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            else
                              TextField(
                                controller: _contato,
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
                            if (_needsCode) ...[
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
                            : Text(t.signInButton),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _esqueciSenha,
                      child: Text(t.forgotLink),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _criarConta,
                      child: Text(t.createOne),
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
