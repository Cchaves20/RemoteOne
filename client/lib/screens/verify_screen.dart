import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/cadastro.dart';
import '../models/pais.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../widgets/brand.dart';

/// A segunda etapa do cadastro: digitar o código que chegou.
///
/// É aqui que a conta passa a existir. Até este ponto o servidor guarda um
/// cadastro pendente e mais nada — quem fecha a tela sem digitar o código não
/// deixou conta nenhuma para trás.
///
/// **Dá para voltar**, e isso não é cortesia: o erro mais comum desta tela é ter
/// digitado o número errado na anterior, e a correção é lá. A tela de cadastro
/// continua viva na pilha, com tudo preenchido.
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key, required this.state, required this.pendente});

  final AppState state;
  final SignupPending pendente;

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _codigo = TextEditingController();
  late SignupPending _pendente = widget.pendente;

  Timer? _relogio;
  int _faltam = 0;
  bool _enviando = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _codigo.addListener(() => setState(() {}));
    _comecarContagem(_pendente.resendInSeconds);
  }

  @override
  void dispose() {
    _relogio?.cancel();
    _codigo.dispose();
    super.dispose();
  }

  /// A contagem até o reenviar valer.
  ///
  /// Mostrar o tempo, em vez de só desabilitar o botão, é o que separa "espere"
  /// de "não funciona": um botão apagado sem explicação parece defeito.
  void _comecarContagem(int segundos) {
    _relogio?.cancel();
    setState(() => _faltam = segundos);
    _relogio = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _faltam--);
      if (_faltam <= 0) t.cancel();
    });
  }

  Future<void> _confirmar() async {
    final t = widget.state.t;
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      await widget.state.signupVerify(_pendente.destination, _codigo.text.trim());
      if (!mounted) return;
      // Sai da pilha inteira do cadastro: a sessão começou, e voltar para o
      // formulário depois disso não faria sentido nenhum.
      Navigator.of(context).popUntil((rota) => rota.isFirst);
    } on ApiException catch (e) {
      // A mensagem vem do servidor porque é ela que sabe quantas tentativas
      // sobraram, e se o que expirou foi o código ou o cadastro inteiro.
      if (mounted) {
        setState(() => _erro = e.message);
        _codigo.clear();
      }
    } catch (_) {
      if (mounted) setState(() => _erro = t.networkError);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _reenviar() async {
    final t = widget.state.t;
    setState(() => _erro = null);
    try {
      final novo = await widget.state.signupResend(_pendente.destination);
      if (!mounted) return;
      setState(() => _pendente = novo);
      _comecarContagem(novo.resendInSeconds);
      _codigo.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.codeResent)));
    } on ApiException catch (e) {
      if (mounted) setState(() => _erro = e.message);
    } catch (_) {
      if (mounted) setState(() => _erro = t.networkError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    final theme = Theme.of(context);
    final podeReenviar = _faltam <= 0;
    return Scaffold(
      appBar: AppBar(title: Text(t.verifyTitle)),
      body: AuroraBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      _pendente.porEmail
                          ? Icons.mark_email_unread_outlined
                          : Icons.sms_outlined,
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _pendente.porEmail ? t.verifySentEmail : t.verifySentSms,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    // Mascarado: a tela pode estar sendo vista por outra pessoa,
                    // e os quatro últimos bastam para reconhecer o próprio
                    // número.
                    Text(
                      mascararDestino(_pendente.destination),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (!_pendente.delivered) ...[
                      const SizedBox(height: 14),
                      // O servidor está sem provedor e o código foi para o
                      // diário. Sem este aviso, a pessoa esperaria uma mensagem
                      // que nunca vai chegar e concluiria que o app quebrou.
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
                    const SizedBox(height: 24),
                    TextField(
                      controller: _codigo,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 6,
                      // Só dígitos: o código é numérico, e deixar entrar letra
                      // só produziria uma tentativa gasta à toa — e as
                      // tentativas são cinco.
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: theme.textTheme.headlineMedium?.copyWith(
                        letterSpacing: 12,
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: '······',
                        errorText: _erro,
                      ),
                      onSubmitted: (_) {
                        if (_codigo.text.length == 6) _confirmar();
                      },
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: (_codigo.text.length == 6 && !_enviando)
                          ? _confirmar
                          : null,
                      child: _enviando
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(t.verifyConfirm),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: podeReenviar ? _reenviar : null,
                      child: Text(
                        podeReenviar ? t.resendCode : t.resendIn(_faltam),
                      ),
                    ),
                    // Voltar para corrigir o contato. Explícito, e não só o
                    // botão da barra: o erro típico desta tela é ter digitado o
                    // número errado, e a correção é na tela anterior.
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(
                        _pendente.porEmail ? t.changeEmail : t.changePhone,
                      ),
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
