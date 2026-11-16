import 'dart:convert';
import 'dart:typed_data';

/// Um aplicativo do computador, como retornado por GET /devices/{id}/apps.
///
/// `id` é o que identifica o app para agir sobre ele: o caminho do atalho
/// (área de trabalho) ou o PID (em execução). `iconBytes` é o ícone real do
/// programa, quando o agente conseguiu extrair.
class RemoteApp {
  const RemoteApp({required this.id, required this.name, this.iconBytes});

  final String id;
  final String name;
  final Uint8List? iconBytes;

  /// O nome pelo qual um atalho e um processo se reconhecem.
  ///
  /// Existe para uma pergunta só: **este atalho da área de trabalho está
  /// aberto agora?** O atalho chega como "Spotify.lnk" e o processo como
  /// "Spotify" — sem tirar a extensão e o caso, nenhum dos dois casa.
  ///
  /// A comparação depois disso é **exata**, e é uma decisão. Casar por prefixo
  /// pegaria "Google Chrome" com "chrome", mas também casaria "Word" com
  /// "WordPad": diria que um programa está aberto quando não está. Entre errar
  /// para menos e errar para mais, aqui se erra para menos — o anel não
  /// aparece, a dock segue funcionando, e ninguém é informado de algo falso.
  static String matchName(String nome) {
    final base = nome.split(RegExp(r'[\\/]')).last;
    final ponto = base.lastIndexOf('.');
    return (ponto > 0 ? base.substring(0, ponto) : base).toLowerCase();
  }

  factory RemoteApp.fromJson(Map<String, dynamic> json) {
    final icon = json['icon'] as String?;
    Uint8List? bytes;
    if (icon != null && icon.isNotEmpty) {
      try {
        bytes = base64Decode(icon);
      } catch (_) {
        // Ícone corrompido: segue sem ele (o app mostra a inicial do nome).
      }
    }
    return RemoteApp(
      id: json['id'] as String,
      name: json['name'] as String,
      iconBytes: bytes,
    );
  }
}


/// O que aconteceu com um programa no "abrir todos".
///
/// Existe porque a resposta **não** é um "deu certo": abrir quatro programas e
/// não dizer que um falhou é o mesmo que falhar em silêncio. Com o
/// identificador de volta, o app diz *qual* não abriu.
class LaunchResult {
  const LaunchResult({required this.id, required this.ok, this.error});

  final String id;
  final bool ok;
  final String? error;

  factory LaunchResult.fromJson(Map<String, dynamic> json) => LaunchResult(
        id: (json['id'] as String?) ?? '',
        ok: (json['ok'] as bool?) ?? false,
        error: json['error'] as String?,
      );
}
