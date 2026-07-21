import 'package:flutter/material.dart';

/// Área sensível ao toque com gestos de trackpad:
/// - 1 dedo deslizando → mover o cursor
/// - toque → clique esquerdo
/// - segurar → clique direito
/// - 2 dedos deslizando → rolar
///
/// Usa `onScaleUpdate` (que informa `pointerCount`) para distinguir um de dois
/// dedos. O consumidor decide como agrupar/enviar os movimentos e a rolagem.
class Touchpad extends StatelessWidget {
  const Touchpad({
    super.key,
    required this.onMove,
    required this.onScroll,
    required this.onLeftClick,
    required this.onRightClick,
  });

  final void Function(double dx, double dy) onMove;
  final void Function(double dy) onScroll;
  final VoidCallback onLeftClick;
  final VoidCallback onRightClick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onLeftClick,
      onLongPress: onRightClick,
      onScaleUpdate: (details) {
        final delta = details.focalPointDelta;
        if (details.pointerCount >= 2) {
          onScroll(delta.dy);
        } else {
          onMove(delta.dx, delta.dy);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.touch_app, size: 40, color: scheme.outline),
              const SizedBox(height: 8),
              Text(
                'Deslize para mover · toque para clicar\n'
                'segure para o botão direito · 2 dedos para rolar',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
