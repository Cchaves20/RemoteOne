import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// O código de pareamento em caixas: nove, em três grupos de três, como o
/// computador mostra ("K7Q 4ZP 9M2").
///
/// Por baixo é um `TextField` só, invisível, que recebe o teclado, o colar e
/// o preenchimento automático; as caixas apenas desenham o que ele tem. Caixa
/// por caixa com um campo cada quebraria o colar e o apagar, que são os dois
/// gestos que mais se usa com um código.
class CampoDeCodigo extends StatefulWidget {
  const CampoDeCodigo({
    super.key,
    required this.controller,
    this.tamanho = 9,
    this.grupo = 3,
    this.onCompleto,
    this.rotulo,
    this.autofocus = true,
  });

  final TextEditingController controller;
  final int tamanho;
  final int grupo;
  final ValueChanged<String>? onCompleto;
  final String? rotulo;
  final bool autofocus;

  @override
  State<CampoDeCodigo> createState() => _CampoDeCodigoState();
}

class _CampoDeCodigoState extends State<CampoDeCodigo> {
  final _foco = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_mudou);
    _foco.addListener(_mudou);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_mudou);
    _foco.dispose();
    super.dispose();
  }

  void _mudou() {
    if (!mounted) return;
    setState(() {});
    final texto = widget.controller.text;
    if (texto.length == widget.tamanho) widget.onCompleto?.call(texto);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.cores;
    final texto = widget.controller.text;
    final caixas = <Widget>[];
    for (var i = 0; i < widget.tamanho; i++) {
      if (i > 0 && i % widget.grupo == 0) caixas.add(const SizedBox(width: 10));
      if (i > 0 && i % widget.grupo != 0) caixas.add(const SizedBox(width: 4));
      final atual = _foco.hasFocus && i == texto.length.clamp(0, widget.tamanho - 1);
      caixas.add(Expanded(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.superficie,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: atual ? c.aoVivo : c.linha,
              width: atual ? 1.6 : 1,
            ),
            boxShadow: atual
                ? [BoxShadow(color: c.aoVivo.withAlpha(40), spreadRadius: 3)]
                : null,
          ),
          child: Text(
            i < texto.length ? texto[i] : '',
            style: context.numeros.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: c.texto,
            ),
          ),
        ),
      ));
    }

    return Semantics(
      label: widget.rotulo,
      textField: true,
      value: texto,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _foco.requestFocus(),
        child: Stack(
          children: [
            // O campo de verdade, sem nada à vista: ele está aqui pelo
            // teclado, pelo colar e pelo leitor de tela.
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _foco,
                  autofocus: widget.autofocus,
                  autocorrect: false,
                  enableSuggestions: false,
                  showCursor: false,
                  textCapitalization: TextCapitalization.characters,
                  keyboardType: TextInputType.visiblePassword,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: widget.tamanho,
                  inputFormatters: [
                    // Colado "K7Q 4ZP 9M2" ou "k7q-4zp-9m2": vira "K7Q4ZP9M2".
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    TextInputFormatter.withFunction(
                      (velho, novo) => novo.copyWith(text: novo.text.toUpperCase()),
                    ),
                  ],
                  decoration: const InputDecoration(counterText: '', filled: false),
                ),
              ),
            ),
            IgnorePointer(child: Row(children: caixas)),
          ],
        ),
      ),
    );
  }
}
