/// Um aplicativo do computador, como retornado por GET /devices/{id}/apps.
///
/// `id` é o que identifica o app para agir sobre ele: o caminho do atalho
/// (instalados) ou o PID (em execução).
class RemoteApp {
  const RemoteApp({required this.id, required this.name});

  final String id;
  final String name;

  factory RemoteApp.fromJson(Map<String, dynamic> json) {
    return RemoteApp(
      id: json['id'] as String,
      name: json['name'] as String,
    );
  }
}
