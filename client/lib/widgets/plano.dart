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
/// Aqui vira uma conversa: o que é, o que dá para fazer, e onde se resolve.
///
/// ## Por que este aviso não abre a compra
///
/// Houve uma versão que abria, e ela saiu. A compra tem **uma** porta — o
/// botão no cartão "Seu plano", nos Ajustes — e este aviso aponta para ela em
/// vez de ser uma segunda.
///
/// Duas entradas para a mesma tela são duas telas para manter iguais: cada
/// regra nova sobre quem pode comprar precisa ser lembrada nas duas, e o dia
/// em que uma for esquecida o app vai oferecer, num canto, o que já não
/// oferece no outro.
///
/// O custo disto é real e vale registrar: quem esbarra num limite acabou de
/// tentar usar o recurso, e é o instante de maior vontade que vai existir.
/// Mandar essa pessoa até os Ajustes perde parte dela pelo caminho.
library;

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';

/// Para onde escrever quando alguém precisa falar com a gente.
const contatoDeskside = 'contato@deskside.com.br';

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
          Text(
            t.assinaturaChamada,
            style: Theme.of(dialogo).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          // A placa que aponta para a única porta. Sem ela o diálogo diria o
          // que falta e não diria onde se resolve, que é a metade que importa.
          Text(
            t.planoOndeAssinar,
            style: Theme.of(dialogo).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        // Um botão só, e ele fecha. Não é o "botão que não faz nada" que este
        // arquivo evita: aquele seria um **Assinar** que não assina. Aqui o
        // diálogo veio explicar, terminou de explicar, e sai.
        TextButton(
          key: const Key('plano-entendi'),
          onPressed: () => Navigator.of(dialogo).pop(),
          child: Text(t.planoEntendi),
        ),
      ],
    ),
  );
}
