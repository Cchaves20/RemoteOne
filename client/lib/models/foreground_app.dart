import 'dart:convert';
import 'dart:typed_data';

/// O programa em primeiro plano no computador, de GET
/// /devices/{id}/foreground.
///
/// `exe` é a chave de comparação com os perfis ("powerpnt.exe"): o nome
/// legível muda com o idioma do Windows, o executável não.
class ForegroundApp {
  const ForegroundApp({required this.exe, this.name = '', this.iconBytes});

  final String exe;
  final String name;
  final Uint8List? iconBytes;

  /// `null` quando não há janela em foco — resposta legítima do computador, e
  /// o sinal para o app voltar aos ícones genéricos.
  static ForegroundApp? fromJson(Map<String, dynamic> json) {
    final app = json['app'];
    if (app is! Map<String, dynamic>) return null;
    final exe = (app['exe'] as String?)?.toLowerCase() ?? '';
    if (exe.isEmpty) return null;
    final icon = app['icon'] as String?;
    Uint8List? bytes;
    if (icon != null && icon.isNotEmpty) {
      try {
        bytes = base64Decode(icon);
      } catch (_) {
        // Ícone corrompido: segue sem ele (fica o ícone genérico do perfil).
      }
    }
    return ForegroundApp(
      exe: exe,
      name: (app['name'] as String?) ?? '',
      iconBytes: bytes,
    );
  }
}
