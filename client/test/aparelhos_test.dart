import 'dart:convert';

import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/sessao.dart';
import 'package:deskside_client/services/aparelho.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('nome do aparelho', () {
    test('iPhone e iPad com a versão do sistema', () {
      const versao = 'Version 18.1 (Build 22B83)';
      expect(descreverAparelho(sistema: 'ios', versao: versao, tablet: false),
          'iPhone · iOS 18.1');
      expect(descreverAparelho(sistema: 'ios', versao: versao, tablet: true),
          'iPad · iPadOS 18.1');
    });

    test('Android sem versão, que o Dart não expõe', () {
      expect(
          descreverAparelho(
              sistema: 'android', versao: 'Linux 5.10 #1 SMP', tablet: false),
          'Celular Android');
      expect(descreverAparelho(sistema: 'android', versao: '', tablet: true),
          'Tablet Android');
    });

    test('versão em formato desconhecido fica de fora', () {
      expect(descreverAparelho(sistema: 'ios', versao: '???', tablet: false),
          'iPhone');
    });
  });

  test('tempo desde o último uso', () {
    const t = Strings(AppLanguage.ptBr);
    expect(t.usadoHa(const Duration(seconds: 20)), 'agora');
    expect(t.usadoHa(const Duration(minutes: 5)), 'há 5 min');
    expect(t.usadoHa(const Duration(hours: 3)), 'há 3 h');
    expect(t.usadoHa(const Duration(days: 1)), 'há 1 dia');
    expect(t.usadoHa(const Duration(days: 12)), 'há 12 dias');
  });

  test('Sessao lê o que o servidor manda', () {
    final s = Sessao.fromJson({
      'id': 'abc',
      'aparelho': 'iPhone · iOS 18.1',
      'criada_em': '2026-10-01T10:00:00+00:00',
      'ultimo_uso': '2026-10-19T10:00:00+00:00',
      'atual': true,
    });
    expect(s.aparelho, 'iPhone · iOS 18.1');
    expect(s.atual, isTrue);
    expect(s.ultimoUso.toUtc(), DateTime.utc(2026, 10, 19, 10));
  });

  test('o nome do aparelho vai no cabeçalho, codificado', () async {
    String? cabecalho;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        cabecalho = req.headers['X-Deskside-Aparelho'];
        return http.Response(
            jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
      }),
    )..aparelho = 'iPhone · iOS 18.1';
    await client.login('senha', email: 'a@b.com');
    expect(cabecalho, isNotNull);
    expect(Uri.decodeComponent(cabecalho!), 'iPhone · iOS 18.1');
  });

  group('renovação', () {
    test('pede a troca e guarda o refresh novo', () async {
      Map<String, dynamic>? pedido;
      final store = InMemoryTokenStore();
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/auth/refresh') {
            pedido = jsonDecode(req.body) as Map<String, dynamic>;
            return http.Response(
                jsonEncode({'access_token': 'a2', 'refresh_token': 'r2'}), 200);
          }
          return http.Response(
              jsonEncode({'access_token': 'a1', 'refresh_token': 'r1'}), 200);
        }),
      );
      await client.login('senha', email: 'a@b.com');
      await client.refreshAccess();

      expect(pedido?['refresh_token'], 'r1');
      expect(pedido?['rotacao'], isTrue);
      expect((await store.load()).$2, 'r2');
    });

    test('usa o refresh que outro processo já trocou', () async {
      // O widget da tela inicial renova num processo próprio, com o mesmo
      // armazenamento: mandar o da memória seria mandar um já trocado.
      final enviados = <String>[];
      final store = InMemoryTokenStore();
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/auth/refresh') {
            enviados.add(
                (jsonDecode(req.body) as Map<String, dynamic>)['refresh_token']
                    as String);
            return http.Response(
                jsonEncode({'access_token': 'a3', 'refresh_token': 'r3'}), 200);
          }
          return http.Response(
              jsonEncode({'access_token': 'a1', 'refresh_token': 'r1'}), 200);
        }),
      );
      await client.login('senha', email: 'a@b.com');
      await store.save('a2', 'r2'); // o widget renovou
      await client.refreshAccess();

      expect(enviados, ['r2']);
    });

    test('servidor antigo, sem refresh na resposta, mantém o atual', () async {
      final store = InMemoryTokenStore();
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/auth/refresh') {
            return http.Response(jsonEncode({'access_token': 'a2'}), 200);
          }
          return http.Response(
              jsonEncode({'access_token': 'a1', 'refresh_token': 'r1'}), 200);
        }),
      );
      await client.login('senha', email: 'a@b.com');
      await client.refreshAccess();
      expect(await store.load(), ('a2', 'r1'));
    });
  });

  test('sair avisa o servidor, e sai mesmo sem rede', () async {
    final caminhos = <String>[];
    var rede = true;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        caminhos.add(req.url.path);
        if (!rede) throw http.ClientException('sem rede');
        if (req.url.path == '/api/v1/auth/logout') return http.Response('', 204);
        return http.Response(
            jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
      }),
    );
    await client.login('senha', email: 'a@b.com');
    await client.sair();
    expect(caminhos, contains('/api/v1/auth/logout'));
    expect(client.isAuthenticated, isFalse);

    await client.login('senha', email: 'a@b.com');
    rede = false;
    await client.sair();
    expect(client.isAuthenticated, isFalse);
  });

  test('sair de todos os outros guarda os tokens novos', () async {
    final store = InMemoryTokenStore();
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: store,
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/v1/auth/sessions/revoke-others') {
          return http.Response(
              jsonEncode({'access_token': 'a2', 'refresh_token': 'r2'}), 200);
        }
        return http.Response(
            jsonEncode({'access_token': 'a1', 'refresh_token': 'r1'}), 200);
      }),
    );
    await client.login('senha', email: 'a@b.com');
    await client.endOtherSessions();
    expect(await store.load(), ('a2', 'r2'));
  });

  test('lista e encerra sessões', () async {
    final pedidos = <String>[];
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        pedidos.add('${req.method} ${req.url.path}');
        if (req.url.path == '/api/v1/auth/sessions') {
          return http.Response(
              jsonEncode([
                {
                  'id': 's1',
                  'aparelho': '',
                  'criada_em': '2026-10-01T10:00:00Z',
                  'ultimo_uso': '2026-10-19T10:00:00Z',
                  'atual': false,
                }
              ]),
              200);
        }
        if (req.method == 'DELETE') return http.Response('', 204);
        return http.Response(
            jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
      }),
    );
    await client.login('senha', email: 'a@b.com');
    final sessoes = await client.listSessions();
    expect(sessoes.single.id, 's1');
    await client.endSession('s1');
    expect(pedidos, contains('DELETE /api/v1/auth/sessions/s1'));
  });
}
