import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deskside_client/models/system_stats.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/token_store.dart';

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
    await client.login('senhaSegura123!', email: 'a@b.com');
    expect(client.isAuthenticated, isTrue);

    await client.listDevices();
    expect(seenAuth, 'Bearer tok');
  });

  test('setPresentation manda só o campo que mudou', () async {
    // A armadilha deste recurso: o botão da barra de perfis mexe em `on` e a
    // área de perfis mexe em `auto`. Se cada um mandasse os dois, mandaria
    // junto um valor lido há dez minutos — e desfaria, sem querer, a escolha
    // que o outro acabou de fazer.
    final corpos = <Map<String, dynamic>>[];
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        corpos.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }),
    );

    await client.setPresentation('dev-1', on: true);
    await client.setPresentation('dev-1', auto: false);

    expect(corpos[0], {'on': true});
    expect(corpos[1], {'auto': false});
  });

  test('presentation lê o que o computador respondeu', () async {
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async => http.Response(
            jsonEncode({
              'on': true,
              'auto': true,
              'detected': 'Slides',
              'supported': false,
            }),
            200,
          )),
    );

    final estado = await client.presentation('dev-1');
    expect(estado.on, isTrue);
    // `detected` é o que explica um modo que ligou sozinho, e `supported` é o
    // que impede o app de prometer um silêncio que aquele Windows não faz.
    expect(estado.detected, 'Slides');
    expect(estado.supported, isFalse);
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
    await client.login('senhaSegura123!', email: 'a@b.com', totpCode: '123456');
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
    await client.login('senhaSegura123!', email: 'a@b.com');
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

  test('systemStats decodifica as métricas do computador', () async {
    Uri? seenUrl;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seenUrl = req.url;
        return http.Response(
          jsonEncode({
            'cpu_percent': 37.4,
            'memory_used': 8000000000,
            'memory_total': 16000000000,
            'disk_used': 300000000000,
            'disk_total': 500000000000,
            'disk_name': 'C:',
            'uptime_seconds': 3600,
          }),
          200,
        );
      }),
    );

    final stats = await client.systemStats('dev-1');
    expect(seenUrl?.path, '/api/v1/devices/dev-1/system');
    expect(stats.cpuPercent, 37.4);
    expect(stats.diskName, 'C:');
    expect(stats.memoryFraction, closeTo(0.5, 0.001));
  });

  test('mediaKey manda a ação no corpo e aceita 204', () async {
    Map<String, dynamic>? seenBody;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }),
    );

    await client.mediaKey('dev-1', 'play_pause');
    expect(seenBody, {'action': 'play_pause'});
  });

  test('trocar o contato só vale depois do código', () async {
    // O `start` **não** troca nada: ele manda o código. Um app que tratasse a
    // resposta do start como "pronto" mostraria o contato novo na tela sem que
    // ele existisse na conta — e a pessoa descobriria isso no próximo login.
    final chamadas = <String>[];
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        chamadas.add(req.url.path);
        if (req.url.path == '/api/v1/auth/me/contact/start') {
          return http.Response(
            jsonEncode({
              'destination': 'novo@example.com',
              'channel': 'email',
              'resend_in_seconds': 60,
              'delivered': true,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 1,
            'email': 'novo@example.com',
            'phone': null,
            'two_factor_enabled': false,
          }),
          200,
        );
      }),
    );

    final pendente = await client.contactChangeStart(
      currentPassword: 'senhaSegura123!',
      email: 'novo@example.com',
    );
    expect(pendente.destination, 'novo@example.com');
    expect(pendente.porEmail, isTrue);

    final conta = await client.contactChangeVerify('123456');
    expect(conta.email, 'novo@example.com');
    expect(chamadas, [
      '/api/v1/auth/me/contact/start',
      '/api/v1/auth/me/contact/verify',
    ]);
  });

  test('trocar a senha adota os tokens novos da resposta', () async {
    // O servidor cancela **todos** os tokens da conta ao trocar a senha, para
    // derrubar sessões em outros aparelhos — inclusive o token deste aqui. Se o
    // app ficasse com o antigo, a chamada seguinte daria 401 e a pessoa cairia
    // na tela de login logo depois de trocar a senha com sucesso.
    String? seenAuth;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/v1/auth/login') {
          return http.Response(
            jsonEncode({'access_token': 'velho', 'refresh_token': 'r-velho'}),
            200,
          );
        }
        if (req.url.path == '/api/v1/auth/me/password') {
          return http.Response(
            jsonEncode({'access_token': 'novo', 'refresh_token': 'r-novo'}),
            200,
          );
        }
        seenAuth = req.headers['Authorization'];
        return http.Response(jsonEncode([]), 200);
      }),
    );

    await client.login('senhaSegura123!', email: 'a@b.com');
    await client.updatePassword('senhaSegura123!', 'outraSenha456!');

    await client.listDevices();
    expect(seenAuth, 'Bearer novo');
  });

  group('401: vencido é uma coisa, sessão encerrada é outra', () {
    // O cabeçalho vai em minúsculas de propósito: é como um servidor HTTP de
    // verdade entrega, e o `MockClient` repassa o mapa como foi escrito.
    const cabecalhoDeToken = {'www-authenticate': 'Bearer'};

    test('token vencido é renovado e a requisição refeita, sem deslogar',
        () async {
      // O defeito que isto fecha: o access token dura 15 minutos e nada o
      // renovava durante o uso. Depois de um quarto de hora, toda ação
      // respondia "credenciais inválidas" ate o app ser reaberto.
      var tentativas = 0;
      final tokensVistos = <String?>[];
      var encerrou = false;
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/auth/login') {
            return http.Response(
              jsonEncode({'access_token': 'velho', 'refresh_token': 'r'}),
              200,
            );
          }
          if (req.url.path == '/api/v1/auth/refresh') {
            return http.Response(jsonEncode({'access_token': 'novo'}), 200);
          }
          tentativas++;
          tokensVistos.add(req.headers['Authorization']);
          // Só a primeira vez recusa: é o token vencido.
          if (tentativas == 1) {
            return http.Response('{"detail":"credenciais inválidas"}', 401,
                headers: cabecalhoDeToken);
          }
          return http.Response(jsonEncode([]), 200);
        }),
      );
      client.aoEncerrarSessao = () => encerrou = true;

      await client.login('senhaSegura123!', email: 'a@b.com');
      final devices = await client.listDevices();

      expect(devices, isEmpty, reason: 'a requisição precisa ter sido refeita');
      expect(tentativas, 2);
      expect(tokensVistos, ['Bearer velho', 'Bearer novo']);
      expect(encerrou, isFalse, reason: 'vencer não é a sessão acabar');
      expect(client.isAuthenticated, isTrue);
    });

    test('refresh recusado encerra a sessão', () async {
      // O outro lado: alguém trocou a senha noutro aparelho, e este aqui
      // precisa cair na tela de login em vez de ficar dando erro em cada toque.
      var encerrou = false;
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/auth/login') {
            return http.Response(
              jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
              200,
            );
          }
          if (req.url.path == '/api/v1/auth/refresh') {
            return http.Response('{"detail":"refresh token inválido"}', 401);
          }
          return http.Response('{"detail":"credenciais inválidas"}', 401,
              headers: cabecalhoDeToken);
        }),
      );
      client.aoEncerrarSessao = () => encerrou = true;

      await client.login('senhaSegura123!', email: 'a@b.com');
      await expectLater(client.listDevices(), throwsA(isA<ApiException>()));

      expect(encerrou, isTrue);
      expect(client.isAuthenticated, isFalse);
    });

    test('401 sem o cabeçalho não mexe na sessão', () async {
      // Senha atual errada e código de verificação errado também respondem 401,
      // e deslogar neles expulsaria quem só errou a digitação. O servidor manda
      // o `WWW-Authenticate` só quando o problema é o token; há teste do outro
      // lado, em backend/tests/test_sessoes.py.
      var encerrou = false;
      var refreshes = 0;
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/auth/login') {
            return http.Response(
              jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
              200,
            );
          }
          if (req.url.path == '/api/v1/auth/refresh') {
            refreshes++;
            return http.Response(jsonEncode({'access_token': 'b'}), 200);
          }
          return http.Response('{"detail":"senha atual incorreta"}', 401);
        }),
      );
      client.aoEncerrarSessao = () => encerrou = true;

      await client.login('senhaSegura123!', email: 'a@b.com');
      await expectLater(
        client.updatePassword('errada', 'outraSenha456!'),
        throwsA(isA<ApiException>()),
      );

      expect(encerrou, isFalse);
      expect(refreshes, 0, reason: 'nem deveria tentar renovar');
      expect(client.isAuthenticated, isTrue);
    });
  });

  group('formatação das métricas', () {
    test('bytes viram GB/MB em base 1024, como o Windows mostra', () {
      expect(SystemStats.formatBytes(16 * 1024 * 1024 * 1024), '16.0 GB');
      expect(SystemStats.formatBytes(512 * 1024 * 1024), '512 MB');
      expect(SystemStats.formatBytes(2048), '2 KB');
      expect(SystemStats.formatBytes(7), '7 B');
    });

    test('total zero não vira divisão por zero na barra', () {
      const vazio = SystemStats(
        cpuPercent: 0,
        memoryUsed: 0,
        memoryTotal: 0,
        diskUsed: 0,
        diskTotal: 0,
        diskName: '',
        uptimeSeconds: 0,
      );
      expect(vazio.memoryFraction, 0);
      expect(vazio.diskFraction, 0);
    });

    test('tempo ligado cresce de minutos para dias', () {
      SystemStats comUptime(int segundos) => SystemStats(
            cpuPercent: 0,
            memoryUsed: 0,
            memoryTotal: 1,
            diskUsed: 0,
            diskTotal: 1,
            diskName: 'C:',
            uptimeSeconds: segundos,
          );
      String rotulo(int segundos) => comUptime(segundos)
          .uptimeLabel(days: 'd', hours: 'h', minutes: 'min');
      expect(rotulo(90), '1min');
      expect(rotulo(3 * 3600 + 25 * 60), '3h 25min');
      expect(rotulo(2 * 86400 + 4 * 3600), '2d 4h');
    });
  });
}
