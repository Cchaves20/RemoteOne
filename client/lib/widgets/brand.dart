import 'package:flutter/material.dart';

import '../theme.dart';

/// Símbolo do Deskside: a "tela com cursor" em gradiente (mesmo glifo do
/// ícone do app). Usado no login e no "Sobre".
class DesksideMark extends StatelessWidget {
  const DesksideMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/icon/deskside_glyph.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

/// Fundo com um brilho suave da marca no topo (para telas como o login).
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1.1),
          radius: 1.3,
          colors: [
            auroraViolet.withAlpha(Theme.of(context).brightness == Brightness.dark ? 80 : 40),
            scheme.surface.withAlpha(0),
          ],
        ),
      ),
      child: child,
    );
  }
}
