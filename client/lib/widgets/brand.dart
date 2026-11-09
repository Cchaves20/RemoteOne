import 'package:flutter/material.dart';

import 'identidade.dart';

/// Símbolo do Deskside: o monitor aceso com o cursor da marca dentro. Usado no
/// login, no cadastro e no "Sobre".
///
/// Desenhado, e não mais a imagem do ícone: o desenho acompanha o tamanho sem
/// serrilhar e tem o brilho da tela, que a imagem achatava.
class DesksideMark extends StatelessWidget {
  const DesksideMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) => LogoDeskside(largura: size * 1.3);
}

/// Fundo com o brilho suave da marca no topo (login, cadastro e afins).
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => BrilhoDoTopo(child: child);
}
