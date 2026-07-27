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
