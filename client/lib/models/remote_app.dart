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
