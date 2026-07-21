import 'package:flutter/material.dart';

/// Área sensível ao toque: deslizar reporta deltas de movimento; tocar reporta
/// um clique. O consumidor decide como agrupar/enviar os movimentos.
class Touchpad extends StatelessWidget {
  const Touchpad({super.key, required this.onMove, required this.onTap});

  final void Function(double dx, double dy) onMove;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onPanUpdate: (details) => onMove(details.delta.dx, details.delta.dy),
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
                'Deslize para mover · toque para clicar',
                style: TextStyle(color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
