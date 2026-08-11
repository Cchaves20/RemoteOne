import 'dart:convert';

import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// O estado que sobra de uma sessão que acabou.
///
/// O defeito que estes testes fecham apareceu em uso: criar uma conta por
/// e-mail e encontrar "Alterar telefone" na tela de conta, com o número de uma
/// conta **excluída**. Nada dava erro — o app só estava mostrando quem tinha
/// estado logado antes.
///
/// É a mesma armadilha das cascatas do `User` no servidor, um andar acima: o
/// que não for explicitamente descartado não fica esquecido, reaparece como
/// dado de outra pessoa.
void main() {
  /// Um cliente que devolve a conta pedida em `/auth/me` e vazio no resto.
  ApiClient clienteQueDevolve({String? email, String? phone}) => ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          // Pelo método, e não só pelo caminho: `DELETE /auth/me` é a
          // exclusão da conta, e ela espera 204.
          if (req.url.path == '/api/v1/auth/me' && req.method == 'GET') {
            return http.Response(
              jsonEncode({
                'id': 1,
                'email': email,
                'phone': phone,
                'totp_enabled': false,
              }),
              200,
            );
          }
          if (req.url.path == '/api/v1/auth/me' && req.method == 'DELETE') {
            return http.Response('', 204);
          }
          if (req.url.path.contains('signup/verify') ||
              req.url.path.contains('login')) {
            return http.Response(
              jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
              req.url.path.contains('signup') ? 201 : 200,
            );
          }
          return http.Response(jsonEncode([]), 200);
        }),
      );

  test('criar conta relê o /me e não herda a conta anterior', () async {
    // O caminho exato do defeito: `signupVerify` era o único jeito de entrar
    // que não lia o `/me`, e por isso a conta de antes continuava na tela.
    final state = AppState(clienteQueDevolve(email: 'novo@example.com'));
    state.conta = null;

    await state.signupVerify('novo@example.com', '123456');

    expect(state.conta, isNotNull);
    expect(state.conta!.email, 'novo@example.com');
    expect(state.conta!.porTelefone, isFalse,
        reason: 'a tela de conta mostraria "Alterar telefone"');
  });

  test('sair esquece a conta, e não só a lista de computadores', () async {
    final state = AppState(clienteQueDevolve(phone: '+5511999998888'));
    await state.login('senhaSegura123!', phone: '11999998888', country: 'BR');
    expect(state.conta!.porTelefone, isTrue);

    await state.logout();

    expect(state.conta, isNull);
    expect(state.twoFactorEnabled, isFalse);
  });

  test('excluir a conta esquece a conta', () async {
    // Sem isto, apagar uma conta de telefone e criar uma de e-mail em seguida
    // deixava o número da conta morta embaixo do botão da conta nova.
    final state = AppState(clienteQueDevolve(phone: '+5511999998888'));
    await state.login('senhaSegura123!', phone: '11999998888', country: 'BR');

    await state.deleteAccount('senhaSegura123!');

    expect(state.conta, isNull);
    expect(state.devices, isEmpty);
  });
}
