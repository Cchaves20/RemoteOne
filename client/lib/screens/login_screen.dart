import 'package:flutter/material.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/identidade.dart';
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
  // Digitando um código de recuperação em vez do autenticador.
  bool _recuperacao = false;

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
    final c = context.cores;
    return Scaffold(
      body: BrilhoDoTopo(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, limites) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                // A altura toda da tela, para o "Usar outro servidor" ficar no
                // rodapé quando cabe, e descer junto quando não cabe.
                constraints: BoxConstraints(minHeight: limites.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 56),
                        const Center(child: LogoDeskside(largura: 104)),
                        const SizedBox(height: 20),
                        Text('Deskside',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.displaySmall
                                ?.copyWith(fontSize: 36, letterSpacing: -1)),
                        const SizedBox(height: 6),
                        Text(t.fraseDaMarca,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: c.texto2, fontSize: 15)),
                        const SizedBox(height: 36),
                        // Só e-mail. Ver signup_screen.dart: sem provedor de
                        // SMS, o caminho por telefone saiu das telas. O login
                        // por telefone **não** usava SMS (é telefone e senha),
                        // então quem tinha conta só com telefone perderia o
                        // acesso. Conferi antes de remover: havia uma, e ela
                        // ganhou e-mail primeiro.
                        //
                        // Os campos direto sobre o fundo, sem o cartão em volta:
                        // caixa dentro de caixa era o que mais deixava a tela
                        // com cara de formulário genérico.
                        TextField(
                          controller: _contato,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.email],
                          decoration: InputDecoration(labelText: t.email),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => _busy ? null : _submit(),
                          decoration: InputDecoration(labelText: t.password),
                        ),
                        if (_needsCode) ...[
                          const SizedBox(height: 14),
                          TextField(
                            // A chave muda com o modo para o campo nascer de
                            // novo com o teclado certo.
                            key: ValueKey(_recuperacao),
                            controller: _code,
                            keyboardType: _recuperacao
                                ? TextInputType.text
                                : TextInputType.number,
                            textCapitalization: _recuperacao
                                ? TextCapitalization.characters
                                : TextCapitalization.none,
                            autocorrect: false,
                            autofocus: true,
                            style: context.numeros.copyWith(fontSize: 17),
                            decoration: InputDecoration(
                              labelText:
                                  _recuperacao ? t.recoveryCode : t.twoFactorCode,
                              helperText: _recuperacao
                                  ? t.secondFactorRecoveryBody
                                  : t.twoFactorCodeHint,
                              helperMaxLines: 2,
                              hintText: _recuperacao ? 'ABCDE-FGHJK' : null,
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => setState(() {
                                _recuperacao = !_recuperacao;
                                _code.clear();
                              }),
                              child: Text(_recuperacao
                                  ? t.useAuthenticatorCode
                                  : t.useRecoveryCode),
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        BotaoDeskside(
                          rotulo: t.signInButton,
                          largo: true,
                          carregando: _busy,
                          onPressed: _submit,
                        ),
                        const SizedBox(height: 6),
                        // `Wrap`, e não `Row`: em francês, num celular
                        // estreito, os dois não cabem lado a lado, e a `Row`
                        // estourava a tela.
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            TextButton(
                              style: TextButton.styleFrom(foregroundColor: c.texto2),
                              onPressed: _busy ? null : _esqueciSenha,
                              child: Text(t.forgotLink),
                            ),
                            TextButton(
                              onPressed: _busy ? null : _criarConta,
                              child: Text(t.createOne),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        // O endereço do servidor **não** fica à mostra.
                        //
                        // Ele já nasce apontando para o servidor certo, e um
                        // campo de URL na tela de entrada de um produto para o
                        // público diz "isto é ferramenta de programador". Some,
                        // mas **não deixa de existir**: apontar o celular a um
                        // servidor da mesma rede continua legítimo, e é o que se
                        // usa para desenvolver. Por isso fica no rodapé, pequeno.
                        if (_servidorAberto) ...[
                          TextField(
                            controller: _server,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            style: context.numeros.copyWith(fontSize: 14),
                            decoration: InputDecoration(
                              labelText: t.server,
                              helperText: t.serverHint,
                            ),
                          ),
                          // A saída para quem ficou com um endereço salvo que
                          // não responde mais. Sem ela, o único conserto seria
                          // reinstalar o app.
                          Center(
                            child: TextButton(
                              style: TextButton.styleFrom(foregroundColor: c.texto2),
                              onPressed: () =>
                                  setState(() => _server.text = backendPadrao),
                              child: Text(t.voltarAoServidorPadrao),
                            ),
                          ),
                        ] else
                          Center(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: c.texto3,
                                textStyle: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                              onPressed: () => setState(() => _servidorAberto = true),
                              child: Text(t.usarOutroServidor),
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
