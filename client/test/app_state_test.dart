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

  group('sem internet', () {
    // O defeito: aberto em modo avião, o app ficava com a lista vazia e a
    // conta nula até ser fechado e aberto de novo — e o cartão do plano lia a
    // conta nula como "grátis", com o botão Assinar, para quem paga.

    late bool rede;
    late InMemoryTokenStore tokens;

    ApiClient cliente() => ApiClient(
          baseUrl: 'http://test',
          tokenStore: tokens,
          httpClient: MockClient((req) async {
            if (!rede) throw http.ClientException('sem rede');
            final caminho = req.url.path;
            if (caminho.contains('login') || caminho.contains('refresh')) {
              return http.Response(
                  jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
            }
            if (caminho == '/api/v1/auth/me') {
              return http.Response(
                jsonEncode({'id': 1, 'email': 'a@b.com', 'plano': 'pago'}),
                200,
              );
            }
            if (caminho == '/api/v1/devices') {
              return http.Response(
                jsonEncode([
                  {
                    'device_id': 'pc-1',
                    'name': 'PC da sala',
                    'os': 'windows',
                    'hostname': 'PC',
                    'online': true,
                  }
                ]),
                200,
              );
            }
            return http.Response(jsonEncode([]), 200);
          }),
        );

    setUp(() {
      rede = true;
      tokens = InMemoryTokenStore();
    });

    test('abrir sem rede não vira "grátis" nem lista vazia de verdade',
        () async {
      // Sessão salva de uma abertura anterior.
      await tokens.save('a', 'r');
      rede = false;
      final state = AppState(cliente());

      await state.restoreSession();

      expect(state.isAuthenticated, isTrue, reason: 'sem rede não desloga');
      expect(state.semConexao, isTrue);
      // Conta nula é "não sei", e é assim que o cartão do plano a lê agora.
      expect(state.conta, isNull);

      // A internet volta: a próxima tentativa traz tudo, sem reabrir o app.
      rede = true;
      await state.recarregar();
      expect(state.semConexao, isFalse);
      expect(state.devices, hasLength(1));
      expect(state.conta?.ehPago, isTrue);
      state.dispose();
    });

    test('a rede cair com o app aberto não apaga a lista nem a conta',
        () async {
      final state = AppState(cliente());
      await state.login('senhaSegura123!', email: 'a@b.com');
      expect(state.devices, hasLength(1));

      rede = false;
      await state.recarregar();

      expect(state.semConexao, isTrue);
      expect(state.devices, hasLength(1));
      expect(state.conta?.ehPago, isTrue);
      state.dispose();
    });

    test('sair da conta para as novas tentativas', () async {
      final state = AppState(cliente());
      await state.login('senhaSegura123!', email: 'a@b.com');
      rede = false;
      await state.recarregar();
      expect(state.semConexao, isTrue);

      rede = true;
      await state.logout();
      expect(state.semConexao, isFalse);
      expect(state.devices, isEmpty);
      state.dispose();
    });
  });
}
