import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskside_client/services/teclado_fisico.dart';

/// O tradutor de teclas do teclado físico.
///
/// É a única parte da funcionalidade que dá para verificar sem um iPad com
/// teclado na mão: quem tem o foco, quando o teclado da tela some e se o
/// iPadOS entregou a tecla são coisas do aparelho. A tradução, não — e é nela
/// que mora o erro que estragaria a digitação (um "A" virando Shift+A, um
/// acento virando código de tecla).
void main() {
  const teclado = TecladoFisico();

  group('texto', () {
    test('letra vira texto, não tecla', () {
      // `key_text` é o que preserva o layout: o computador do outro lado pode
      // estar em ABNT2 ou US, e mandar código de tecla erraria em um dos dois.
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.keyA, caractere: 'a'),
        {'kind': 'key_text', 'text': 'a'},
      );
    });

    test('maiúscula vai como maiúscula, e não como Shift+A', () {
      // O Shift já está embutido no caractere. Tratá-lo como modificador
      // mandaria um atalho para o computador em vez de uma letra.
      expect(
        teclado.traduzir(
          tecla: LogicalKeyboardKey.keyA,
          caractere: 'A',
          shift: true,
        ),
        {'kind': 'key_text', 'text': 'A'},
      );
    });

    test('vogal acentuada chega composta e passa inteira', () {
      // No ABNT2 o til e o "a" viram "ã" antes de chegar aqui.
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.keyA, caractere: 'ã'),
        {'kind': 'key_text', 'text': 'ã'},
      );
    });

    test('espaço vai como texto', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.space, caractere: ' '),
        {'kind': 'key_text', 'text': ' '},
      );
    });

    test('mas Ctrl+Espaço vira atalho com nome de tecla', () {
      // Um espaço solto como nome de tecla não seria entendido do outro lado;
      // é o único caractere que precisa de nome próprio dentro do atalho.
      expect(
        teclado.traduzir(
          tecla: LogicalKeyboardKey.space,
          caractere: ' ',
          ctrl: true,
        ),
        {
          'kind': 'key_combo',
          'modifiers': ['ctrl'],
          'key': 'space',
        },
      );
    });
  });

  group('teclas especiais', () {
    test('Enter vira key_press', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.enter),
        {'kind': 'key_press', 'key': 'enter'},
      );
    });

    test('o Enter do teclado numérico é o mesmo Enter', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.numpadEnter),
        {'kind': 'key_press', 'key': 'enter'},
      );
    });

    test('as setas viram nomes curtos', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.arrowUp),
        {'kind': 'key_press', 'key': 'up'},
      );
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.pageDown),
        {'kind': 'key_press', 'key': 'page_down'},
      );
    });

    test('Shift+seta é atalho de verdade: seleciona', () {
      // Aqui o Shift **é** modificador, ao contrário do caso da letra: uma
      // seta não produz caractere, então não há onde ele estar embutido.
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.arrowRight, shift: true),
        {
          'kind': 'key_combo',
          'modifiers': ['shift'],
          'key': 'right',
        },
      );
    });

    test('F5 chega como F5', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.f5),
        {'kind': 'key_press', 'key': 'f5'},
      );
    });
  });

  group('atalhos', () {
    test('Cmd+C vira Ctrl+C', () {
      // O motivo de existir a troca: no teclado do iPad, Cmd fica onde o Ctrl
      // fica num PC, e é ele que a pessoa aperta para copiar. Sem a troca,
      // Meta+C no Windows não copia nada.
      expect(
        teclado.traduzir(
          tecla: LogicalKeyboardKey.keyC,
          caractere: 'c',
          meta: true,
        ),
        {
          'kind': 'key_combo',
          'modifiers': ['ctrl'],
          'key': 'c',
        },
      );
    });

    test('sem a troca, Cmd continua sendo Meta', () {
      const semTroca = TecladoFisico(cmdViraCtrl: false);
      expect(
        semTroca.traduzir(
          tecla: LogicalKeyboardKey.keyC,
          caractere: 'c',
          meta: true,
        ),
        {
          'kind': 'key_combo',
          'modifiers': ['meta'],
          'key': 'c',
        },
      );
    });

    test('Ctrl+Shift+Esc leva os dois modificadores, na ordem fixa', () {
      expect(
        teclado.traduzir(
          tecla: LogicalKeyboardKey.escape,
          ctrl: true,
          shift: true,
        ),
        {
          'kind': 'key_combo',
          'modifiers': ['ctrl', 'shift'],
          'key': 'escape',
        },
      );
    });

    test('Ctrl e Cmd juntos não mandam ctrl duas vezes', () {
      expect(
        teclado.traduzir(
          tecla: LogicalKeyboardKey.keyS,
          caractere: 's',
          ctrl: true,
          meta: true,
        ),
        {
          'kind': 'key_combo',
          'modifiers': ['ctrl'],
          'key': 's',
        },
      );
    });

    test('com Ctrl apertado e sem caractere, vale o rótulo da tecla', () {
      // Alguns teclados não produzem caractere nenhum com Ctrl segurado. Sem
      // esta saída, Ctrl+C ficaria mudo justamente onde mais importa.
      final acao = teclado.traduzir(
        tecla: LogicalKeyboardKey.keyC,
        ctrl: true,
      );
      expect(acao?['kind'], 'key_combo');
      expect(acao?['key'], 'c');
    });

    test('atalho com letra maiúscula vira minúscula', () {
      // Ctrl+Shift+S chega com "S": o agente espera o nome da tecla, e o
      // maiúsculo já está dito pelo modificador.
      final acao = teclado.traduzir(
        tecla: LogicalKeyboardKey.keyS,
        caractere: 'S',
        ctrl: true,
        shift: true,
      );
      expect(acao?['key'], 's');
    });
  });

  group('o que não deve sair daqui', () {
    test('modificadora sozinha não manda nada', () {
      // Segurar Cmd para depois apertar C passa por aqui primeiro. Mandar algo
      // neste momento digitaria lixo antes do atalho.
      for (final tecla in const [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altRight,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.capsLock,
      ]) {
        expect(teclado.traduzir(tecla: tecla), isNull, reason: '$tecla');
      }
    });

    test('modificadora sozinha continua nula mesmo com outra segurada', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.shiftLeft, meta: true),
        isNull,
      );
    });

    test('tecla desconhecida e sem caractere não vira nada', () {
      expect(teclado.traduzir(tecla: LogicalKeyboardKey.insert), isNull);
    });

    test('caractere vazio não vira texto vazio', () {
      expect(
        teclado.traduzir(tecla: LogicalKeyboardKey.keyA, caractere: ''),
        isNull,
      );
    });
  });
}
