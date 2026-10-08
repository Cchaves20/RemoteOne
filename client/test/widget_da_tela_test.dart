import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/models/widget_config.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:deskside_client/services/widget_da_tela.dart';

void main() {
  const t = Strings(AppLanguage.ptBr);

  group('textoDoBotao', () {
    test('símbolo em cima, nome embaixo', () {
      expect(
        textoDoBotao(t, const BotaoDoWidget(TipoDeBotao.tocarPausar)),
        '${simboloDoBotao(TipoDeBotao.tocarPausar)}\n${t.botaoTocarPausar}',
      );
    });

    test('automação leva o nome que o servidor mandou', () {
      const b = BotaoDoWidget(TipoDeBotao.automacao,
          automacaoId: 'a1', automacaoNome: 'Modo cinema');
      expect(textoDoBotao(t, b), endsWith('\nModo cinema'));
    });

    test('todo tipo tem símbolo', () {
      for (final tipo in TipoDeBotao.values) {
        expect(simboloDoBotao(tipo), isNotEmpty, reason: tipo.name);
      }
    });
  });

  group('executarBotao', () {
    late List<http.Request> pedidos;
    late ApiClient api;

    setUp(() {
      pedidos = [];
      api = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((req) async {
          pedidos.add(req);
          if (req.method == 'GET' && req.url.path.endsWith('/presentation')) {
            return http.Response(jsonEncode({'on': true, 'auto': false}), 200);
          }
          if (req.url.path.contains('/automations/')) {
            return http.Response(jsonEncode({'results': []}), 200);
          }
          return http.Response('', 204);
        }),
      );
    });

    Map<String, dynamic> corpo(http.Request r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    test('teclas de mídia vão com a ação que o servidor aceita', () async {
      final esperado = {
        TipoDeBotao.tocarPausar: 'play_pause',
        TipoDeBotao.volumeMais: 'volume_up',
        TipoDeBotao.volumeMenos: 'volume_down',
        TipoDeBotao.silenciar: 'mute',
      };
      for (final MapEntry(key: tipo, value: acao) in esperado.entries) {
        pedidos.clear();
        await executarBotao(api, tipo, 'pc-1', null);
        expect(pedidos.single.url.path, '/api/v1/devices/pc-1/media');
        expect(corpo(pedidos.single), {'action': acao});
      }
    });

    test('suspender', () async {
      await executarBotao(api, TipoDeBotao.suspender, 'pc-1', null);
      expect(pedidos.single.url.path, '/api/v1/devices/pc-1/power');
      expect(corpo(pedidos.single), {'action': 'suspend'});
    });

    test('apresentação inverte o estado atual', () async {
      await executarBotao(api, TipoDeBotao.apresentacao, 'pc-1', null);
      expect(pedidos.map((p) => p.method), ['GET', 'POST']);
      // Estava ligada (o servidor falso diz `on: true`): o toque desliga, e
      // manda só o `on` — nunca o `auto`.
      expect(corpo(pedidos.last), {'on': false});
    });

    test('automação roda no computador do widget', () async {
      await executarBotao(api, TipoDeBotao.automacao, 'pc-1', 'a1');
      expect(pedidos.single.url.path, '/api/v1/automations/a1/run');
      expect(pedidos.single.url.queryParameters['device_id'], 'pc-1');
    });

    test('automação sem id não chama o servidor', () async {
      await executarBotao(api, TipoDeBotao.automacao, 'pc-1', null);
      await executarBotao(api, TipoDeBotao.automacao, 'pc-1', '');
      expect(pedidos, isEmpty);
    });
  });

  group('SincronizadorDoWidget', () {
    late List<ConfigDoWidget?> publicados;
    late SincronizadorDoWidget s;

    setUp(() {
      publicados = [];
      s = SincronizadorDoWidget((w, _) async => publicados.add(w));
    });

    test('abrindo o app, sem escolha carregada, não apaga o widget', () {
      // Antes da sessão voltar, ou sem rede: nada a publicar.
      s.sincronizar(null, false, t, AppLanguage.system);
      s.sincronizar(null, true, t, AppLanguage.system);
      expect(publicados, isEmpty);
    });

    test('publica uma vez por escolha, não a cada notificação', () {
      const w = ConfigDoWidget(deviceId: 'pc-1');
      s.sincronizar(w, true, t, AppLanguage.system);
      s.sincronizar(w, true, t, AppLanguage.system);
      expect(publicados, [w]);
    });

    test('escolha nova ou idioma novo publicam de novo', () {
      const w1 = ConfigDoWidget(deviceId: 'pc-1');
      const w2 = ConfigDoWidget(deviceId: 'pc-2');
      s.sincronizar(w1, true, t, AppLanguage.system);
      s.sincronizar(w2, true, t, AppLanguage.system);
      s.sincronizar(w2, true, t, AppLanguage.en);
      expect(publicados, [w1, w2, w2]);
    });

    test('sem rede depois de carregar: mantém o que estava', () {
      const w = ConfigDoWidget(deviceId: 'pc-1');
      s.sincronizar(w, true, t, AppLanguage.system);
      s.sincronizar(null, true, t, AppLanguage.system);
      expect(publicados, [w]);
    });

    test('saiu da conta: apaga', () {
      const w = ConfigDoWidget(deviceId: 'pc-1');
      s.sincronizar(w, true, t, AppLanguage.system);
      s.sincronizar(null, false, t, AppLanguage.system);
      expect(publicados, [w, null]);
    });
  });
}
