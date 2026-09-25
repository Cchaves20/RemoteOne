import 'package:deskside_client/widgets/barra_do_sistema.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// O app acima da barra de navegação do Android — e só no Android.
///
/// Em 8 das 17 telas o fim da lista ficava por baixo dos botões do sistema,
/// porque uma `ListView` com `padding` explícito perde o recuo automático. O
/// conserto é um lugar só, em volta do app; estes testes guardam os dois
/// lados dele.
void main() {
  /// Um "sistema" com 48 de barra embaixo, e o app ocupando tudo.
  Widget montar() => MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 48)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => respeitarBarraDoSistema(
              context,
              const SizedBox.expand(key: Key('app')),
            ),
          ),
        ),
      );

  testWidgets('no Android, o app termina antes da barra de navegação',
      (tester) async {
    await tester.pumpWidget(montar());

    final tela = tester.getSize(find.byType(ColoredBox)).height;
    final app = tester.getSize(find.byKey(const Key('app'))).height;
    // O que o defeito fazia: o app ia até a borda, e os últimos 48 ficavam
    // embaixo dos botões de voltar, início e recentes.
    expect(app, tela - 48);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('no Android, o topo continua com a barra de título',
      (tester) async {
    // Recuar em cima também tiraria a cor da barra de título de trás da barra
    // de status. Quem cuida do topo é a `AppBar`.
    await tester.pumpWidget(montar());
    final area = tester.widget<SafeArea>(find.byType(SafeArea));
    expect(area.top, isFalse);
    expect(area.bottom, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('no iOS, nada muda', (tester) async {
    // As telas do iOS já foram usadas e aprovadas como estão; a faixa de lá é
    // o indicador de início, fino e translúcido.
    await tester.pumpWidget(montar());
    expect(find.byType(SafeArea), findsNothing);
    final tela = tester.getSize(find.byKey(const Key('app'))).height;
    expect(tela, greaterThan(0));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
