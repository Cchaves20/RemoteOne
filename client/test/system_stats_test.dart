import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/models/system_stats.dart';

/// As métricas do computador, do JSON até o texto da tela.
///
/// O que se protege aqui é a diferença entre **ausente** e **zero**. Um
/// computador de mesa não tem bateria e uma máquina virtual não tem GPU
/// dedicada: nesses casos o agente não manda o campo, e mostrar 0% seria uma
/// medida errada, não uma medida faltando.
void main() {
  /// O que um agente atualizado manda num notebook completo.
  Map<String, dynamic> completo() => {
        'cpu_percent': 37.4,
        'memory_used': 8000000000,
        'memory_total': 16000000000,
        'disk_used': 300000000000,
        'disk_total': 500000000000,
        'disk_name': 'C:',
        'uptime_seconds': 3600,
        'gpu_percent': 42.5,
        'gpu_name': 'NVIDIA GeForce RTX 3060',
        'temperature_celsius': 51.2,
        'network_rx_bps': 1500000,
        'network_tx_bps': 2048,
        'battery_percent': 87,
        'on_battery': true,
      };

  group('leitura do JSON', () {
    test('lê as medidas novas quando o computador as manda', () {
      final s = SystemStats.fromJson(completo());
      expect(s.gpuPercent, 42.5);
      expect(s.gpuName, 'NVIDIA GeForce RTX 3060');
      expect(s.temperatureCelsius, 51.2);
      expect(s.networkRxBps, 1500000);
      expect(s.networkTxBps, 2048);
      expect(s.batteryPercent, 87);
      expect(s.onBattery, true);
    });

    test('agente antigo continua funcionando', () {
      // O caso que acontece de verdade: o app se atualiza pela App Store e o
      // agente do computador não. Sem os campos novos, o painel tem que
      // continuar mostrando CPU, memória e disco em vez de falhar inteiro.
      final antigo = completo()
        ..remove('gpu_percent')
        ..remove('gpu_name')
        ..remove('temperature_celsius')
        ..remove('network_rx_bps')
        ..remove('network_tx_bps')
        ..remove('battery_percent')
        ..remove('on_battery');
      final s = SystemStats.fromJson(antigo);
      expect(s.cpuPercent, 37.4);
      expect(s.gpuPercent, isNull);
      expect(s.batteryPercent, isNull);
      // Rede é o único que vira zero em vez de nulo: toda máquina tem rede, e
      // "sem tráfego agora" é uma medida legítima de valor zero.
      expect(s.networkRxBps, 0);
      expect(s.networkTxBps, 0);
    });

    test('nulo explícito é ausência, não zero', () {
      // Desktop: o agente manda o campo como null em vez de omitir.
      final desktop = completo()
        ..['battery_percent'] = null
        ..['on_battery'] = null
        ..['gpu_percent'] = null;
      final s = SystemStats.fromJson(desktop);
      expect(s.batteryPercent, isNull);
      expect(s.onBattery, isNull);
      expect(s.gpuPercent, isNull);
    });

    test('inteiro onde se espera decimal não quebra', () {
      // O agente manda 42 e não 42.0 quando o uso é redondo; em JSON os dois
      // são o mesmo número, mas em Dart `int` não é `double`.
      final s = SystemStats.fromJson(completo()..['gpu_percent'] = 42);
      expect(s.gpuPercent, 42.0);
    });
  });

  group('taxa de rede', () {
    test('usa base 1000, não 1024', () {
      // Velocidade de rede se conta em potências de dez no mundo inteiro - é
      // assim que o provedor vende e que o Windows mostra. Capacidade de disco
      // e memória, não. Usar a mesma base para os dois deixaria um errado.
      expect(SystemStats.formatRate(1000), '1 KB/s');
      expect(SystemStats.formatRate(1500000), '1.5 MB/s');
    });

    test('abaixo de mil mostra bytes', () {
      expect(SystemStats.formatRate(0), '0 B/s');
      expect(SystemStats.formatRate(999), '999 B/s');
    });
  });

  group('o que já existia continua valendo', () {
    test('tamanhos usam base 1024', () {
      // Aqui é o contrário da rede: o "GB" que o Windows mostra é 1024³, e o
      // número tem que bater com o que a pessoa vê no próprio computador.
      expect(SystemStats.formatBytes(1024), '1 KB');
      expect(SystemStats.formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('fração não divide por zero', () {
      final s = SystemStats.fromJson(completo()
        ..['memory_total'] = 0
        ..['disk_total'] = 0);
      expect(s.memoryFraction, 0);
      expect(s.diskFraction, 0);
    });
  });
}
