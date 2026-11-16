import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/services/retentativa.dart';

/// O orçamento de tentativas do vídeo direto.
///
/// Cada teste aqui corresponde a um jeito de a reconexão automática dar
/// errado — e os dois primeiros são os que não aparecem em teste manual: quem
/// testa com a rede boa nunca chega neles.
void main() {
  group('Retentativa', () {
    test('as esperas crescem, na ordem', () {
      // Crescente porque a causa passageira (trocou de torre, o Wi-Fi
      // oscilou) costuma passar em segundos; se não passou em três, esperar
      // oito custa pouco e acerta mais.
      final r = Retentativa();
      expect(r.proxima(), const Duration(seconds: 3));
      expect(r.proxima(), const Duration(seconds: 8));
      expect(r.proxima(), const Duration(seconds: 20));
    });

    test('acaba, e devolve null em vez de recomeçar', () {
      // O laço infinito. Sem este `null`, um computador que não tem caminho de
      // rede nenhum — o caso em que o ICE falha por falta de candidatos —
      // faria o celular tentar para sempre, gastando bateria e dados de quem
      // está na rua para uma conexão que não vai fechar.
      final r = Retentativa();
      r.proxima();
      r.proxima();
      r.proxima();

      expect(r.esgotou, isTrue);
      expect(r.proxima(), isNull);
      expect(r.proxima(), isNull, reason: 'não pode voltar a dar esperas');
    });

    test('consome ao devolver, e não depois', () {
      // O outro defeito silencioso: se `proxima()` só consultasse, o
      // incremento ficaria por conta de quem chama — e um caminho esquecido
      // devolveria a mesma espera para sempre, o que é o laço infinito com
      // outra cara.
      final r = Retentativa();
      expect(r.tentativa, 0);
      r.proxima();
      expect(r.tentativa, 1);
      r.proxima();
      expect(r.tentativa, 2);
    });

    test('o sucesso devolve o orçamento cheio', () {
      // Uma sessão de duas horas oscila mais de três vezes. Sem zerar ao
      // conectar, ela gastaria as três chances na primeira meia hora e
      // passaria o resto no modo antigo com a rede já boa.
      final r = Retentativa();
      r.proxima();
      r.proxima();
      r.proxima();
      expect(r.esgotou, isTrue);

      r.sucesso();

      expect(r.esgotou, isFalse);
      expect(r.tentativa, 0);
      expect(r.proxima(), const Duration(seconds: 3));
    });

    test('sabe dizer em que tentativa está, para a mensagem na tela', () {
      // "tentando de novo (2 de 3)" é o que separa um aviso que tranquiliza de
      // um que assusta.
      final r = Retentativa();
      expect(r.total, 3);
      r.proxima();
      expect(r.tentativa, 1);
      r.proxima();
      expect('${r.tentativa} de ${r.total}', '2 de 3');
    });

    test('aceita outro orçamento, para quem precisar de outro ritmo', () {
      final r = Retentativa(esperas: const [Duration(seconds: 1)]);
      expect(r.total, 1);
      expect(r.proxima(), const Duration(seconds: 1));
      expect(r.proxima(), isNull);
    });

    test('um orçamento vazio já nasce esgotado', () {
      // O caso degenerado: sem esperas, não há tentativa nenhuma — e o
      // `proxima()` não pode estourar índice ao ser chamado mesmo assim.
      final r = Retentativa(esperas: const []);
      expect(r.esgotou, isTrue);
      expect(r.proxima(), isNull);
    });
  });
}
