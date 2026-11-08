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

/// Uma lista de mentira no lugar da que está vindo: um ícone e uma ou duas
/// linhas por item, na altura de um `ListTile`.
///
/// No lugar do círculo girando, por dois motivos: a tela já mostra o formato
/// do que vai aparecer, e o conteúdo, quando chega, ocupa o mesmo lugar, sem
/// empurrar nada. O leitor de tela ouve [rotulo] uma vez, e não cada bloco.
class EsqueletoDeLista extends StatelessWidget {
  const EsqueletoDeLista({
    super.key,
    required this.rotulo,
    this.itens = 6,
    this.duasLinhas = true,
  });

  final String rotulo;
  final int itens;
  final bool duasLinhas;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: rotulo,
      liveRegion: true,
      child: ExcludeSemantics(
        child: Pulse(
          child: ListView.builder(
            physics: const NeverScrollableScrollPhysics(),
            itemCount: itens,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const SkeletonBox(width: 24, height: 24, radius: 6),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Larguras que variam: blocos todos iguais parecem
                        // uma grade, e não uma lista de nomes.
                        FractionallySizedBox(
                          widthFactor: const [0.7, 0.5, 0.6, 0.45][i % 4],
                          child: const SkeletonBox(height: 14),
                        ),
                        if (duasLinhas) ...[
                          const SizedBox(height: 8),
                          const FractionallySizedBox(
                            widthFactor: 0.3,
                            child: SkeletonBox(height: 11),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
