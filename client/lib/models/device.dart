/// Um computador pareado, como retornado por GET /api/v1/devices.
class Device {
  const Device({
    required this.deviceId,
    required this.name,
    required this.os,
    required this.hostname,
    this.online = false,
    this.testeEncerrado = false,
  });

  final String deviceId;
  final String name;
  final String os;
  final String hostname;

  /// Se o agente está conectado ao backend agora (presença ao vivo).
  final bool online;

  /// Só na resposta do pareamento: o teste de 30 dias desta conta **acabou
  /// agora**, porque este computador já serviu a testes de outras contas.
  ///
  /// O plano mudou debaixo da pessoa. Sem este aviso ela veria os recursos
  /// pagos sumirem logo depois de parear, e concluiria que parear quebrou
  /// alguma coisa.
  final bool testeEncerrado;

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      deviceId: json['device_id'] as String,
      name: json['name'] as String,
      os: json['os'] as String,
      hostname: json['hostname'] as String,
      online: json['online'] as bool? ?? false,
      // Ausente num servidor antigo: `false`, que só deixa de mostrar um aviso.
      testeEncerrado: json['teste_encerrado'] as bool? ?? false,
    );
  }
}
