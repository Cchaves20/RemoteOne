import 'package:deskside_client/models/automation.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/atalhos_do_icone.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Automation automacao(String id, String nome) => Automation(id: id, name: nome);

  test('o ícone mostra até quatro automações, na ordem da conta', () {
    final itens = itensDoIcone([
      for (var i = 1; i <= 6; i++) automacao('a$i', 'Rotina $i'),
    ]);
    expect(itens.map((i) => i.localizedTitle),
        ['Rotina 1', 'Rotina 2', 'Rotina 3', 'Rotina 4']);
    expect(itens.first.type, 'automacao:a1');
  });

  test('automação ainda não salva não vira atalho', () {
    // Sem id, o atalho não teria o que pedir ao servidor.
    expect(itensDoIcone([automacao('', 'Rascunho')]), isEmpty);
  });

  test('o toque volta a ser a automação certa', () {
    expect(automacaoDoAtalho('automacao:abc'), 'abc');
    expect(automacaoDoAtalho('automacao:'), isNull);
    expect(automacaoDoAtalho('outra-coisa:abc'), isNull);
  });

  test('o pedido do ícone é entregue uma vez só', () {
    // Senão a automação rodaria de novo a cada redesenho da tela.
    final state = AppState(
      ApiClient(baseUrl: 'http://test', tokenStore: InMemoryTokenStore()),
    );
    state.receberAtalho('automacao:abc');
    expect(state.tomarAtalho(), 'automacao:abc');
    expect(state.tomarAtalho(), isNull);
    state.dispose();
  });
}
