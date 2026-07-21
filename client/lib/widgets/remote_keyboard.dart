import 'package:flutter/material.dart';

/// Teclado customizado para controle remoto: além de digitar texto, oferece
/// teclas que o teclado do celular não tem (Ctrl, Alt, Tab, Esc, setas...).
///
/// Os modificadores (Ctrl/Alt/Shift) são "grudentos": toque em Ctrl e depois
/// em C para enviar Ctrl+C; toque em Ctrl e depois numa tecla especial para o
/// atalho correspondente.
class RemoteKeyboard extends StatefulWidget {
  const RemoteKeyboard({
    super.key,
    required this.onText,
    required this.onKey,
    required this.onCombo,
  });

  /// Texto digitado (uma ou mais letras).
  final void Function(String text) onText;

  /// Tecla especial (nomes do backend: enter, tab, escape, up, down...).
  final void Function(String specialKey) onKey;

  /// Atalho: modificadores + tecla (um caractere ou nome de tecla especial).
  final void Function(List<String> modifiers, String key) onCombo;

  @override
  State<RemoteKeyboard> createState() => _RemoteKeyboardState();
}

class _RemoteKeyboardState extends State<RemoteKeyboard> {
  final _controller = TextEditingController();
  final Set<String> _mods = {};
  String _prev = '';

  static const _specials = <(String, String)>[
    ('Esc', 'escape'),
    ('Tab', 'tab'),
    ('←', 'left'),
    ('↑', 'up'),
    ('↓', 'down'),
    ('→', 'right'),
    ('Enter', 'enter'),
    ('⌫', 'backspace'),
    ('Del', 'delete'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleMod(String modifier) {
    setState(() {
      if (!_mods.remove(modifier)) _mods.add(modifier);
    });
  }

  void _special(String name) {
    if (_mods.isNotEmpty) {
      widget.onCombo(_mods.toList(), name);
      setState(_mods.clear);
    } else {
      widget.onKey(name);
    }
  }

  void _onChanged(String value) {
    if (value.length > _prev.length && value.startsWith(_prev)) {
      final added = value.substring(_prev.length);
      if (_mods.isNotEmpty && added.length == 1) {
        widget.onCombo(_mods.toList(), added);
        setState(_mods.clear);
      } else {
        widget.onText(added);
      }
    } else if (value.length < _prev.length) {
      // Apagou no campo → envia Backspace ao computador.
      for (var i = 0; i < _prev.length - value.length; i++) {
        widget.onKey('backspace');
      }
    }
    _prev = value;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in const [
                  ('Ctrl', 'ctrl'),
                  ('Alt', 'alt'),
                  ('Shift', 'shift'),
                ])
                  _ModKey(
                    label: m.$1,
                    active: _mods.contains(m.$2),
                    onTap: () => _toggleMod(m.$2),
                  ),
                for (final s in _specials)
                  OutlinedButton(
                    onPressed: () => _special(s.$2),
                    child: Text(s.$1),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              onChanged: _onChanged,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'Digitar (com Ctrl/Alt ativo, vira atalho)',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModKey extends StatelessWidget {
  const _ModKey({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return active
        ? FilledButton(onPressed: onTap, child: Text(label))
        : OutlinedButton(onPressed: onTap, child: Text(label));
  }
}
