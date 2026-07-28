import 'package:flutter/material.dart';

import '../services/word_suggester.dart';

enum _Layer { letters, symbols, accents }

/// A palavra que está sendo digitada agora, do ponto de vista do app.
///
/// O teclado manda cada tecla direto ao computador e não tem como ler o que há
/// na tela dele; então o app mantém o seu próprio rastro do que foi digitado
/// desde o último espaço. Quem move o cursor (um toque na tela, uma seta) tem
/// de chamar [reset] — a partir dali o rastro não corresponde mais a nada.
class TypedWord extends ValueNotifier<String> {
  TypedWord() : super('');

  void addChar(String c) {
    // Só letras continuam a palavra. Espaço, pontuação e número a encerram.
    if (RegExp(r"^[a-zA-Zà-öø-ÿ']$").hasMatch(c)) {
      value = value + c;
    } else {
      reset();
    }
  }

  void backspace() {
    if (value.isNotEmpty) value = value.substring(0, value.length - 1);
  }

  void reset() {
    if (value.isNotEmpty) value = '';
  }
}

/// Teclado em layout de computador com camadas: letras (QWERTY), símbolos/
/// pontuação e acentos (PT-BR). Modificadores Ctrl/Alt/Shift são grudentos;
/// letra sozinha digita, com Ctrl/Alt vira atalho, Shift aplica maiúscula.
class RemoteKeyboard extends StatefulWidget {
  const RemoteKeyboard({
    super.key,
    required this.onText,
    required this.onKey,
    required this.onCombo,
    this.onReplace,
    this.typed,
    this.suggester,
  });

  final void Function(String text) onText;
  final void Function(String specialKey) onKey;
  final void Function(List<String> modifiers, String key) onCombo;

  /// Apaga `backspaces` caracteres e digita `text` numa ação só. Sem isto a
  /// barra de sugestões não aparece — trocar a palavra em várias mensagens
  /// separadas embaralharia o texto no canal não ordenado.
  final void Function(int backspaces, String text)? onReplace;

  /// Rastro do que está sendo digitado. Quem for dono da tela precisa
  /// reiniciá-lo quando o cursor muda de lugar.
  final TypedWord? typed;

  /// De onde saem as sugestões. `null` = barra desligada.
  final WordSuggester? suggester;

  @override
  State<RemoteKeyboard> createState() => _RemoteKeyboardState();
}

class _RemoteKeyboardState extends State<RemoteKeyboard> {
  final Set<String> _mods = {};
  _Layer _layer = _Layer.letters;

  List<List<String>> _rowsFor(_Layer layer) {
    switch (layer) {
      case _Layer.letters:
        return ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
            .map((s) => s.split(''))
            .toList();
      case _Layer.symbols:
        return [
          '1234567890'.split(''),
          ['@', '#', r'$', '%', '&', '*', '-', '_', '/', '+'],
          ['.', ',', '?', '!', "'", '"', ':', ';', '='],
        ];
      case _Layer.accents:
        return [
          ['á', 'à', 'â', 'ã', 'é', 'ê'],
          ['í', 'ó', 'ô', 'õ', 'ú'],
          ['ç', 'ü', 'ª', 'º', '°'],
        ];
    }
  }

  String get _layerLabel => switch (_layer) {
        _Layer.letters => '?#',
        _Layer.symbols => 'áé',
        _Layer.accents => 'abc',
      };

  void _cycleLayer() {
    setState(() {
      _layer = switch (_layer) {
        _Layer.letters => _Layer.symbols,
        _Layer.symbols => _Layer.accents,
        _Layer.accents => _Layer.letters,
      };
    });
  }

  void _toggleMod(String modifier) {
    setState(() {
      if (!_mods.remove(modifier)) _mods.add(modifier);
    });
  }

  bool get _hasComboMod =>
      _mods.contains('ctrl') || _mods.contains('alt') || _mods.contains('meta');

  void _typeChar(String c) {
    if (_hasComboMod) {
      widget.onCombo(_mods.toList(), c);
      setState(_mods.clear);
    } else if (_mods.contains('shift')) {
      widget.onText(c.toUpperCase());
      setState(() => _mods.remove('shift'));
    } else {
      widget.onText(c);
    }
    final rastro = widget.typed;
    if (rastro != null) {
      // Espaço e pontuação encerram a palavra: é o momento de guardá-la, antes
      // de o rastro ser zerado.
      if (!RegExp(r"^[a-zA-Zà-öø-ÿ']$").hasMatch(c)) _aprender(rastro.value);
      rastro.addChar(c);
    }
  }

  void _special(String name) {
    if (_mods.isNotEmpty) {
      widget.onCombo(_mods.toList(), name);
      setState(_mods.clear);
    } else {
      widget.onKey(name);
    }
    final rastro = widget.typed;
    if (rastro == null) return;
    if (name == 'backspace') {
      rastro.backspace();
    } else {
      // Enter, seta, Esc, Tab: o cursor saiu de onde estava, então a palavra
      // que o app achava que estava sendo digitada acabou.
      _aprender(rastro.value);
      rastro.reset();
    }
  }

  void _aprender(String palavra) {
    if (palavra.length >= 3) widget.suggester?.learn(palavra);
  }

  /// Troca a palavra digitada pela sugestão tocada.
  ///
  /// Numa ação só (apagar + digitar): o canal de dados é não ordenado, e em
  /// mensagens separadas o texto novo poderia chegar antes dos backspaces.
  void _usarSugestao(String palavra) {
    final rastro = widget.typed;
    final trocar = widget.onReplace;
    if (rastro == null || trocar == null) return;
    trocar(rastro.value.length, '$palavra ');
    _aprender(palavra);
    rastro.reset();
  }

  static const _style = ButtonStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
  );

  /// Balão com a letra, mostrado acima da tecla enquanto o dedo está nela.
  ///
  /// Serve para o dedo não esconder a confirmação do que foi tocado — o mesmo
  /// motivo pelo qual o teclado do iPhone faz isso. Só nas teclas de caractere:
  /// em Ctrl ou Esc não há dúvida sobre o que se apertou.
  OverlayEntry? _preview;

  void _showPreview(BuildContext keyContext, String label) {
    _hidePreview();
    final box = keyContext.findRenderObject();
    final overlay = Overlay.maybeOf(keyContext);
    if (box is! RenderBox || !box.hasSize || overlay == null) return;
    final topo = box.localToGlobal(Offset.zero);
    final cores = Theme.of(keyContext).colorScheme;
    _preview = OverlayEntry(
      builder: (_) => Positioned(
        left: topo.dx - 12,
        top: topo.dy - 48,
        width: box.size.width + 24,
        // Sem toque: o balão nasce debaixo do dedo e não pode roubar o gesto
        // que o criou.
        child: IgnorePointer(
          child: Material(
            elevation: 6,
            color: cores.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 44,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    color: cores.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_preview!);
  }

  void _hidePreview() {
    _preview?.remove();
    _preview = null;
  }

  @override
  void dispose() {
    _hidePreview();
    super.dispose();
  }

  Widget _key(
    Widget child,
    VoidCallback onTap, {
    int flex = 2,
    bool active = false,
    String? preview,
  }) {
    Widget botao = SizedBox(
      height: 34,
      child: active
          ? FilledButton(onPressed: onTap, style: _style, child: FittedBox(child: child))
          : OutlinedButton(onPressed: onTap, style: _style, child: FittedBox(child: child)),
    );
    if (preview != null) {
      botao = Builder(
        builder: (keyContext) => Listener(
          onPointerDown: (_) => _showPreview(keyContext, preview),
          onPointerUp: (_) => _hidePreview(),
          onPointerCancel: (_) => _hidePreview(),
          child: botao,
        ),
      );
    }
    return Expanded(
      flex: flex,
      child: Padding(padding: const EdgeInsets.all(1.5), child: botao),
    );
  }

  Widget _charKey(String c) {
    final label = _mods.contains('shift') ? c.toUpperCase() : c;
    return _key(Text(label), () => _typeChar(c), preview: label);
  }

  Row _charRow(List<String> chars) => Row(children: [for (final c in chars) _charKey(c)]);

  /// Barra de sugestões: só aparece quando há o que sugerir, e **nunca** troca
  /// nada sozinha. Tocar numa palavra é a única coisa que muda o texto.
  Widget _suggestionBar() {
    final rastro = widget.typed;
    final sugeridor = widget.suggester;
    if (rastro == null || sugeridor == null || widget.onReplace == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<String>(
      valueListenable: rastro,
      builder: (context, digitado, _) {
        final sugestoes = sugeridor.suggest(digitado);
        if (sugestoes.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 34,
          child: Row(
            children: [
              for (final palavra in sugestoes)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(1.5),
                    child: TextButton(
                      style: _style,
                      onPressed: () => _usarSugestao(palavra),
                      child: FittedBox(child: Text(palavra)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rowsFor(_layer);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _suggestionBar(),
              // Especiais (sempre visíveis).
              Row(
                children: [
                  _key(const Text('Esc'), () => _special('escape')),
                  _key(const Text('Tab'), () => _special('tab')),
                  _key(const Icon(Icons.arrow_upward, size: 16), () => _special('up')),
                  _key(const Icon(Icons.arrow_downward, size: 16), () => _special('down')),
                  _key(const Icon(Icons.arrow_back, size: 16), () => _special('left')),
                  _key(const Icon(Icons.arrow_forward, size: 16), () => _special('right')),
                  _key(const Text('Del'), () => _special('delete')),
                ],
              ),
              _charRow(rows[0]),
              _charRow(rows[1]),
              // Shift + terceira linha + Backspace.
              Row(
                children: [
                  _key(const Icon(Icons.keyboard_capslock, size: 16),
                      () => _toggleMod('shift'),
                      flex: 3, active: _mods.contains('shift')),
                  for (final c in rows[2]) _charKey(c),
                  _key(const Icon(Icons.backspace_outlined, size: 16),
                      () => _special('backspace'),
                      flex: 3),
                ],
              ),
              // Camada + modificadores + espaço + ponto + Enter.
              Row(
                children: [
                  _key(Text(_layerLabel), _cycleLayer, flex: 3),
                  _key(const Text('Ctrl'), () => _toggleMod('ctrl'),
                      flex: 3, active: _mods.contains('ctrl')),
                  _key(const Text('Alt'), () => _toggleMod('alt'),
                      flex: 3, active: _mods.contains('alt')),
                  _key(const Icon(Icons.space_bar, size: 16), () => _typeChar(' '), flex: 8),
                  _key(const Text('.'), () => _typeChar('.')),
                  _key(const Icon(Icons.keyboard_return, size: 16),
                      () => _special('enter'),
                      flex: 4),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
