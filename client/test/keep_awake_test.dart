import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remoteone_client/models/keep_awake.dart';
import 'package:remoteone_client/services/api_client.dart';
import 'package:remoteone_client/services/token_store.dart';

void main() {
  group('KeepAwakeState', () {
    test('lê os três campos separados', () {
      final estado = KeepAwakeState.fromJson({
        'enabled': true,
        'holding': false,
        'source': 'battery',
      });
      expect(estado.enabled, isTrue);
      expect(estado.holding, isFalse);
      expect(estado.source, PowerSource.battery);
    });

    test('ligado na bateria é "suspenso", não é ligado nem desligado', () {
      // É o estado que a tela precisa explicar: a chave está ligada e o
      // computador vai dormir do mesmo jeito.
      final estado = KeepAwakeState.fromJson(
          {'enabled': true, 'holding': false, 'source': 'battery'});
      expect(estado.suspended, isTrue);
    });

    test('ligado e segurando não é suspenso', () {
      final estado = KeepAwakeState.fromJson(
          {'enabled': true, 'holding': true, 'source': 'ac'});
      expect(estado.suspended, isFalse);
    });

    test('desligado não é suspenso', () {
      final estado = KeepAwakeState.fromJson(
          {'enabled': false, 'holding': false, 'source': 'ac'});
      expect(estado.suspended, isFalse);
    });

    test('fonte desconhecida não quebra a tela', () {
      // Um agente mais novo pode inventar uma fonte que este app não conhece.
      // Cair em `unknown` deixa a tela funcionando; lançar a deixaria em
      // branco por causa de uma palavra.
      expect(PowerSource.parse('solar'), PowerSource.unknown);
      expect(PowerSource.parse(null), PowerSource.unknown);
    });
  });

  group('ApiClient', () {
    test('consulta o estado do computador', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          expect(req.method, 'GET');
          expect(req.url.path, '/api/v1/devices/dev-1/keep-awake');
          return http.Response(
            jsonEncode({'enabled': true, 'holding': true, 'source': 'ac'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final estado = await client.keepAwake('dev-1');
      expect(estado.holding, isTrue);
      expect(estado.source, PowerSource.ac);
    });

    test('desligar manda o campo e aceita o 204', () async {
      Map<String, dynamic>? corpo;
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          corpo = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response('', 204);
        }),
      );
      await client.setKeepAwake('dev-1', false);
      expect(corpo, {'enabled': false});
    });

    test('computador offline vira exceção, e não sucesso silencioso', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({'detail': 'agente offline'}),
              503,
              headers: {'content-type': 'application/json'},
            )),
      );
      expect(
        () => client.setKeepAwake('dev-1', true),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
