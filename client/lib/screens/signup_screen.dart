import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../services/senha.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/identidade.dart';
import '../widgets/links_legais.dart';
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
  bool _verSenha = false;

  /// A caixa de aceite dos termos e da privacidade. Começa desmarcada: um
  /// aceite que vem marcado não é escolha de ninguém.
  bool _aceitou = false;
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
      _confere &&
      _aceitou;

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
        email: _contato.text.trim(),
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
      // O brilho da marca começa atrás da barra do título, e não abaixo
      // dela: senão a barra vira uma faixa lisa cortando o brilho.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(t.createAccountTitle),
        backgroundColor: Colors.transparent,
      ),
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
                            autofillHints: const [AutofillHints.givenName],
                            decoration: InputDecoration(labelText: t.firstName),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _sobrenome,
                            textCapitalization: TextCapitalization.words,
                            autofillHints: const [AutofillHints.familyName],
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
                          prefixIcon: const Icon(Icons.calendar_today_outlined, size: 20),
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
                    // Só e-mail. O cadastro por telefone foi removido das
                    // telas enquanto não houver provedor de SMS: a habilitação
                    // no Brasil pede CNPJ, e oferecer um caminho que manda o
                    // código para o registro do servidor é pior do que não
                    // oferecer. O backend continua aceitando telefone, e
                    // `models/pais.dart` guarda a normalização — voltar é
                    // trabalho de tela, não de protocolo.
                    TextField(
                      controller: _contato,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: t.email),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _senha,
                      obscureText: !_verSenha,
                      autofillHints: const [AutofillHints.newPassword],
                      decoration: InputDecoration(
                        labelText: t.password,
                        suffixIcon: IconButton(
                          tooltip: _verSenha ? t.esconderSenha : t.mostrarSenha,
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
                        // O erro só aparece depois de a pessoa começar a
                        // digitar: acusar "não confere" num campo vazio seria
                        // brigar com quem ainda nem tentou.
                        errorText: _confirmacao.text.isEmpty || _confere
                            ? null
                            : t.passwordMismatch,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Checkbox(
                          key: const Key('cadastro-aceite'),
                          value: _aceitou,
                          onChanged: (v) => setState(() => _aceitou = v ?? false),
                        ),
                        Expanded(
                          child: TextoDeAceite(
                            state: widget.state,
                            estilo: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                    if (_erro != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _erro!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 22),
                    BotaoDeskside(
                      rotulo: t.continueButton,
                      largo: true,
                      carregando: _enviando,
                      onPressed: _completo ? _enviar : null,
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
  ///
  /// Etiquetas que acendem (com a cor de "ao vivo" e um tique) conforme a
  /// regra é cumprida.
  Widget _regras(Strings t, ThemeData theme) {
    final c = context.cores;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final regra in RegraDeSenha.values)
          Builder(builder: (context) {
            final ok = regra.cumprida(_senha.text);
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: ok ? c.aoVivoFundo : c.superficieAlta,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ok) ...[
                    Icon(Icons.check_rounded, size: 14, color: c.aoVivo),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    regra.rotulo(t),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: ok ? c.aoVivo : c.texto3,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  static String _formatar(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
