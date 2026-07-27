import 'package:flutter/material.dart';

import '../theme.dart';

/// Símbolo do RemoteOne: um quadrado com o gradiente da marca e o ícone de
/// "tela + sinal". Usado no login, no "Sobre" e como identidade visual.
class RemoteOneMark extends StatelessWidget {
  const RemoteOneMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: auroraGradient,
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: auroraViolet.withAlpha(110),
            blurRadius: size * 0.35,
            offset: Offset(0, size * 0.14),
          ),
        ],
      ),
      child: Icon(Icons.cast_connected, color: Colors.white, size: size * 0.5),
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
