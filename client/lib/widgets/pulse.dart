import 'package:flutter/material.dart';

/// Efeito de "respiração" (opacidade pulsante) para placeholders de carregamento.
/// Sem dependências externas — usa um AnimationController simples.
class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.child});

  final Widget child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 0.75).animate(curve),
      child: widget.child,
    );
  }
}

/// Caixa arredondada usada como bloco de placeholder dentro de um [Pulse].
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 8,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withAlpha(28),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
