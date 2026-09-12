import 'package:flutter/material.dart';

import '../config.dart';
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

  /// Se o campo do servidor está à mostra.
  ///
  /// Aberto de saída **quando o endereço salvo não é o padrão** — que é
  /// exatamente quando a pessoa precisa vê-lo. É o caso de quem apontou o app
  /// para a própria rede e voltou dias depois sem lembrar, e o de quem ficou com
  /// um endereço que parou de responder: escondido, o login falharia e nada na
  /// tela explicaria por quê.
  late bool _servidorAberto = widget.state.serverUrl != backendPadrao;

  /// Se entra por telefone. Falso = e-mail.

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


  Future<void> _submit() async {
    setState(() => _busy = true);
    widget.state.serverUrl = _server.text.trim();
    try {
      await widget.state.login(
        _password.text,
        email: _contato.text.trim(),
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
                            // Só e-mail. Ver signup_screen.dart: sem
                            // provedor de SMS, o caminho por telefone saiu das
                            // telas. Aqui vale uma ressalva — o login por
                            // telefone **não** usava SMS (é telefone e senha,
                            // sem código), então quem tinha conta só com
                            // telefone perderia o acesso. Conferi antes de
                            // remover: havia uma, e ela ganhou e-mail primeiro.
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
                            // O endereço do servidor **não** fica à mostra.
                            //
                            // Enquanto o padrão embutido era `localhost`, este
                            // campo era obrigatório: sem digitar um endereço, o
                            // app não alcançava nada. Agora ele já nasce
                            // apontando para o servidor certo, e um campo de URL
                            // na tela de entrada de um produto para o público
                            // diz "isto é ferramenta de programador" — além de
                            // ser mais uma coisa que dá para preencher errado.
                            //
                            // Some, mas **não deixa de existir**: apontar o
                            // celular a um servidor da mesma rede continua
                            // legítimo, e é o que se usa para desenvolver.
                            const SizedBox(height: 4),
                            if (!_servidorAberto)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: () =>
                                      setState(() => _servidorAberto = true),
                                  child: Text(t.usarOutroServidor),
                                ),
                              )
                            else ...[
                              const SizedBox(height: 8),
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
                              // A saída para quem ficou com um endereço salvo que
                              // não responde mais. Sem ela, o único conserto seria
                              // reinstalar o app — e ninguém adivinharia que era
                              // isso.
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: () => setState(
                                      () => _server.text = backendPadrao),
                                  child: Text(t.voltarAoServidorPadrao),
                                ),
                              ),
                            ],
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
