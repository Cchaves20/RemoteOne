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

  test('renameDevice envia PATCH e devolve o Device atualizado', () async {
    Uri? seenUrl;
    String? seenMethod;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seenUrl = req.url;
        seenMethod = req.method;
        return http.Response(
          jsonEncode({
            'device_id': 'dev-1',
            'name': 'Novo nome',
            'os': 'windows',
            'hostname': 'pc',
            'online': true,
          }),
          200,
        );
      }),
    );
    final device = await client.renameDevice('dev-1', 'Novo nome');
    expect(seenMethod, 'PATCH');
    expect(seenUrl?.path, '/api/v1/devices/dev-1');
    expect(device.name, 'Novo nome');
    expect(device.online, isTrue);
  });

  test('powerDevice envia a ação e aceita 204', () async {
    Map<String, dynamic>? body;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }),
    );
    await client.powerDevice('dev-1', 'restart');
    expect(body?['action'], 'restart');
  });

  test('login envia totp_code quando informado', () async {
    Map<String, dynamic>? body;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
          200,
        );
      }),
    );
    await client.login('a@b.com', 'senhaSegura123', totpCode: '123456');
    expect(body?['totp_code'], '123456');
  });

  test('setupTwoFactor retorna secret e uri', () async {
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        return http.Response(
          jsonEncode({'secret': 'ABC123', 'otpauth_uri': 'otpauth://totp/x'}),
          200,
        );
      }),
    );
    final data = await client.setupTwoFactor();
    expect(data['secret'], 'ABC123');
    expect(data['otpauth_uri'], 'otpauth://totp/x');
  });

  test('enableTwoFactor envia o código e aceita 204', () async {
    Map<String, dynamic>? body;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }),
    );
    await client.enableTwoFactor('654321');
    expect(body?['code'], '654321');
  });

  test('listApps pede o kind certo e devolve os aplicativos', () async {
    Uri? seen;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seen = req.url;
        return http.Response(
          jsonEncode([
            // PNG 1x1 válido em base64, para exercitar a decodificação.
            {
              'id': r'C:\Spotify.lnk',
              'name': 'Spotify',
              'icon':
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            },
            {'id': r'C:\Chrome.lnk', 'name': 'Chrome'},
          ]),
          200,
        );
      }),
    );
    final apps = await client.listApps('dev-1', kind: 'running');
    expect(seen?.path, '/api/v1/devices/dev-1/apps');
    expect(seen?.query, 'kind=running');
    expect(apps.length, 2);
    expect(apps.first.name, 'Spotify');
    // O ícone vem em base64 e é decodificado para bytes.
    expect(apps.first.iconBytes, isNotNull);
    // Sem campo `icon`, fica sem ícone (o app mostra a inicial).
    expect(apps[1].iconBytes, isNull);
  });

  test('launchApp e closeApp enviam o id e aceitam 204', () async {
    final paths = <String>[];
    final bodies = <Map<String, dynamic>>[];
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        paths.add(req.url.path);
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }),
    );
    await client.launchApp('dev-1', r'C:\Spotify.lnk');
    await client.closeApp('dev-1', '4321');
    expect(paths, [
      '/api/v1/devices/dev-1/apps/launch',
      '/api/v1/devices/dev-1/apps/close',
    ]);
    expect(bodies[0]['id'], r'C:\Spotify.lnk');
    expect(bodies[1]['id'], '4321');
  });

  test('wakeDevice chama o endpoint /wake e aceita 204', () async {
    Uri? seen;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seen = req.url;
        return http.Response('', 204);
      }),
    );
    await client.wakeDevice('dev-9');
    expect(seen?.path, '/api/v1/devices/dev-9/wake');
  });

  test('wakeDevice sem peer vira ApiException 409', () async {
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        return http.Response(jsonEncode({'detail': 'nenhum peer'}), 409);
      }),
    );
    expect(
      () => client.wakeDevice('d'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'code', 409)),
    );
  });

  test('deleteAccount envia a senha e limpa a sessão', () async {
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
        return http.Response('', 204);
      }),
    );
    await client.login('a@b.com', 'senhaSegura123');
    expect(client.isAuthenticated, isTrue);
    await client.deleteAccount('senhaSegura123');
    expect(client.isAuthenticated, isFalse);
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
