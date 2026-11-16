import 'package:deskside_client/models/automation.dart';
import 'package:deskside_client/models/widget_config.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lê o widget como o servidor manda', () {
    final w = ConfigDoWidget.fromJson({
      'device_id': 'pc-1',
      'device_name': 'PC da sala',
      'online': true,
      'botoes': [
        {'tipo': 'apresentacao'},
        {'tipo': 'automacao', 'automacao_id': 'a1', 'automacao_nome': 'Cinema'},
        // Um tipo de uma versão mais nova do servidor: some, não quebra.
        {'tipo': 'teletransporte'},
      ],
      'atalhos': ['a1'],
    });
    expect(w.deviceName, 'PC da sala');
    expect(w.botoes.map((b) => b.tipo),
        [TipoDeBotao.apresentacao, TipoDeBotao.automacao]);
    expect(w.botoes[1].automacaoNome, 'Cinema');
    expect(w.atalhos, ['a1']);
  });

  test('o que vai ao servidor é só a escolha', () {
    final json = const ConfigDoWidget(
      deviceId: 'pc-1',
      deviceName: 'ignorado',
      online: true,
      botoes: [
        BotaoDoWidget(TipoDeBotao.tocarPausar),
        BotaoDoWidget(TipoDeBotao.automacao, automacaoId: 'a1'),
      ],
    ).toJson();
    expect(json, {
      'device_id': 'pc-1',
      'botoes': [
        {'tipo': 'tocar_pausar'},
        {'tipo': 'automacao', 'automacao_id': 'a1'},
      ],
      'atalhos': <String>[],
    });
  });

  test('a chave do menu vai e volta', () {
    for (final b in const [
      BotaoDoWidget(TipoDeBotao.silenciar),
      BotaoDoWidget(TipoDeBotao.automacao, automacaoId: 'x'),
    ]) {
      final volta = BotaoDoWidget.daChave(b.chave)!;
      expect(volta.tipo, b.tipo);
      expect(volta.automacaoId, b.automacaoId);
    }
    // Automação sem qual, ou tipo desconhecido: não vira botão.
    expect(BotaoDoWidget.daChave('automacao:'), isNull);
    expect(BotaoDoWidget.daChave('automacao'), isNull);
    expect(BotaoDoWidget.daChave('nada'), isNull);
  });

  test('os atalhos do ícone seguem a escolha, ou as primeiras automações', () {
    final state = AppState(
      ApiClient(baseUrl: 'http://test', tokenStore: InMemoryTokenStore()),
    );
    state.automations = const [
      Automation(id: 'a1', name: 'Um'),
      Automation(id: 'a2', name: 'Dois'),
      Automation(id: 'a3', name: 'Três'),
    ];
    expect(state.automacoesDoIcone.map((a) => a.id), ['a1', 'a2', 'a3']);

    // Na ordem escolhida; uma que sumiu da conta fica de fora.
    state.widget = const ConfigDoWidget(atalhos: ['a3', 'apagada', 'a1']);
    expect(state.automacoesDoIcone.map((a) => a.id), ['a3', 'a1']);
    state.dispose();
  });
}
