import 'dart:async';
import 'dart:convert';

import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A abertura do app: os pedidos da recarga saem juntos, e não em fila.
///
/// Em fila, a lista de computadores só aparecia depois da quarta ida e volta
/// ao servidor. O teste segura toda resposta até os quatro pedidos chegarem:
/// em fila, o segundo nunca sairia, e a conta daria um só.
void main() {
  const caminhos = {
    '/api/v1/devices',
    '/api/v1/auth/me',
    '/api/v1/automations',
    '/api/v1/widget',
  };

  http.Response responder(String caminho, {int codigoDaConta = 200}) {
    switch (caminho) {
      case '/api/v1/auth/me':
        if (codigoDaConta != 200) {
          return http.Response(jsonEncode({'detail': 'erro'}), codigoDaConta);
        }
        return http.Response(
          jsonEncode({'id': 1, 'email': 'a@b.com', 'plano': 'pago'}),
          200,
        );
      case '/api/v1/devices':
        return http.Response(
          jsonEncode([
            {
              'device_id': 'pc-1',
              'name': 'PC',
              'os': 'windows',
              'hostname': 'PC',
              'online': true,
            }
          ]),
          200,
        );
      default:
        return http.Response(jsonEncode([]), 200);
    }
  }

  Future<AppState> logado(MockClient rede) async {
    final tokens = InMemoryTokenStore();
    await tokens.save('a', 'r');
    final state = AppState(
      ApiClient(baseUrl: 'http://test', tokenStore: tokens, httpClient: rede),
    );
    await state.restoreSession();
    return state;
  }

  test('os quatro pedidos da recarga saem ao mesmo tempo', () async {
    var simultaneos = 0;
    var maximo = 0;
    var segurando = false;
    final liberar = Completer<void>();

    final state = await logado(MockClient((req) async {
      final caminho = req.url.path;
      if (!segurando || !caminhos.contains(caminho)) {
        return responder(caminho);
      }
      simultaneos++;
      if (simultaneos > maximo) maximo = simultaneos;
      if (simultaneos == caminhos.length && !liberar.isCompleted) {
        liberar.complete();
      }
      // Em fila, os outros nunca chegariam: o prazo evita travar o teste.
      await liberar.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
      simultaneos--;
      return responder(caminho);
    }));

    segurando = true;
    await state.recarregar();

    expect(maximo, caminhos.length,
        reason: 'os pedidos têm de estar no ar juntos');
    expect(state.devices, hasLength(1));
    expect(state.conta?.ehPago, isTrue);
    state.dispose();
  });

  test('erro do servidor continua sendo erro do servidor, e não "sem rede"',
      () async {
    // O `Future.wait` repassa o erro como ele é. Se ele viesse embrulhado,
    // o `on ApiException` não pegaria e o app mostraria "sem conexão" com o
    // servidor respondendo.
    var quebrar = false;
    final state = await logado(MockClient((req) async => responder(
          req.url.path,
          codigoDaConta: quebrar ? 500 : 200,
        )));
    expect(state.devices, hasLength(1));

    quebrar = true;
    await state.recarregar();

    expect(state.semConexao, isFalse);
    expect(state.devices, hasLength(1), reason: 'a lista de antes fica');
    state.dispose();
  });

  test('automações e widget falhando não derrubam a lista', () async {
    final state = await logado(MockClient((req) async {
      final caminho = req.url.path;
      if (caminho == '/api/v1/automations' || caminho == '/api/v1/widget') {
        return http.Response(jsonEncode({'detail': 'não existe'}), 404);
      }
      return responder(caminho);
    }));

    expect(state.devices, hasLength(1));
    expect(state.conta?.ehPago, isTrue);
    expect(state.semConexao, isFalse);
    state.dispose();
  });
}
