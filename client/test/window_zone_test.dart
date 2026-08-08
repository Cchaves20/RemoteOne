import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/models/window_zone.dart';

/// Onde cada janela fica quando o perfil abre todos os programas.
///
/// O catálogo de layouts vive no app porque é ele que desenha o seletor; o
/// agente só recebe a célula escolhida e faz a conta em pixels. O que se
/// protege aqui é o que atravessa a rede e o que o editor deduz do que está
/// guardado.
void main() {
  group('catálogo de layouts', () {
    test('toda zona de todo layout cabe na própria grade', () {
      // Uma zona inválida no catálogo seria recusada pelo servidor no momento
      // de salvar o perfil - longe daqui, e sem dizer que a culpa é da tabela.
      for (final l in WindowLayout.all) {
        expect(l.zones, isNotEmpty, reason: l.id);
        for (final z in l.zones) {
          expect(z.isValid, isTrue, reason: '${l.id}: $z');
          expect(z.cols, l.cols, reason: '${l.id}: grade divergente');
          expect(z.rows, l.rows, reason: '${l.id}: grade divergente');
        }
      }
    });

    test('as zonas de um layout cobrem a tela sem sobrepor', () {
      // Conta por célula: a soma das células ocupadas tem que ser exatamente o
      // total da grade, e nenhuma célula pode ser reivindicada duas vezes.
      for (final l in WindowLayout.all) {
        final ocupadas = <String>{};
        for (final z in l.zones) {
          for (var c = z.col; c < z.col + z.colspan; c++) {
            for (var r = z.row; r < z.row + z.rowspan; r++) {
              expect(ocupadas.add('$c,$r'), isTrue,
                  reason: '${l.id}: célula $c,$r em duas zonas');
            }
          }
        }
        expect(ocupadas.length, l.cols * l.rows, reason: '${l.id}: sobrou buraco');
      }
    });

    test('cada layout tem id único', () {
      final ids = WindowLayout.all.map((l) => l.id).toSet();
      expect(ids.length, WindowLayout.all.length);
    });

    test('os cinco desenhos do Windows estão lá', () {
      final ids = WindowLayout.all.map((l) => l.id).toList();
      expect(ids, contains('metades'));
      expect(ids, contains('dois-tercos'));
      expect(ids, contains('tres-colunas'));
      expect(ids, contains('quadrantes'));
      expect(ids, contains('principal-e-duas'));
    });
  });

  group('deduzir o layout do que está guardado', () {
    test('acha o layout a que uma zona pertence', () {
      final metades = WindowLayout.all.firstWhere((l) => l.id == 'metades');
      expect(WindowLayout.containing(metades.zones.first)?.id, 'metades');
      final quadrantes =
          WindowLayout.all.firstWhere((l) => l.id == 'quadrantes');
      expect(WindowLayout.containing(quadrantes.zones.last)?.id, 'quadrantes');
    });

    test('zona de nenhum layout não inventa um', () {
      // Uma grade de 5 colunas não existe no catálogo. Aproximar poria as
      // janelas em lugares que ninguém escolheu.
      const estranha = WindowZone(cols: 5, rows: 1, col: 2, row: 0);
      expect(WindowLayout.containing(estranha), isNull);
      expect(WindowLayout.containing(null), isNull);
    });

    test('o layout do perfil sai da primeira zona preenchida', () {
      // O editor reabre no layout que a pessoa escolheu, e o perfil guarda
      // zonas em vez do nome do layout - um campo à parte poderia discordar
      // delas, e ninguém saberia em qual acreditar.
      final tres = WindowLayout.all.firstWhere((l) => l.id == 'tres-colunas');
      expect(
        WindowLayout.ofZones([null, tres.zones[1], null])?.id,
        'tres-colunas',
      );
    });

    test('perfil sem zona nenhuma não tem layout', () {
      expect(WindowLayout.ofZones([null, null]), isNull);
      expect(WindowLayout.ofZones([]), isNull);
    });
  });

  group('a zona no fio', () {
    test('vai e volta sem perder campo', () {
      // Um campo perdido viraria uma janela no lugar errado - mais confuso que
      // uma que não se moveu.
      const z = WindowZone(cols: 3, rows: 2, col: 1, row: 0, colspan: 2);
      expect(WindowZone.fromJson(z.toJson()), z);
    });

    test('sem colspan no JSON vale uma célula', () {
      // O caso comum é ocupar uma célula só; exigir o campo em todo item seria
      // peso sem informação.
      final z = WindowZone.fromJson({'cols': 2, 'rows': 1, 'col': 1, 'row': 0});
      expect(z.colspan, 1);
      expect(z.rowspan, 1);
      expect(z.isValid, isTrue);
    });

    test('zona fora da grade se reconhece inválida', () {
      expect(const WindowZone(cols: 2, rows: 1, col: 2, row: 0).isValid, isFalse);
      expect(
        const WindowZone(cols: 2, rows: 1, col: 1, row: 0, colspan: 2).isValid,
        isFalse,
      );
      expect(const WindowZone(cols: 0, rows: 1, col: 0, row: 0).isValid, isFalse);
    });

    test('duas zonas iguais são iguais', () {
      // O seletor compara zonas para destacar a escolhida; sem `==` por valor,
      // nenhuma apareceria marcada.
      const a = WindowZone(cols: 2, rows: 1, col: 0, row: 0);
      const b = WindowZone(cols: 2, rows: 1, col: 0, row: 0);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
