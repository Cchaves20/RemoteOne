import 'package:flutter/services.dart';

/// Traduz teclas de um teclado físico para as ações que o agente entende.
///
/// Separado da tela por um motivo prático: aqui não há widget, foco nem
/// aparelho — é função pura, e portanto é a única parte disto que dá para
/// testar sem um iPad na mão. O resto (quem tem o foco, quando o teclado
/// aparece) só se verifica no aparelho.
///
/// ## Os três caminhos, e por que não é um só
///
/// - **Texto** vai por `key_text`. Acento e cedilha do teclado ABNT2 chegam
///   ao Flutter já compostos: o til e a vogal viram "ã" antes de nós. Mandar
///   código de tecla estragaria isso, porque o computador do outro lado pode
///   estar com outro layout.
/// - **Teclas especiais** (setas, Enter, F5) não têm caractere, e vão por
///   `key_press`.
/// - **Atalhos** vão por `key_combo`, com os modificadores separados.
///
/// ## O que o iPadOS fica para si
///
/// Cmd+Espaço, Cmd+Tab, Cmd+H e as capturas de tela nunca chegam ao
/// aplicativo — o sistema os intercepta antes. Não há contorno; um `Alt+Tab`
/// no computador remoto precisa de um botão na tela.
class TecladoFisico {
  const TecladoFisico({this.cmdViraCtrl = true});

  /// Cmd do iPad vale como Ctrl do computador.
  ///
  /// Ligado por padrão porque é onde a memória muscular está: no teclado do
  /// iPad, Cmd fica exatamente onde o Ctrl fica num teclado de PC, e é ele que
  /// a pessoa aperta para copiar. Sem esta troca, Cmd+C chegaria como Meta+C —
  /// que no Windows abre o menu Iniciar em vez de copiar.
  final bool cmdViraCtrl;

  /// As teclas que não produzem caractere e têm nome próprio no protocolo.
  ///
  /// `final`, e não `const`: `LogicalKeyboardKey` sobrescreve `==` e
  /// `hashCode`, e o Dart proíbe esses tipos como chave de mapa constante — um
  /// mapa `const` é montado em tempo de compilação, quando ainda não dá para
  /// chamar o `==` de ninguém. Como é `static`, continua existindo uma vez só
  /// para todas as instâncias, que era o que o `const` estava fazendo aqui.
  static final Map<LogicalKeyboardKey, String> _especiais = {
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.numpadEnter: 'enter',
    LogicalKeyboardKey.backspace: 'backspace',
    LogicalKeyboardKey.tab: 'tab',
    LogicalKeyboardKey.escape: 'escape',
    LogicalKeyboardKey.delete: 'delete',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.home: 'home',
    LogicalKeyboardKey.end: 'end',
    LogicalKeyboardKey.pageUp: 'page_up',
    LogicalKeyboardKey.pageDown: 'page_down',
    LogicalKeyboardKey.f1: 'f1',
    LogicalKeyboardKey.f2: 'f2',
    LogicalKeyboardKey.f3: 'f3',
    LogicalKeyboardKey.f4: 'f4',
    LogicalKeyboardKey.f5: 'f5',
    LogicalKeyboardKey.f6: 'f6',
    LogicalKeyboardKey.f7: 'f7',
    LogicalKeyboardKey.f8: 'f8',
    LogicalKeyboardKey.f9: 'f9',
    LogicalKeyboardKey.f10: 'f10',
    LogicalKeyboardKey.f11: 'f11',
    LogicalKeyboardKey.f12: 'f12',
  };

  /// As teclas que só existem para modificar outras. Sozinhas não mandam nada.
  ///
  /// `final` pelo mesmo motivo do mapa acima.
  static final Set<LogicalKeyboardKey> _modificadoras = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  /// A ação a mandar, ou `null` quando a tecla não deve ir para o computador.
  ///
  /// `null` é resposta legítima e frequente: teclas modificadoras sozinhas,
  /// e qualquer coisa que não vire texto nem tenha nome conhecido.
  Map<String, dynamic>? traduzir({
    required LogicalKeyboardKey tecla,
    String? caractere,
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
    bool meta = false,
  }) {
    if (_modificadoras.contains(tecla)) return null;

    final mods = <String>[
      if (ctrl || (meta && cmdViraCtrl)) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (meta && !cmdViraCtrl) 'meta',
    ];

    final especial = _especiais[tecla];
    if (especial != null) {
      if (mods.isEmpty) return {'kind': 'key_press', 'key': especial};
      return {'kind': 'key_combo', 'modifiers': mods, 'key': especial};
    }

    // Shift sozinho **não** faz atalho: ele já está embutido no caractere que
    // chegou. Tratá-lo como modificador transformaria um "A" maiúsculo em
    // Shift+A, que é outra coisa para quem recebe.
    final atalho = ctrl || alt || meta;
    if (atalho) {
      final nome = _nomeDaTecla(tecla, caractere);
      if (nome == null) return null;
      return {'kind': 'key_combo', 'modifiers': mods, 'key': nome};
    }

    // Espaço tem nome próprio no protocolo, mas também chega como caractere.
    // Vai como texto: é o que preserva o comportamento de digitação.
    if (caractere != null && caractere.isNotEmpty) {
      return {'kind': 'key_text', 'text': caractere};
    }
    return null;
  }

  /// O nome de uma tecla comum dentro de um atalho.
  ///
  /// Prefere o caractere, e cai no rótulo da tecla quando ele não veio — com
  /// Ctrl apertado, alguns teclados não produzem caractere nenhum.
  static String? _nomeDaTecla(LogicalKeyboardKey tecla, String? caractere) {
    // O espaço é o único caractere que vale como nome de tecla e não sobrevive
    // a um `trim`: fora de atalho ele vai como texto, mas em Ctrl+Espaço
    // precisa do nome que o agente conhece.
    if (tecla == LogicalKeyboardKey.space) return 'space';
    if (caractere != null && caractere.trim().isNotEmpty) {
      return caractere.toLowerCase();
    }
    final rotulo = tecla.keyLabel.trim();
    if (rotulo.isEmpty) return null;
    return rotulo.toLowerCase();
  }
}
