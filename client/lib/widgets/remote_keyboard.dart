import 'package:flutter/material.dart';

enum _Layer { letters, symbols, accents }

/// Teclado em layout de computador com camadas: letras (QWERTY), símbolos/
/// pontuação e acentos (PT-BR). Modificadores Ctrl/Alt/Shift são grudentos;
/// letra sozinha digita, com Ctrl/Alt vira atalho, Shift aplica maiúscula.
class RemoteKeyboard extends StatefulWidget {
  const RemoteKeyboard({
    super.key,
    required this.onText,
    required this.onKey,
    required this.onCombo,
  });

  final void Function(String text) onText;
  final void Function(String specialKey) onKey;
  final void Function(List<String> modifiers, String key) onCombo;

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
  }

  void _special(String name) {
    if (_mods.isNotEmpty) {
      widget.onCombo(_mods.toList(), name);
      setState(_mods.clear);
    } else {
      widget.onKey(name);
    }
  }

  static const _style = ButtonStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
  );

  Widget _key(Widget child, VoidCallback onTap, {int flex = 2, bool active = false}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: SizedBox(
          height: 34,
          child: active
              ? FilledButton(onPressed: onTap, style: _style, child: FittedBox(child: child))
              : OutlinedButton(onPressed: onTap, style: _style, child: FittedBox(child: child)),
        ),
      ),
    );
  }

  Widget _charKey(String c) {
    final label = _mods.contains('shift') ? c.toUpperCase() : c;
    return _key(Text(label), () => _typeChar(c));
  }

  Row _charRow(List<String> chars) => Row(children: [for (final c in chars) _charKey(c)]);

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
                  _key(const Text('espaço'), () => _typeChar(' '), flex: 8),
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
