import 'package:flutter/material.dart';

/// Teclado em layout de computador (QWERTY), com modificadores e teclas
/// especiais que o celular não tem. Cada tecla de caractere digita direto;
/// com Ctrl/Alt/Meta ativos, vira atalho (ex.: Ctrl+C). Shift aplica
/// maiúscula na próxima letra (ou entra no atalho).
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

  static const _row1 = '1234567890';
  static const _row2 = 'qwertyuiop';
  static const _row3 = 'asdfghjkl';
  static const _row4 = 'zxcvbnm';

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

  Widget _key(Widget child, VoidCallback onTap, {int flex = 2, bool active = false}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: SizedBox(
          height: 34,
          child: active
              ? FilledButton(
                  onPressed: onTap,
                  style: _style,
                  child: FittedBox(child: child),
                )
              : OutlinedButton(
                  onPressed: onTap,
                  style: _style,
                  child: FittedBox(child: child),
                ),
        ),
      ),
    );
  }

  static const _style = ButtonStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
  );

  Widget _charKey(String c) {
    final label = _mods.contains('shift') ? c.toUpperCase() : c;
    return _key(Text(label), () => _typeChar(c));
  }

  Row _charRow(String chars) => Row(
        children: [for (final c in chars.split('')) _charKey(c)],
      );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Especiais: Esc, Tab, setas, Del.
              Row(
                children: [
                  _key(const Text('Esc'), () => _special('escape')),
                  _key(const Text('Tab'), () => _special('tab')),
                  _key(const Icon(Icons.arrow_upward, size: 18),
                      () => _special('up')),
                  _key(const Icon(Icons.arrow_downward, size: 18),
                      () => _special('down')),
                  _key(const Icon(Icons.arrow_back, size: 18),
                      () => _special('left')),
                  _key(const Icon(Icons.arrow_forward, size: 18),
                      () => _special('right')),
                  _key(const Text('Del'), () => _special('delete')),
                ],
              ),
              _charRow(_row1),
              _charRow(_row2),
              _charRow(_row3),
              // Shift + zxcvbnm + Backspace.
              Row(
                children: [
                  _key(const Icon(Icons.keyboard_capslock, size: 18),
                      () => _toggleMod('shift'),
                      flex: 3, active: _mods.contains('shift')),
                  for (final c in _row4.split('')) _charKey(c),
                  _key(const Icon(Icons.backspace_outlined, size: 18),
                      () => _special('backspace'),
                      flex: 3),
                ],
              ),
              // Modificadores + espaço + Enter.
              Row(
                children: [
                  _key(const Text('Ctrl'), () => _toggleMod('ctrl'),
                      flex: 3, active: _mods.contains('ctrl')),
                  _key(const Text('Alt'), () => _toggleMod('alt'),
                      flex: 3, active: _mods.contains('alt')),
                  _key(const Text('espaço'), () => _typeChar(' '), flex: 8),
                  _key(const Icon(Icons.keyboard_return, size: 18),
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
