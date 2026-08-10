import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/pais.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../services/senha.dart';
import '../widgets/brand.dart';
import 'verify_screen.dart';

/// Criação de conta: o formulário inteiro, antes da verificação.
///
/// Tela própria, e não mais um botão que troca dois campos na tela de login:
/// são sete campos, um seletor de país e uma lista de regras de senha que
/// precisa de espaço para ser lida. Espremer isso no login faria as duas coisas
/// piores.
///
/// **Tudo é validado aqui e conferido de novo no servidor.** A validação daqui
/// existe para explicar enquanto a pessoa digita; a de lá é a que decide.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _nome = TextEditingController();
  final _sobrenome = TextEditingController();
  final _contato = TextEditingController();
  final _senha = TextEditingController();
  final _confirmacao = TextEditingController();

  DateTime? _nascimento;
  Pais _pais = Pais.padrao;

  /// Se o contato é telefone. Falso = e-mail.
  bool _porTelefone = false;
  bool _verSenha = false;
  bool _enviando = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    // Redesenha a cada tecla para a lista de regras acender em tempo real —
    // é o que transforma "senha inválida" em "falta um número".
    _senha.addListener(_redesenhar);
    _confirmacao.addListener(_redesenhar);
  }

  void _redesenhar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nome.dispose();
    _sobrenome.dispose();
    _contato.dispose();
    _senha.dispose();
    _confirmacao.dispose();
    super.dispose();
  }

  bool get _confere =>
      _confirmacao.text.isNotEmpty && _confirmacao.text == _senha.text;

  bool get _completo =>
      _nome.text.trim().isNotEmpty &&
      _sobrenome.text.trim().isNotEmpty &&
      _nascimento != null &&
      _contato.text.trim().isNotEmpty &&
      senhaValida(_senha.text) &&
      _confere;

  Future<void> _escolherData() async {
    final t = widget.state.t;
    final hoje = DateTime.now();
    final escolhida = await showDatePicker(
      context: context,
      initialDate: _nascimento ?? DateTime(hoje.year - 25, hoje.month, hoje.day),
      firstDate: DateTime(hoje.year - 120),
      // O calendário já não deixa escolher o futuro: é mais honesto que aceitar
      // e recusar depois.
      lastDate: hoje,
      helpText: t.birthDate,
    );
    if (escolhida != null) setState(() => _nascimento = escolhida);
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

  Future<void> _enviar() async {
    final t = widget.state.t;
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      final pendente = await widget.state.signupStart(
        firstName: _nome.text.trim(),
        lastName: _sobrenome.text.trim(),
        birthDate: _nascimento!,
        email: _porTelefone ? null : _contato.text.trim(),
        phone: _porTelefone ? _contato.text.trim() : null,
        country: _porTelefone ? _pais.iso : null,
        password: _senha.text,
        passwordConfirm: _confirmacao.text,
      );
      if (!mounted) return;
      // `push` e não `pushReplacement`: a tela de verificação precisa poder
      // **voltar para cá** com o formulário intacto — quem errou o número quer
      // corrigir o número, não preencher tudo de novo.
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VerifyScreen(state: widget.state, pendente: pendente),
        ),
      );
    } on ApiException catch (e) {
      // A mensagem do servidor é a boa: ela diz *o que* falta na senha, ou por
      // que o número não serve para aquele país. Trocá-la por um texto genérico
      // jogaria fora a única explicação que existe.
      if (mounted) setState(() => _erro = e.message);
    } catch (e) {
      if (mounted) setState(() => _erro = t.networkError);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.createAccountTitle)),
      body: AuroraBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _nome,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(labelText: t.firstName),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _sobrenome,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(labelText: t.lastName),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: _escolherData,
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: t.birthDate,
                          prefixIcon: const Icon(Icons.cake_outlined),
                        ),
                        child: Text(
                          _nascimento == null
                              ? t.birthDateHint
                              : _formatar(_nascimento!),
                          style: TextStyle(
                            color: _nascimento == null
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    // A escolha entre e-mail e telefone vem **antes** do campo,
                    // e não como um segundo campo opcional: são duas formas de
                    // dizer a mesma coisa, e dois campos fariam parecer que se
                    // pede as duas.
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
                        // Limpa: um e-mail escrito no campo de telefone não é
                        // um telefone, e deixá-lo lá convidaria a mandar.
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
                              child: Text(
                                '${_pais.bandeira} +${_pais.ddi}',
                                style: theme.textTheme.bodyLarge,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _contato,
                              keyboardType: TextInputType.phone,
                              // Sem filtro de entrada: espaço, parêntese e
                              // hífen são como as pessoas escrevem número, e
                              // quem limpa é a normalização.
                              decoration: InputDecoration(
                                labelText: t.phone,
                                hintText: t.phoneHint,
                              ),
                              onChanged: (_) => setState(() {}),
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
                        onChanged: (_) => setState(() {}),
                      ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _senha,
                      obscureText: !_verSenha,
                      decoration: InputDecoration(
                        labelText: t.password,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_verSenha
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          onPressed: () => setState(() => _verSenha = !_verSenha),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _regras(t, theme),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _confirmacao,
                      obscureText: !_verSenha,
                      decoration: InputDecoration(
                        labelText: t.passwordConfirm,
                        prefixIcon: const Icon(Icons.lock_reset_outlined),
                        // O erro só aparece depois de a pessoa começar a
                        // digitar: acusar "não confere" num campo vazio seria
                        // brigar com quem ainda nem tentou.
                        errorText: _confirmacao.text.isEmpty || _confere
                            ? null
                            : t.passwordMismatch,
                      ),
                    ),
                    if (_erro != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _erro!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: (_completo && !_enviando) ? _enviar : null,
                      child: _enviando
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(t.continueButton),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t.signupCodeExplain,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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

  /// As cinco regras, acendendo enquanto se digita.
  ///
  /// Todas visíveis desde o começo, e não uma de cada vez: um formulário que
  /// revela uma exigência por vez faz a pessoa tentar cinco vezes para
  /// descobrir cinco regras.
  Widget _regras(Strings t, ThemeData theme) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final regra in RegraDeSenha.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                regra.cumprida(_senha.text)
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                size: 15,
                color: regra.cumprida(_senha.text)
                    ? Colors.greenAccent
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                regra.rotulo(t),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: regra.cumprida(_senha.text)
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }

  static String _formatar(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
