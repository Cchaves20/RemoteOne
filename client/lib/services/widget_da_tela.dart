/// O widget da tela inicial, do lado do app.
///
/// ## iPhone
///
/// O widget do iPhone é Swift (`client/nativo/ios/DesksideWidget/`) e lê o
/// servidor sozinho. Daqui só sai o pedido de redesenho, para a escolha salva
/// na tela de widgets aparecer agora e não em até 15 minutos.
///
/// ## Android
///
/// O widget do Android só desenha: quem lê o servidor é o app, que grava o que
/// mostrar pelo `home_widget`. E os botões rodam **este** código em segundo
/// plano (`aoTocarNoWidget`), sem abrir o app — com o mesmo login, o mesmo
/// cliente da API e os mesmos textos.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../models/widget_config.dart';
import 'api_client.dart';

/// O `kind` do widget do iPhone. Precisa bater com `DesksideWidget.tipo`.
const nomeDoWidgetIos = 'DesksideWidget';

/// A classe do widget do Android (`DesksideWidgetProvider.kt`).
const nomeDoWidgetAndroid = 'DesksideWidgetProvider';

const _chaveNome = 'deskside_nome';
const _chaveOnline = 'deskside_online';
const _chaveComputador = 'deskside_computador';
const _chaveAviso = 'deskside_aviso';
String _chaveBotao(int i, String campo) => 'deskside_botao_${i}_$campo';

bool get _ehAndroid => defaultTargetPlatform == TargetPlatform.android;
bool get _ehIos => defaultTargetPlatform == TargetPlatform.iOS;

/// O símbolo de cada botão no widget do Android. Emoji porque o widget do
/// Android é desenhado por outro processo (`RemoteViews`), e um texto é o que
/// ele mostra sem pacote de ícones nenhum.
String simboloDoBotao(TipoDeBotao tipo) => switch (tipo) {
      TipoDeBotao.apresentacao => '🖥',
      TipoDeBotao.tocarPausar => '⏯',
      TipoDeBotao.automacao => '⚡',
      TipoDeBotao.suspender => '🌙',
      TipoDeBotao.volumeMais => '🔊',
      TipoDeBotao.volumeMenos => '🔉',
      TipoDeBotao.silenciar => '🔇',
    };

/// O texto de um botão: símbolo em cima, nome embaixo.
String textoDoBotao(Strings t, BotaoDoWidget b) {
  final nome = switch (b.tipo) {
    TipoDeBotao.apresentacao => t.presentationMode,
    TipoDeBotao.tocarPausar => t.botaoTocarPausar,
    TipoDeBotao.suspender => t.suspend,
    TipoDeBotao.volumeMais => t.botaoVolumeMais,
    TipoDeBotao.volumeMenos => t.botaoVolumeMenos,
    TipoDeBotao.silenciar => t.botaoSilenciar,
    TipoDeBotao.automacao => b.automacaoNome ?? '',
  };
  return '${simboloDoBotao(b.tipo)}\n$nome';
}

/// Grava o widget e pede o redesenho nos dois sistemas. Nunca lança: o widget
/// é conveniência, e falhar aqui não pode atrapalhar o app.
Future<void> publicarWidget(ConfigDoWidget? w, Strings t) async {
  try {
    if (_ehAndroid) {
      await _gravarAndroid(w, t);
      await HomeWidget.updateWidget(androidName: nomeDoWidgetAndroid);
    } else if (_ehIos) {
      await HomeWidget.updateWidget(iOSName: nomeDoWidgetIos);
    }
  } catch (_) {
    // Sem widget na tela, ou sistema sem suporte: nada a fazer.
  }
}

/// `w == null` é "fora da conta": tudo apagado, e o widget mostra o seu próprio
/// "abra o Deskside". Com conta mas sem computador, o aviso diz o que falta.
Future<void> _gravarAndroid(ConfigDoWidget? w, Strings t) async {
  await HomeWidget.saveWidgetData<String>(
    _chaveAviso,
    (w != null && w.deviceId == null) ? t.widgetsSemComputador : null,
  );
  await HomeWidget.saveWidgetData<String>(_chaveNome, w?.deviceName ?? w?.deviceId);
  await HomeWidget.saveWidgetData<bool>(_chaveOnline, w?.online ?? false);
  await HomeWidget.saveWidgetData<String>(_chaveComputador, w?.deviceId);
  final botoes = w?.botoes ?? const <BotaoDoWidget>[];
  for (var i = 0; i < 3; i++) {
    final b = i < botoes.length ? botoes[i] : null;
    await HomeWidget.saveWidgetData<String>(
        _chaveBotao(i, 'texto'), b == null ? null : textoDoBotao(t, b));
    await HomeWidget.saveWidgetData<String>(_chaveBotao(i, 'tipo'), b?.tipo.valor);
    await HomeWidget.saveWidgetData<String>(_chaveBotao(i, 'automacao'), b?.automacaoId);
  }
}

/// Liga os toques nos botões do widget do Android a [aoTocarNoWidget]. No
/// iPhone os botões são do próprio widget (App Intents), e isto não se aplica.
Future<void> registrarToquesDoWidget() async {
  if (!_ehAndroid) return;
  try {
    await HomeWidget.registerInteractivityCallback(aoTocarNoWidget);
  } catch (_) {}
}

/// Mantém o widget em dia com o app: publica quando a escolha do widget ou o
/// idioma mudam. O app notifica a toda hora, e reescrever o widget a cada
/// notificação seria desperdício — por isso a comparação.
class SincronizadorDoWidget {
  SincronizadorDoWidget([this._publicar = publicarWidget]);

  final Future<void> Function(ConfigDoWidget?, Strings) _publicar;
  (int, Object)? _publicado;

  /// Sem escolha carregada ([w] nulo), quase sempre é "ainda carregando" ou
  /// "sem rede", e o widget fica como está: apagá-lo mostraria "abra o app" a
  /// quem tem tudo configurado. Só apaga quando a sessão acabou ([conectado]
  /// falso) depois de algo ter sido publicado nesta execução — ou seja, saiu
  /// da conta.
  void sincronizar(ConfigDoWidget? w, bool conectado, Strings t, Object idioma) {
    if (w == null && (conectado || _publicado == null)) return;
    final assinatura = (identityHashCode(w), idioma);
    if (assinatura == _publicado) return;
    _publicado = assinatura;
    _publicar(w, t);
  }
}

/// Faz o que um botão do widget pede. Separado do toque para ser testável.
Future<void> executarBotao(
  ApiClient api,
  TipoDeBotao tipo,
  String computador,
  String? automacao,
) async {
  switch (tipo) {
    case TipoDeBotao.apresentacao:
      final atual = await api.presentation(computador);
      await api.setPresentation(computador, on: !atual.on);
    case TipoDeBotao.tocarPausar:
      await api.mediaKey(computador, 'play_pause');
    case TipoDeBotao.volumeMais:
      await api.mediaKey(computador, 'volume_up');
    case TipoDeBotao.volumeMenos:
      await api.mediaKey(computador, 'volume_down');
    case TipoDeBotao.silenciar:
      await api.mediaKey(computador, 'mute');
    case TipoDeBotao.suspender:
      await api.powerDevice(computador, 'suspend');
    case TipoDeBotao.automacao:
      if (automacao == null || automacao.isEmpty) return;
      await api.runAutomation(automacao, deviceId: computador);
  }
}

/// O idioma do app, lido fora do app (o toque roda num processo à parte).
/// A mesma regra do `AppState`: a escolha salva, ou o idioma do aparelho.
Strings _textos(SharedPreferences prefs) {
  final salvo = AppLanguage.values
      .where((l) => l.name == prefs.getString('language'))
      .firstOrNull;
  if (salvo != null && salvo != AppLanguage.system) return Strings(salvo);
  return Strings(switch (ui.PlatformDispatcher.instance.locale.languageCode) {
    'pt' => AppLanguage.ptBr,
    'zh' => AppLanguage.zh,
    'fr' => AppLanguage.fr,
    'es' => AppLanguage.es,
    _ => AppLanguage.en,
  });
}

/// Toque num botão do widget do Android: `deskside://widget/botao?i=0`.
///
/// Roda num processo de fundo, sem a tela do app. O login vem do mesmo lugar
/// que o app usa; sem login, não faz nada (o widget já diz "abra o app").
@pragma('vm:entry-point')
Future<void> aoTocarNoWidget(Uri? uri) async {
  final i = int.tryParse(uri?.queryParameters['i'] ?? '');
  if (uri?.host != 'widget' || i == null) return;
  final tipo = TipoDeBotao.doValor(
      await HomeWidget.getWidgetData<String>(_chaveBotao(i, 'tipo')));
  final computador = await HomeWidget.getWidgetData<String>(_chaveComputador);
  final automacao =
      await HomeWidget.getWidgetData<String>(_chaveBotao(i, 'automacao'));
  if (tipo == null || computador == null) return;

  final prefs = await SharedPreferences.getInstance();
  final api = ApiClient(baseUrl: prefs.getString('serverUrl') ?? backendPadrao);
  if (!await api.restore()) return;
  try {
    await executarBotao(api, tipo, computador, automacao);
  } catch (_) {
    // Computador desligado, plano sem o recurso: o widget não tem onde
    // mostrar o motivo, e o estado redesenhado abaixo já diz "offline".
  }
  try {
    final w = await api.widget();
    await _gravarAndroid(w, _textos(prefs));
    await HomeWidget.updateWidget(androidName: nomeDoWidgetAndroid);
  } catch (_) {}
}
