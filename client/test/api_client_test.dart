import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remoteone_client/services/api_client.dart';
import 'package:remoteone_client/services/token_store.dart';

void main() {
  test('login guarda o token e envia Bearer nas chamadas seguintes', () async {
    String? seenAuth;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/v1/auth/login') {
          return http.Response(
            jsonEncode({'access_token': 'tok', 'refresh_token': 'r'}),
            200,
          );
        }
        if (req.url.path == '/api/v1/devices') {
          seenAuth = req.headers['Authorization'];
          return http.Response(jsonEncode([]), 200);
        }
        return http.Response('{}', 404);
      }),
    );

    expect(client.isAuthenticated, isFalse);
    await client.login('a@b.com', 'senhaSegura123');
    expect(client.isAuthenticated, isTrue);

    await client.listDevices();
    expect(seenAuth, 'Bearer tok');
  });

  test('sendInput usa o device_id na URL e aceita 204', () async {
    Uri? seenUrl;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seenUrl = req.url;
        return http.Response('', 204);
      }),
    );
    await client.sendInput('dev-9', {'kind': 'mouse_click', 'button': 'left'});
    expect(seenUrl?.path, '/api/v1/devices/dev-9/input');
  });

  test('fetchFrame devolve os bytes em 200 e null em 503', () async {
    var call = 0;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        call++;
        if (call == 1) {
          return http.Response.bytes([0xFF, 0xD8, 0xFF, 0x01], 200);
        }
        return http.Response('', 503);
      }),
    );
    final frame = await client.fetchFrame('dev-1');
    expect(frame, isNotNull);
    expect(frame!.first, 0xFF);
    expect(await client.fetchFrame('dev-1'), isNull);
  });

  test('startScreen aceita 204', () async {
    Uri? seen;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seen = req.url;
        return http.Response('', 204);
      }),
    );
    await client.startScreen('dev-7');
    expect(seen?.path, '/api/v1/devices/dev-7/screen/start');
  });

  test('erro HTTP vira ApiException com a mensagem detail', () async {
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        return http.Response(jsonEncode({'detail': 'agente offline'}), 503);
      }),
    );
    expect(
      () => client.sendInput('d', {'kind': 'mouse_scroll', 'dy': 1}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 503)
          .having((e) => e.message, 'message', 'agente offline')),
    );
  });
}
