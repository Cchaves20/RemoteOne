import 'package:deskside_client/widgets/pulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('o esqueleto desenha os itens e o leitor de tela ouve um aviso só',
      (tester) async {
    final semantica = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EsqueletoDeLista(rotulo: 'Carregando…', itens: 3)),
    ));
    // Um quadro, e não `pumpAndSettle`: o pulsar não para nunca.
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SkeletonBox), findsNWidgets(3 * 3));
    expect(find.bySemanticsLabel('Carregando…'), findsOneWidget);
    semantica.dispose();
  });

  testWidgets('com uma linha só, sem a linha de baixo', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EsqueletoDeLista(rotulo: 'x', itens: 2, duasLinhas: false),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SkeletonBox), findsNWidgets(2 * 2));
  });
}
