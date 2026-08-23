import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';

/// Para onde escrever enquanto o pagamento é feito à mão.
const contatoDeskside = 'contato@deskside.com.br';

/// O que o app faz quando o servidor recusa por causa do plano.
///
/// ## Por que existe um arquivo só para isto
///
/// O servidor devolve `402` com uma frase pronta ("modo apresentação faz parte
/// do Deskside pago"), e essa frase já apareceria sozinha no aviso vermelho de
/// erro que toda tela tem. Funcionaria — e seria a pior versão possível.
///
/// Um limite de plano **não é um erro**. Mostrá-lo em vermelho, no mesmo lugar
/// onde aparece "não consegui falar com o computador", ensina a pessoa a ler
/// aquilo como defeito. Ela tenta de novo, tenta em outro aparelho, e conclui
/// que o produto está quebrado — quando o que houve foi o produto dizendo que
/// existe mais.
///
/// Aqui vira uma conversa: o que é, o que dá para fazer, e uma saída.
///
/// ## Por que não há botão de assinar
///
/// Porque não há como assinar ainda. Um botão "Assinar" que abrisse uma tela
/// vazia — ou pior, que não fizesse nada — custaria mais confiança do que a
/// recusa inteira. Enquanto o pagamento for feito à mão, o caminho honesto é
/// dizer isso e abrir o e-mail.
library;

/// O `402` do servidor: "você poderia, pagando".
///
/// Separado do `403` de propósito no backend, e é esta função que colhe o
/// proveito: sem o código próprio, o app teria de adivinhar pelo texto — e
/// adivinhar por texto quebra no dia em que alguém reescreve a frase.
bool ehLimiteDePlano(Object erro) =>
    erro is ApiException && erro.statusCode == 402;

/// Mostra a recusa como oferta, e não como falha.
///
/// [mensagem] é a frase do servidor, que diz **o que** foi recusado. Ela vem de
/// lá porque é lá que a regra mora: o app não sabe (e não deve saber) quais
/// recursos são pagos hoje.
Future<void> mostrarLimiteDePlano(
  BuildContext context,
  Strings t,
  String mensagem,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogo) => AlertDialog(
      icon: const Icon(Icons.workspace_premium_outlined),
      title: Text(t.planoLimiteTitulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mensagem),
          const SizedBox(height: 12),
          SelectableText(
            contatoDeskside,
            style: Theme.of(dialogo).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            t.planoComoAssinar,
            style: Theme.of(dialogo).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogo).pop(),
          child: Text(t.planoAgoraNao),
        ),
        FilledButton.icon(
          // **Copiar**, e não abrir o app de e-mail. Nem todo aparelho tem um
          // configurado, e um `mailto:` que não abre nada deixa a pessoa
          // achando que o botão está quebrado. Copiar funciona em qualquer
          // aparelho e ela cola onde quiser — inclusive no WhatsApp.
          //
          // E não é um botão que só fecha o diálogo: aquilo seria exatamente o
          // "botão que não faz nada" que esta tela existe para evitar.
          onPressed: () {
            Clipboard.setData(const ClipboardData(text: contatoDeskside));
            Navigator.of(dialogo).pop();
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(t.planoEmailCopiado)));
          },
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: Text(t.planoCopiarEmail),
        ),
      ],
    ),
  );
}
