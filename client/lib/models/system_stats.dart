/// Métricas do computador, como retornadas por GET /devices/{id}/system.
///
/// O agente manda bytes crus e porcentagem; a formatação em "7,8 GB" fica aqui,
/// no lado que sabe o idioma do usuário.
class SystemStats {
  const SystemStats({
    required this.cpuPercent,
    required this.memoryUsed,
    required this.memoryTotal,
    required this.diskUsed,
    required this.diskTotal,
    required this.diskName,
    required this.uptimeSeconds,
  });

  final double cpuPercent;
  final int memoryUsed;
  final int memoryTotal;
  final int diskUsed;
  final int diskTotal;
  final String diskName;
  final int uptimeSeconds;

  factory SystemStats.fromJson(Map<String, dynamic> json) {
    return SystemStats(
      cpuPercent: (json['cpu_percent'] as num).toDouble(),
      memoryUsed: (json['memory_used'] as num).toInt(),
      memoryTotal: (json['memory_total'] as num).toInt(),
      diskUsed: (json['disk_used'] as num).toInt(),
      diskTotal: (json['disk_total'] as num).toInt(),
      diskName: (json['disk_name'] as String?) ?? '',
      uptimeSeconds: (json['uptime_seconds'] as num).toInt(),
    );
  }

  /// Fração usada (0–1) para a barra de progresso, ou 0 se o total é
  /// desconhecido — dividir por zero pintaria a barra de NaN.
  double get memoryFraction => memoryTotal == 0 ? 0 : memoryUsed / memoryTotal;
  double get diskFraction => diskTotal == 0 ? 0 : diskUsed / diskTotal;

  /// Bytes em unidade legível: GB acima de 1 GB, MB abaixo.
  ///
  /// Base 1024 (o "GB" que o Windows mostra), para o número bater com o que o
  /// usuário vê no próprio computador em vez de ser 7% maior.
  static String formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    if (bytes >= tb) return '${(bytes / tb).toStringAsFixed(1)} TB';
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// Tempo ligado em texto curto: `3d 4h`, `4h 12min` ou `12min`.
  ///
  /// Recebe os rótulos como parâmetro porque a unidade é traduzida — o modelo
  /// não conhece o idioma da tela.
  String uptimeLabel({
    required String days,
    required String hours,
    required String minutes,
  }) {
    final d = uptimeSeconds ~/ 86400;
    final h = (uptimeSeconds % 86400) ~/ 3600;
    final m = (uptimeSeconds % 3600) ~/ 60;
    if (d > 0) return '$d$days $h$hours';
    if (h > 0) return '$h$hours $m$minutes';
    return '$m$minutes';
  }
}
