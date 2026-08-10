import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/cadastro.dart';
import '../models/pais.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../services/senha.dart';
import '../widgets/brand.dart';

/// Esqueci minha senha: pedir o código e trocar a senha.
///
/// **Uma tela com duas fases**, e não duas telas como no cadastro. Lá a
/// primeira fase é um formulário de sete campos que precisa sobreviver ao
/// "voltar"; aqui é um campo só, e uma tela inteira para ele — mais o vaivém
/// entre as duas — seria cerimônia por nada.
///
/// A tela não diz, e não pode dizer, se a conta existe. Quem pede recuperação
/// para um endereço qualquer vê exatamente o que veria se a conta existisse. A
/// diferença viraria um jeito de descobrir quem tem conta no Deskside, e cada
/// conta aqui é um computador.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _contato = TextEditingController();
  final _codigo = TextEditingController();
  final _senha = TextEditingController();
  final _confirmacao = TextEditingController();

  bool _porTelefone = false;
  Pais _pais = Pais.padrao;
  bool _verSenha = false;
  bool _ocupado = false;
  String? _erro;

  /// `null` enquanto o código não foi pedido — é o que separa as duas fases.
  SignupPending? _pedido;

  Timer? _relogio;
  int _faltam = 0;

  @override
  void initState() {
    super.initState();
    for (final c in [_contato, _codigo, _senha, _confirmacao]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _relogio?.cancel();
    _contato.dispose();
    _codigo.dispose();
    _senha.dispose();
    _confirmacao.dispose();
    super.dispose();
  }

  bool get _confere =>
      _confirmacao.text.isNotEmpty && _confirmacao.text == _senha.text;

  bool get _podeTrocar =>
      _codigo.text.length == 6 && senhaValida(_senha.text) && _confere;

  void _comecarContagem(int segundos) {
    _relogio?.cancel();
    setState(() => _faltam = segundos);
    _relogio = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _faltam--);
      if (_faltam <= 0) t.cancel();
    });
  }

  Future<void> _pedirCodigo() async {
    setState(() {
      _ocupado = true;
      _erro = null;
    });
    try {
      final pedido = await widget.state.forgotPassword(
        email: _porTelefone ? null : _contato.text.trim(),
        phone: _porTelefone ? _contato.text.trim() : null,
        country: _porTelefone ? _pais.iso : null,
      );
      if (!mounted) return;
      setState(() => _pedido = pedido);
      _comecarContagem(pedido.resendInSeconds);
    } on ApiException catch (e) {
      if (mounted) setState(() => _erro = e.message);
    } catch (_) {
      if (mounted) setState(() => _erro = widget.state.t.networkError);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _trocarSenha() async {
    setState(() {
      _ocupado = true;
      _erro = null;
    });
    try {
      await widget.state.resetPassword(
        _pedido!.destination,
        _codigo.text.trim(),
        _senha.text,
        _confirmacao.text,
      );
      if (!mounted) return;
      // A sessão já começou: o servidor devolve os tokens junto. Volta ao
      // início em vez de ao login — pedir para entrar agora seria pedir a senha
      // que a pessoa acabou de criar, que é justamente a que ainda não decorou.
      Navigator.of(context).popUntil((rota) => rota.isFirst);
    } on ApiException catch (e) {
      if (mounted) setState(() => _erro = e.message);
    } catch (_) {
      if (mounted) setState(() => _erro = widget.state.t.networkError);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.forgotTitle)),
      body: AuroraBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _pedido == null
                    ? _fasePedir(t, theme)
                    : _faseTrocar(t, theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fasePedir(Strings t, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.lock_reset, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 18),
        Text(
          t.forgotExplain,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
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
            autofocus: true,
            decoration: InputDecoration(
              labelText: t.email,
              prefixIcon: const Icon(Icons.alternate_email),
            ),
          ),
        if (_erro != null) ...[
          const SizedBox(height: 14),
          Text(_erro!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 22),
        FilledButton(
          onPressed: (_contato.text.trim().isEmpty || _ocupado)
              ? null
              : _pedirCodigo,
          child: _ocupado
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(t.forgotSend),
        ),
      ],
    );
  }

  Widget _faseTrocar(Strings t, ThemeData theme) {
    final pedido = _pedido!;
    final podeReenviar = _faltam <= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          pedido.porEmail
              ? Icons.mark_email_unread_outlined
              : Icons.sms_outlined,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 18),
        Text(
          // O mesmo texto do cadastro, e de propósito: é o mesmo código, pelo
          // mesmo caminho, com o mesmo prazo. Duas redações para a mesma coisa
          // fariam parecer dois mecanismos.
          pedido.porEmail ? t.verifySentEmail : t.verifySentSms,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 6),
        Text(
          mascararDestino(pedido.destination),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (!pedido.delivered) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              t.verifyNotDelivered,
              style: TextStyle(
                color: theme.colorScheme.onErrorContainer,
                fontSize: 12,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _codigo,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 10),
          decoration: const InputDecoration(counterText: '', hintText: '······'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _senha,
          obscureText: !_verSenha,
          decoration: InputDecoration(
            labelText: t.newPassword,
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
        // As mesmas cinco regras do cadastro, acendendo enquanto se digita: a
        // senha nova passa pela mesma política, e descobrir isso por um erro do
        // servidor seria descobrir tarde.
        Wrap(
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
                  Text(regra.rotulo(t), style: theme.textTheme.bodySmall),
                ],
              ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmacao,
          obscureText: !_verSenha,
          decoration: InputDecoration(
            labelText: t.passwordConfirm,
            prefixIcon: const Icon(Icons.lock_reset_outlined),
            errorText: _confirmacao.text.isEmpty || _confere
                ? null
                : t.passwordMismatch,
          ),
        ),
        if (_erro != null) ...[
          const SizedBox(height: 14),
          Text(_erro!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 22),
        FilledButton(
          onPressed: (_podeTrocar && !_ocupado) ? _trocarSenha : null,
          child: _ocupado
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(t.forgotChange),
        ),
        TextButton(
          onPressed: (podeReenviar && !_ocupado) ? _pedirCodigo : null,
          child: Text(podeReenviar ? t.resendCode : t.resendIn(_faltam)),
        ),
        // Voltar à primeira fase, para corrigir o contato. O erro típico aqui é
        // ter digitado o endereço errado, e a correção é uma tela acima — que
        // neste caso é a mesma tela.
        TextButton.icon(
          onPressed: _ocupado
              ? null
              : () => setState(() {
                    _pedido = null;
                    _erro = null;
                    _codigo.clear();
                  }),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text(
            pedido.porEmail ? t.verifyChangeEmail : t.verifyChangePhone,
          ),
        ),
      ],
    );
  }
}
