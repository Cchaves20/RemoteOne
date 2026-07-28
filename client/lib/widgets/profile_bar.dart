import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/control_profile.dart';
import '../theme.dart';

/// Barra seletora de perfis: a mesma ideia da dock de aplicativos (o Dock do
/// macOS), só que o que se escolhe aqui não é um programa e sim um **conjunto
/// de atalhos**.
///
/// São duas pistas na mesma barra: a de cima (ou a da esquerda, com o celular
/// deitado) escolhe o perfil; a outra só existe enquanto há um perfil escolhido
/// e traz os botões dele. Tocar de novo no perfil aceso fecha a segunda pista —
/// é assim que a barra volta a ser fininha quando não está em uso, que é o
/// tempo todo em que a pessoa só quer ver a tela do computador.
///
/// Ela fica na borda **oposta** à da dock (esquerda no deitado, topo no em pé):
/// as duas flutuam, e disputar a mesma borda faria uma cobrir a outra.
class ProfileBar extends StatefulWidget {
  const ProfileBar({
    super.key,
    required this.vertical,
    required this.area,
    required this.selected,
    required this.strings,
    required this.onSelect,
    required this.onAction,
    this.profiles,
  });

  /// Barra em pé (celular deitado). Deitada quando o celular está em pé.
  final bool vertical;

  /// Área em que a barra se posiciona — a mesma da imagem do computador.
  final Size area;

  final ControlProfile? selected;
  final Strings strings;
  final ValueChanged<ControlProfile?> onSelect;
  final ValueChanged<ProfileAction> onAction;

  /// Injetável nos testes; na tela real são os perfis que vêm com o app.
  final List<ControlProfile>? profiles;

  @override
  State<ProfileBar> createState() => _ProfileBarState();
}

class _ProfileBarState extends State<ProfileBar>
    with SingleTickerProviderStateMixin {
  /// Lado do botão de perfil e do botão de atalho. O de atalho é mais largo
  /// porque carrega o nome do atalho embaixo do ícone ("Ctrl+Shift+Esc").
  static const double _profileTile = 44;
  static const double _actionTile = 58;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  /// A curva vive aqui, e nao no `build`: criada a cada quadro, cada uma
  /// deixaria um ouvinte no controlador ate o coletor de lixo passar.
  late final Animation<double> _curved = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutBack,
  );

  /// Posição ao longo da borda, de -1 (topo/esquerda) a 1 (base/direita).
  double _pos = 0;

  @override
  void initState() {
    super.initState();
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.vertical;
    final profiles = widget.profiles ?? ControlProfile.builtIn;
    final selected = widget.selected;
    // Teto de comprimento: aberta, a barra pode chegar a três quartos da tela
    // — passar disso é cobrir a tela do computador, e ela ainda rola por
    // dentro se um perfil tiver atalhos demais.
    final maxLength = (vertical ? widget.area.height : widget.area.width) * 0.75;

    final lanes = <Widget>[
      _lane(
        thickness: _profileTile,
        vertical: vertical,
        children: [for (final p in profiles) _profileButton(p)],
      ),
      if (selected != null) ...[
        _divider(vertical: vertical),
        _lane(
          thickness: _actionTile,
          vertical: vertical,
          children: [for (final a in selected.actions) _actionButton(a)],
        ),
      ],
    ];

    // As pistas se empilham no eixo transversal: com a barra em pé elas ficam
    // lado a lado (colunas), e deitada uma sobre a outra (linhas).
    final Widget corpo = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: vertical ? maxLength : double.infinity,
        maxWidth: vertical ? double.infinity : maxLength,
      ),
      child: vertical
          ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lanes,
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lanes,
            ),
    );

    final pill = Container(
      decoration: glassPill(),
      padding: const EdgeInsets.all(6),
      // Cresce e encolhe junto com a segunda pista, em vez de aparecer de uma
      // vez: sem isso, escolher um perfil dá um solavanco na tela.
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: vertical
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [_grip(), Flexible(child: corpo)],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [_grip(), Flexible(child: corpo)],
              ),
      ),
    );

    return Align(
      // Borda oposta à da dock: esquerda com o celular deitado, topo em pé.
      alignment: vertical ? Alignment(-1, _pos) : Alignment(_pos, -1),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ScaleTransition(
          scale: _curved,
          child: FadeTransition(opacity: _anim, child: pill),
        ),
      ),
    );
  }

  /// Alça de arrastar, igual à da dock: só ela move a barra, para não brigar
  /// com a rolagem das pistas.
  Widget _grip() {
    return GestureDetector(
      onPanUpdate: (d) {
        final half =
            (widget.vertical ? widget.area.height : widget.area.width) / 2;
        if (half <= 0) return;
        final delta = (widget.vertical ? d.delta.dy : d.delta.dx) / half;
        setState(() => _pos = (_pos + delta).clamp(-1.0, 1.0));
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          widget.vertical ? Icons.drag_handle : Icons.drag_indicator,
          size: 18,
          color: Colors.white38,
        ),
      ),
    );
  }

  /// Uma pista da barra. O tamanho no eixo transversal é fixo — sem isso a
  /// lista esticaria os botões para ocupar o espaço que sobrasse.
  Widget _lane({
    required double thickness,
    required bool vertical,
    required List<Widget> children,
  }) {
    return SizedBox(
      width: vertical ? thickness : null,
      height: vertical ? null : thickness,
      child: ListView(
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: children,
      ),
    );
  }

  /// Traço curto entre as duas pistas. O comprimento é fixo de propósito: um
  /// traço que se estica pelo eixo transversal obrigaria a barra inteira a ter
  /// sempre a altura máxima, mesmo com dois botões dentro.
  Widget _divider({required bool vertical}) {
    return Container(
      width: vertical ? 1 : 28,
      height: vertical ? 28 : 1,
      margin: const EdgeInsets.all(5),
      color: Colors.white24,
    );
  }

  Widget _profileButton(ControlProfile profile) {
    final aceso = profile.id == widget.selected?.id;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Tooltip(
        message: profile.name(widget.strings),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            HapticFeedback.selectionClick();
            // Tocar no perfil aceso fecha a pista de atalhos: é o mesmo botão
            // que abre e que fecha, sem um "X" a mais na barra.
            widget.onSelect(aceso ? null : profile);
          },
          child: Center(
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: aceso ? auroraGradient : null,
                color: aceso ? null : Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                profile.icon,
                size: 21,
                color: aceso ? Colors.white : Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton(ProfileAction action) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Tooltip(
        message: action.label(widget.strings),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onAction(action),
          child: Center(
            child: SizedBox(
              width: _actionTile - 6,
              height: 44,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(action.icon, size: 20, color: Colors.white),
                  const SizedBox(height: 2),
                  // O nome do atalho encolhe se for longo em vez de estourar a
                  // largura do botão ("Ctrl+Shift+Esc" é o pior caso).
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      action.shortcut,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 9,
                        height: 1,
                        color: Colors.white60,
                      ),
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
