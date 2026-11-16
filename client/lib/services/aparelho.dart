import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

/// Como este aparelho aparece na lista de "Aparelhos conectados".
///
/// Sai do próprio sistema, sem biblioteca: uma daria o modelo exato ("Galaxy
/// S23"), mas plugin nativo no Android já custou builds quebrados a este
/// projeto (ver `pubspec.yaml`). O preço é o Android sem versão — o Dart só
/// expõe a do kernel, que não diz nada a quem lê a lista.
String nomeDoAparelho() {
  final tela = PlatformDispatcher.instance.views.firstOrNull;
  // Tablet pelo lado menor da tela em pixels lógicos, o mesmo corte de 600 que
  // o Material usa. É o que separa iPhone de iPad: os dois são "ios".
  final tablet = tela != null &&
      tela.physicalSize.shortestSide / tela.devicePixelRatio >= 600;
  return descreverAparelho(
    sistema: Platform.operatingSystem,
    versao: Platform.operatingSystemVersion,
    tablet: tablet,
  );
}

/// A parte testável de [nomeDoAparelho].
///
/// [versao] é o `Platform.operatingSystemVersion`, que no iPhone e no Mac vem
/// como "Version 18.1 (Build 22B83)".
String descreverAparelho({
  required String sistema,
  required String versao,
  required bool tablet,
}) {
  final numero = RegExp(r'Version ([\d.]+)').firstMatch(versao)?.group(1);
  String com(String nome, String so) =>
      numero == null ? nome : '$nome · $so $numero';
  return switch (sistema) {
    'ios' => tablet ? com('iPad', 'iPadOS') : com('iPhone', 'iOS'),
    'android' => tablet ? 'Tablet Android' : 'Celular Android',
    'macos' => com('Mac', 'macOS'),
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => sistema,
  };
}
