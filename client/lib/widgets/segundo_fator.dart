import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';

/// Faz [acao] e, se o servidor pedir o segundo fator, pede o código e refaz.
///
/// Devolve `true` quando a ação passou e `false` quando a pessoa desistiu.
/// Qualquer outro erro (senha errada, tentativas demais) sobe para quem chamou,
/// que já sabe mostrá-lo.
///
/// **Pergunta só quando o servidor pede**, em vez de o app decidir antes se a
/// conta tem a verificação ligada. No "esqueci a senha" o app nem sabe — quem
/// sabe é o servidor —, e uma regra só para todas as portas é uma regra que
/// não fica desatualizada numa delas.
///
/// [pedirAntes] é para a rota que sempre exige o código (gerar códigos novos):
/// chamá-la sem ele seria uma viagem garantidamente perdida.
Future<bool> comSegundoFator(
  BuildContext context,
  Strings t,
  Future<void> Function(String? codigo) acao, {
  bool pedirAntes = false,
}) async {
  String? codigo;
  var errou = false;
  if (pedirAntes) {
    codigo = await pedirSegundoFator(context, t);
    if (codigo == null) return false;
  }
  while (true) {
    try {
      await acao(codigo);
      return true;
    } on ApiException catch (e) {
      if (!e.pedeSegundoFator && !e.segundoFatorErrado) rethrow;
      errou = e.segundoFatorErrado;
    }
    if (!context.mounted) return false;
    codigo = await pedirSegundoFator(context, t, errou: errou);
    if (codigo == null) return false;
  }
}

/// A janela do código: o do autenticador ou, pelo link, um de recuperação.
/// Devolve o que foi digitado, ou `null` se a pessoa cancelou.
Future<String?> pedirSegundoFator(
  BuildContext context,
  Strings t, {
  bool errou = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _JanelaDoCodigo(t: t, errou: errou),
    );

class _JanelaDoCodigo extends StatefulWidget {
  const _JanelaDoCodigo({required this.t, required this.errou});

  final Strings t;
  final bool errou;

  @override
  State<_JanelaDoCodigo> createState() => _JanelaDoCodigoState();
}

class _JanelaDoCodigoState extends State<_JanelaDoCodigo> {
  final _codigo = TextEditingController();
  bool _recuperacao = false;

  @override
  void initState() {
    super.initState();
    _codigo.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  /// Seis dígitos, ou os dez caracteres do código de recuperação (o traço e
  /// os espaços o servidor ignora).
  bool get _completo {
    final texto = _codigo.text.trim();
    if (!_recuperacao) return texto.length == 6;
    return texto.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length == 10;
  }

  void _confirmar() {
    if (_completo) Navigator.pop(context, _codigo.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return AlertDialog(
      title: Text(t.secondFactorTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_recuperacao ? t.secondFactorRecoveryBody : t.secondFactorBody),
          const SizedBox(height: 12),
          TextField(
            // A chave muda com o modo para o campo nascer de novo com o
            // teclado certo: trocar `keyboardType` num campo aberto não troca
            // o teclado que já está na tela.
            key: ValueKey(_recuperacao),
            controller: _codigo,
            autofocus: true,
            autocorrect: false,
            keyboardType:
                _recuperacao ? TextInputType.text : TextInputType.number,
            textCapitalization: _recuperacao
                ? TextCapitalization.characters
                : TextCapitalization.none,
            maxLength: _recuperacao ? 11 : 6,
            inputFormatters: [
              if (!_recuperacao) FilteringTextInputFormatter.digitsOnly,
            ],
            onSubmitted: (_) => _confirmar(),
            decoration: InputDecoration(
              counterText: '',
              labelText: _recuperacao ? t.recoveryCode : t.sixDigitCode,
              hintText: _recuperacao ? 'ABCDE-FGHJK' : null,
              // O erro só vale para o código que foi recusado: digitar outro
              // já é a correção.
              errorText: widget.errou && _codigo.text.isEmpty ? t.invalidCode : null,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _recuperacao = !_recuperacao;
                _codigo.clear();
              }),
              child: Text(
                _recuperacao ? t.useAuthenticatorCode : t.useRecoveryCode,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: _completo ? _confirmar : null,
          child: Text(t.verifyConfirm),
        ),
      ],
    );
  }
}
