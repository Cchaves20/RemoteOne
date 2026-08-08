import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/window_zone.dart';
import '../theme.dart';

/// Desenha uma grade com uma zona destacada — a mesma linguagem visual do menu
/// de encaixe do Windows 11.
///
/// É um desenho, e não um ícone: os layouts são cinco, e cada um precisaria de
/// um ícone próprio que ninguém tem. Retângulos com espaço entre eles dizem a
/// mesma coisa, em qualquer tamanho, e continuam certos quando um layout novo
/// entrar na lista.
class LayoutThumb extends StatelessWidget {
  const LayoutThumb({
    super.key,
    required this.layout,
    this.highlight,
    this.size = 34,
  });

  final WindowLayout layout;

  /// A zona a destacar. `null` = todas iguais, que é como o seletor de layout
  /// mostra as opções.
  final WindowZone? highlight;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Um pouco mais larga que alta: é a forma de uma tela, e sem isso os
    // layouts de coluna e de linha ficariam parecidos demais.
    final largura = size * 1.4;
    return SizedBox(
      width: largura,
      height: size,
      child: Stack(
        children: [
          for (final z in layout.zones)
            Positioned(
              left: largura * z.col / z.cols,
              top: size * z.row / z.rows,
              width: largura * z.colspan / z.cols,
              height: size * z.rowspan / z.rows,
              child: Padding(
                // O respiro é o que separa uma zona da outra no desenho; sem
                // ele o layout de quatro parece um retângulo só.
                padding: const EdgeInsets.all(1),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: highlight == null
                        ? Colors.white24
                        : (z == highlight ? auroraCyan : Colors.white12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Escolhe como a tela é dividida quando o perfil abre todos os programas.
///
/// Inclui a opção de **não** dividir, e ela não é enfeite: abrir sem posicionar
/// era o comportamento anterior, e continua sendo uma escolha legítima para
/// quem só quer os programas no ar.
class LayoutPicker extends StatelessWidget {
  const LayoutPicker({
    super.key,
    required this.selected,
    required this.strings,
    required this.onSelect,
  });

  final WindowLayout? selected;
  final Strings strings;
  final ValueChanged<WindowLayout?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.layoutTitle,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        const SizedBox(height: 2),
        Text(
          strings.layoutHint,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _opcao(
                context,
                escolhido: selected == null,
                onTap: () => onSelect(null),
                child: SizedBox(
                  width: 34 * 1.4,
                  height: 34,
                  child: Icon(
                    Icons.close,
                    size: 18,
                    color: selected == null ? auroraCyan : Colors.white24,
                  ),
                ),
              ),
              for (final l in WindowLayout.all)
                _opcao(
                  context,
                  escolhido: selected?.id == l.id,
                  onTap: () => onSelect(l),
                  child: LayoutThumb(layout: l),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _opcao(
    BuildContext context, {
    required bool escolhido,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: escolhido ? auroraCyan : Colors.white12,
              width: escolhido ? 2 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Escolhe em qual zona do layout um programa abre.
///
/// Abre uma folha em vez de um menu porque o que se escolhe é uma **posição**,
/// e posição se escolhe olhando o desenho — uma lista de "esquerda, direita,
/// canto superior" obrigaria a traduzir texto de volta para geometria.
class ZoneChooser extends StatelessWidget {
  const ZoneChooser({
    super.key,
    required this.layout,
    required this.zone,
    required this.strings,
    required this.onPick,
  });

  final WindowLayout layout;
  final WindowZone? zone;
  final Strings strings;
  final ValueChanged<WindowZone?> onPick;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: strings.zoneChoose,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _abrir(context),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: LayoutThumb(layout: layout, highlight: zone, size: 24),
        ),
      ),
    );
  }

  Future<void> _abrir(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.zoneChoose,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final z in layout.zones)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        onPick(z);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: z == zone ? auroraCyan : Colors.white12,
                            width: z == zone ? 2 : 1,
                          ),
                        ),
                        child: LayoutThumb(layout: layout, highlight: z, size: 44),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Sem lugar fixo continua sendo escolha: um programa solto no
              // meio de três encaixados é um caso legítimo.
              TextButton.icon(
                icon: const Icon(Icons.close, size: 18),
                label: Text(strings.zoneNone),
                onPressed: () {
                  Navigator.of(sheet).pop();
                  onPick(null);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
