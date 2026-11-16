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
    this.gpuPercent,
    this.gpuName,
    this.temperatureCelsius,
    this.networkRxBps = 0,
    this.networkTxBps = 0,
    this.batteryPercent,
    this.onBattery,
  });

  final double cpuPercent;
  final int memoryUsed;
  final int memoryTotal;
  final int diskUsed;
  final int diskTotal;
  final String diskName;
  final int uptimeSeconds;

  // As quatro medidas que fecham o painel. Todas podem faltar, e `null` aqui
  // não é falha: é uma máquina que não tem aquilo. Computador de mesa não tem
  // bateria, máquina virtual não tem GPU dedicada, e temperatura no Windows
  // costuma depender de driver do fabricante. Quem lê **esconde** a medida
  // ausente — mostrar 0 se leria como "GPU parada" ou "bateria acabando".
  final double? gpuPercent;
  final String? gpuName;
  final double? temperatureCelsius;

  /// Bytes por segundo entrando e saindo, somando todas as interfaces.
  final int networkRxBps;
  final int networkTxBps;

  final int? batteryPercent;
  final bool? onBattery;

  factory SystemStats.fromJson(Map<String, dynamic> json) {
    // `as num?` em tudo que é novo: um agente que ainda não foi atualizado
    // simplesmente não manda estes campos, e o painel tem que continuar
    // mostrando CPU, memória e disco em vez de falhar inteiro.
    return SystemStats(
      cpuPercent: (json['cpu_percent'] as num).toDouble(),
      memoryUsed: (json['memory_used'] as num).toInt(),
      memoryTotal: (json['memory_total'] as num).toInt(),
      diskUsed: (json['disk_used'] as num).toInt(),
      diskTotal: (json['disk_total'] as num).toInt(),
      diskName: (json['disk_name'] as String?) ?? '',
      uptimeSeconds: (json['uptime_seconds'] as num).toInt(),
      gpuPercent: (json['gpu_percent'] as num?)?.toDouble(),
      gpuName: json['gpu_name'] as String?,
      temperatureCelsius: (json['temperature_celsius'] as num?)?.toDouble(),
      networkRxBps: (json['network_rx_bps'] as num?)?.toInt() ?? 0,
      networkTxBps: (json['network_tx_bps'] as num?)?.toInt() ?? 0,
      batteryPercent: (json['battery_percent'] as num?)?.toInt(),
      onBattery: json['on_battery'] as bool?,
    );
  }

  /// Taxa de rede em texto curto: `1,2 MB/s`.
  ///
  /// Base 1000 aqui, e não 1024 como nos tamanhos: velocidade de rede se conta
  /// em potências de dez no mundo inteiro (é assim que o provedor vende e que o
  /// Windows mostra), enquanto capacidade de disco e memória se conta em 1024.
  /// Usar a mesma base para os dois deixaria um dos números errado.
  static String formatRate(int bytesPerSecond) {
    if (bytesPerSecond >= 1000000) {
      return '${(bytesPerSecond / 1000000).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1000) {
      return '${(bytesPerSecond / 1000).toStringAsFixed(0)} KB/s';
    }
    return '$bytesPerSecond B/s';
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
