import 'dart:convert';

import 'package:deskside_client/models/remote_file.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Pastas grandes vêm em páginas: o que falta, e como a página seguinte entra.
void main() {
  Map<String, dynamic> pagina(int de, int quantos, {int? total}) => {
        'path': '/home/ana/Downloads',
        'parent': '/home/ana',
        'entries': [
          for (var i = de; i < de + quantos; i++)
            {
              'name': 'arq-$i',
              'path': '/home/ana/Downloads/arq-$i',
              'is_dir': false,
              'size': 1,
            }
        ],
        if (total != null) 'total': total,
        if (de > 0) 'offset': de,
      };

  test('a primeira página diz quanto falta', () {
    final l = RemoteListing.fromJson(pagina(0, 500, total: 1200));
    expect(l.restantes, 700);
  });

  test('juntar as páginas soma os itens e zera o que falta no fim', () {
    var l = RemoteListing.fromJson(pagina(0, 500, total: 1200));
    l = l.comMais(RemoteListing.fromJson(pagina(500, 500, total: 1200)));
    expect(l.entries, hasLength(1000));
    expect(l.restantes, 200);
    l = l.comMais(RemoteListing.fromJson(pagina(1000, 200, total: 1200)));
    expect(l.restantes, 0);
    expect(l.entries.last.name, 'arq-1199');
    expect(l.parent, '/home/ana', reason: 'a pasta continua a mesma');
  });

  test('agente antigo, sem total, é a pasta inteira', () {
    final l = RemoteListing.fromJson(pagina(0, 3));
    expect(l.total, isNull);
    expect(l.restantes, 0);
  });

  test('a página seguinte pede o offset, e a primeira não', () async {
    final pedidos = <Uri>[];
    final api = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        pedidos.add(req.url);
        return http.Response(jsonEncode(pagina(0, 1, total: 1)), 200);
      }),
    );
    await api.listFiles('pc', path: '/home/ana');
    await api.listFiles('pc', path: '/home/ana', offset: 500);
    expect(pedidos[0].queryParameters.containsKey('offset'), isFalse);
    expect(pedidos[1].queryParameters['offset'], '500');
    expect(pedidos[1].queryParameters['path'], '/home/ana');
  });
}
