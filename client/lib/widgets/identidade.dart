import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// As peças que fazem o Deskside parecer o Deskside: o monitor que acende, o
/// cursor da marca, o botão com relevo, os ícones no traço do logo e o jeito
/// de vibrar. Ficam juntas para cada tela usar a mesma, e não uma parecida.

// --- vibração --------------------------------------------------------------

/// O "toque" do app. Cada momento tem o seu, e é sempre o mesmo: a mão
/// aprende antes do olho.
class Vibracao {
  Vibracao._();

  /// Conectou: dois toques curtos.
  static Future<void> conectou() async {
    await HapticFeedback.lightImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.lightImpact();
  }

  /// Desconectou ou caiu: um toque longo.
  static Future<void> desconectou() => HapticFeedback.heavyImpact();

  /// Uma tecla do teclado remoto, ou um botão com relevo.
  static Future<void> tecla() => HapticFeedback.selectionClick();
}

// --- o cursor da marca -------------------------------------------------------

/// A seta do logo, em degradê. Vai no logo, nas telas acesas e no lugar do
/// ponteiro no modo trackpad.
class CursorDaMarca extends StatelessWidget {
  const CursorDaMarca({super.key, this.tamanho = 28, this.brilho = true});

  final double tamanho;
  final bool brilho;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: tamanho,
      height: tamanho,
      child: CustomPaint(painter: _PintorDoCursor(brilho: brilho)),
    );
  }
}

class _PintorDoCursor extends CustomPainter {
  _PintorDoCursor({required this.brilho});

  final bool brilho;

  /// A seta numa caixa de 24 x 24, a mesma do logo.
  static Path seta(Size s) {
    final k = s.width / 24;
    return Path()
      ..moveTo(5 * k, 3 * k)
      ..lineTo(5 * k, 19 * k)
      ..lineTo(9.5 * k, 14.8 * k)
      ..lineTo(12.6 * k, 21 * k)
      ..lineTo(15.2 * k, 19.8 * k)
      ..lineTo(12.2 * k, 13.6 * k)
      ..lineTo(18 * k, 13.4 * k)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final caminho = seta(size);
    if (brilho) {
      canvas.drawPath(
        caminho.shift(Offset(0, size.height * 0.05)),
        Paint()
          ..color = auroraCyan.withAlpha(140)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.18),
      );
    }
    canvas.drawPath(
      caminho,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFC4B5FD), auroraCyan],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      caminho,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width / 24
        ..color = const Color(0xFF05060D).withAlpha(160),
    );
  }

  @override
  bool shouldRepaint(_PintorDoCursor old) => old.brilho != brilho;
}

// --- o monitor ---------------------------------------------------------------

/// Um computador desenhado como monitor: **tela acesa** quando ele está
/// online, **apagada** quando não. É a peça que mais carrega a marca — o
/// estado do computador se lê de relance, sem precisar ler "Online".
///
/// [conteudo] vai dentro da tela acesa (o programa em primeiro plano, o
/// cursor). [heroTag] liga este monitor à tela remota: ao conectar, ele
/// cresce até virar a tela.
class MonitorDeskside extends StatelessWidget {
  const MonitorDeskside({
    super.key,
    required this.ligado,
    required this.largura,
    this.proporcao = 16 / 9,
    this.conteudo,
    this.comPe = true,
    this.heroTag,
    this.intensidade = 1,
  });

  final bool ligado;
  final double largura;
  final double proporcao;
  final Widget? conteudo;
  final bool comPe;
  final Object? heroTag;

  /// 0 a 1: quanto a tela brilha. O "ligando" da conexão anima isto.
  final double intensidade;

  @override
  Widget build(BuildContext context) {
    final c = context.cores;
    final altura = largura / proporcao;
    final raio = math.max(6.0, largura * 0.05);
    final borda = math.max(1.5, largura * 0.006);

    Widget tela;
    if (ligado) {
      tela = Container(
        width: largura,
        height: altura,
        padding: EdgeInsets.all(borda),
        decoration: BoxDecoration(
          gradient: auroraGradient,
          borderRadius: BorderRadius.circular(raio + borda),
          boxShadow: [
            BoxShadow(
              color: auroraBlue.withAlpha((70 * intensidade).round()),
              blurRadius: largura * 0.14,
              offset: Offset(0, largura * 0.015),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(raio),
          // Duas camadas: o vidro escuro e, por cima, a luz. Numa caixa só, o
          // Flutter ignora a cor quando há degradê, e a borda colorida de fora
          // aparecia pela parte transparente da luz.
          child: ColoredBox(
            color: const Color(0xFF0F1330),
            child: DecoratedBox(
              decoration: BoxDecoration(
                // A luz da tela: um brilho que nasce no canto de cima e se
                // apaga no escuro do vidro — e não a tela inteira pintada.
                gradient: RadialGradient(
                  center: const Alignment(-0.55, -0.75),
                  radius: 1.05,
                  colors: [
                    auroraViolet.withAlpha((105 * intensidade).round()),
                    auroraBlue.withAlpha((50 * intensidade).round()),
                    auroraCyan.withAlpha((16 * intensidade).round()),
                    const Color(0x000F1330),
                  ],
                  stops: const [0, 0.42, 0.72, 1],
                ),
              ),
              child: SizedBox.expand(child: conteudo),
            ),
          ),
        ),
      );
    } else {
      tela = Container(
        width: largura,
        height: altura,
        decoration: BoxDecoration(
          color: c.monitorApagado,
          borderRadius: BorderRadius.circular(raio + borda),
          border: Border.all(color: c.bordaApagada, width: borda),
        ),
      );
    }

    if (heroTag != null) {
      tela = Hero(tag: heroTag!, child: tela);
    }
    if (!comPe) return tela;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tela,
        Container(width: largura * 0.14, height: largura * 0.035, color: c.pe),
        Container(
          width: largura * 0.36,
          height: math.max(4.0, largura * 0.024),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.pe,
            borderRadius: BorderRadius.circular(6),
          ),
          // O LED da base: verde e aceso com o computador online.
          child: Container(
            width: math.max(3.0, largura * 0.018),
            height: math.max(3.0, largura * 0.018),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ligado ? c.led : c.bordaApagada,
              boxShadow: ligado
                  ? [BoxShadow(color: c.led, blurRadius: largura * 0.03)]
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// O logo: o monitor aceso com o cursor dentro.
class LogoDeskside extends StatelessWidget {
  const LogoDeskside({super.key, this.largura = 104});

  final double largura;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Deskside',
      image: true,
      child: MonitorDeskside(
        ligado: true,
        largura: largura,
        proporcao: 1.5,
        conteudo: Center(child: CursorDaMarca(tamanho: largura * 0.34)),
      ),
    );
  }
}

// --- o botão com relevo --------------------------------------------------------

/// O botão principal: o degradê de ação com uma "borda de baixo", que afunda
/// quando o dedo encosta e vibra de leve. É o mesmo material das teclas do
/// teclado remoto — o celular como um objeto que se aperta.
class BotaoDeskside extends StatefulWidget {
  const BotaoDeskside({
    super.key,
    required this.rotulo,
    required this.onPressed,
    this.icone,
    this.iconeDepois = false,
    this.largo = false,
    this.carregando = false,
    this.altura = 56,
    this.redondo = false,
  });

  final String rotulo;
  final VoidCallback? onPressed;
  final IconData? icone;

  /// O ícone depois do texto (uma seta de "Continuar"), e não antes.
  final bool iconeDepois;
  final bool largo;
  final bool carregando;
  final double altura;

  /// Pílula (o "Parear" que flutua) em vez de cantos de 16.
  final bool redondo;

  @override
  State<BotaoDeskside> createState() => _BotaoDesksideState();
}

class _BotaoDesksideState extends State<BotaoDeskside> {
  bool _apertado = false;

  bool get _ativo => widget.onPressed != null && !widget.carregando;

  void _apertar(bool sim) {
    if (!_ativo || _apertado == sim) return;
    setState(() => _apertado = sim);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.cores;
    final raio = BorderRadius.circular(widget.redondo ? widget.altura / 2 : 16);
    const relevo = 5.0;
    final texto = Text(
      widget.rotulo,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: _ativo ? Colors.white : c.texto3,
        fontWeight: FontWeight.w600,
        fontSize: 16,
      ),
    );
    final icone = widget.icone == null
        ? null
        : Icon(widget.icone, size: 20, color: _ativo ? Colors.white : c.texto3);
    final filhos = <Widget>[
      if (widget.carregando)
        const SizedBox(
          width: 20,
          height: 20,
          child:
              CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
        )
      else ...[
        if (icone != null && !widget.iconeDepois) ...[
          icone,
          const SizedBox(width: 10)
        ],
        Flexible(child: texto),
        if (icone != null && widget.iconeDepois) ...[
          const SizedBox(width: 8),
          icone
        ],
      ],
    ];

    final descida = _apertado ? relevo - 1 : 0.0;
    return Semantics(
      button: true,
      enabled: _ativo,
      label: widget.rotulo,
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) => _apertar(true),
        onTapCancel: () => _apertar(false),
        onTapUp: (_) => _apertar(false),
        onTap: _ativo
            ? () {
                Vibracao.tecla();
                widget.onPressed!();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 70),
          height: widget.altura,
          width: widget.largo ? double.infinity : null,
          margin: EdgeInsets.only(top: descida, bottom: relevo - descida),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            gradient: _ativo ? degradeDeAcao : null,
            color: _ativo ? null : c.superficieAlta,
            borderRadius: raio,
            border: _ativo ? null : Border.all(color: c.linha),
            boxShadow: _ativo
                ? [
                    BoxShadow(
                      color: sombraDoBotao,
                      offset: Offset(0, relevo - descida),
                    ),
                    if (!_apertado)
                      BoxShadow(
                        color: auroraViolet.withAlpha(45),
                        blurRadius: 26,
                        offset: const Offset(0, 10),
                      ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: widget.largo ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: filhos,
          ),
        ),
      ),
    );
  }
}

// --- ícones próprios -----------------------------------------------------------

/// As ações principais no traço do logo: 1,8 de espessura, cantos redondos, e
/// o degradê da marca quando [cor] não é dada. O resto do app usa os ícones
/// do Material — estes seis são os que a pessoa toca o tempo todo.
enum IconeDeskside { teclado, mouse, arquivos, programas, energia, perfis }

class IconeDaMarca extends StatelessWidget {
  const IconeDaMarca(this.icone, {super.key, this.tamanho = 24, this.cor});

  final IconeDeskside icone;
  final double tamanho;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final cor = this.cor ?? IconTheme.of(context).color;
    return SizedBox(
      width: tamanho,
      height: tamanho,
      child: CustomPaint(painter: _PintorDoIcone(icone, cor)),
    );
  }
}

class _PintorDoIcone extends CustomPainter {
  _PintorDoIcone(this.icone, this.cor);

  final IconeDeskside icone;
  final Color? cor;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (cor != null) {
      p.color = cor!;
    } else {
      p.shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFA78BFA), Color(0xFF6D8BFF), auroraCyan],
      ).createShader(Offset.zero & size);
    }
    RRect rr(double x, double y, double w, double h, double r) =>
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x * k, y * k, w * k, h * k), Radius.circular(r * k));
    void linha(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1 * k, y1 * k), Offset(x2 * k, y2 * k), p);

    switch (icone) {
      case IconeDeskside.teclado:
        canvas.drawRRect(rr(2.5, 6, 19, 12, 2.5), p);
        for (final x in [6.0, 9.5, 13.0, 16.5]) {
          linha(x, 10, x + 0.01, 10);
        }
        linha(7.5, 14, 16.5, 14);
      case IconeDeskside.mouse:
        canvas.drawRRect(rr(6.5, 3, 11, 18, 5.5), p);
        linha(12, 7, 12, 10);
      case IconeDeskside.arquivos:
        canvas.drawPath(
          Path()
            ..moveTo(3 * k, 7.5 * k)
            ..quadraticBezierTo(3 * k, 5.5 * k, 5 * k, 5.5 * k)
            ..lineTo(9 * k, 5.5 * k)
            ..lineTo(11 * k, 7.5 * k)
            ..lineTo(19 * k, 7.5 * k)
            ..quadraticBezierTo(21 * k, 7.5 * k, 21 * k, 9.5 * k)
            ..lineTo(21 * k, 17 * k)
            ..quadraticBezierTo(21 * k, 19 * k, 19 * k, 19 * k)
            ..lineTo(5 * k, 19 * k)
            ..quadraticBezierTo(3 * k, 19 * k, 3 * k, 17 * k)
            ..close(),
          p,
        );
      case IconeDeskside.programas:
        for (final (x, y) in [
          (3.5, 3.5),
          (13.5, 3.5),
          (3.5, 13.5),
          (13.5, 13.5)
        ]) {
          canvas.drawRRect(rr(x, y, 7, 7, 2), p);
        }
      case IconeDeskside.energia:
        linha(12, 3, 12, 11);
        canvas.drawArc(
          Rect.fromCircle(center: Offset(12 * k, 13 * k), radius: 8 * k),
          -math.pi / 2 + 0.75,
          2 * math.pi - 1.5,
          false,
          p,
        );
      case IconeDeskside.perfis:
        canvas.drawPath(
          Path()
            ..moveTo(12 * k, 3 * k)
            ..lineTo(21 * k, 8 * k)
            ..lineTo(12 * k, 13 * k)
            ..lineTo(3 * k, 8 * k)
            ..close(),
          p,
        );
        canvas.drawPath(
          Path()
            ..moveTo(3 * k, 13 * k)
            ..lineTo(12 * k, 18 * k)
            ..lineTo(21 * k, 13 * k),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(_PintorDoIcone old) =>
      old.icone != icone || old.cor != cor;
}

// --- a página de fundo -----------------------------------------------------------

/// O brilho suave da marca no topo da tela (login, cadastro, pareamento).
class BrilhoDoTopo extends StatelessWidget {
  const BrilhoDoTopo({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.cores;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1.15),
          radius: 1.1,
          colors: [c.brilhoDoTopo, c.fundo.withAlpha(0)],
        ),
      ),
      child: child,
    );
  }
}
