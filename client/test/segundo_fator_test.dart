import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/widgets/segundo_fator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Abre um botão que roda [comSegundoFator] com [acao] e guarda o desfecho.
class _Desfecho {
  bool? passou;
  Object? erro;
}

Future<_Desfecho> _abrir(
  WidgetTester tester,
  Future<void> Function(String? codigo) acao,
) async {
  final desfecho = _Desfecho();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            try {
              desfecho.passou = await comSegundoFator(
                  context, const Strings(AppLanguage.ptBr), acao);
            } catch (e) {
              desfecho.erro = e;
            }
          },
          child: const Text('ir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('ir'));
  await tester.pumpAndSettle();
  return desfecho;
}

void main() {
  testWidgets('conta sem verificação: faz a ação sem perguntar nada',
      (tester) async {
    final codigos = <String?>[];
    final desfecho = await _abrir(tester, (c) async => codigos.add(c));

    expect(desfecho.passou, isTrue);
    expect(codigos, [null]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('pede o código quando o servidor pede, e refaz com ele',
      (tester) async {
    final codigos = <String?>[];
    final desfecho = await _abrir(tester, (c) async {
      codigos.add(c);
      if (c == null) throw ApiException(401, 'two_factor_required');
    });

    expect(find.text('Código de verificação'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump(); // o botão só se ativa no quadro seguinte
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    expect(desfecho.passou, isTrue);
    expect(codigos, [null, '123456']);
  });

  testWidgets('código errado pergunta de novo, avisando', (tester) async {
    final codigos = <String?>[];
    final desfecho = await _abrir(tester, (c) async {
      codigos.add(c);
      if (c == null) throw ApiException(401, 'two_factor_required');
      if (c == '000000') throw ApiException(401, 'two_factor_invalid');
    });

    await tester.enterText(find.byType(TextField), '000000');
    await tester.pump(); // o botão só se ativa no quadro seguinte
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();
    expect(find.text('Código inválido. Tente de novo.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '654321');
    await tester.pump(); // o botão só se ativa no quadro seguinte
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    expect(desfecho.passou, isTrue);
    expect(codigos, [null, '000000', '654321']);
  });

  testWidgets('aceita um código de recuperação pelo link', (tester) async {
    final codigos = <String?>[];
    final desfecho = await _abrir(tester, (c) async {
      codigos.add(c);
      if (c == null) throw ApiException(401, 'two_factor_required');
    });

    await tester.tap(find.text('Usar um código de recuperação'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'abcde-fghjk');
    await tester.pump(); // o botão só se ativa no quadro seguinte
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    expect(desfecho.passou, isTrue);
    expect(codigos.last, 'abcde-fghjk');
  });

  testWidgets('cancelar não refaz a ação', (tester) async {
    final codigos = <String?>[];
    final desfecho = await _abrir(tester, (c) async {
      codigos.add(c);
      throw ApiException(401, 'two_factor_required');
    });

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(desfecho.passou, isFalse);
    expect(codigos, [null]);
  });

  testWidgets('outros erros sobem para quem chamou', (tester) async {
    final desfecho = await _abrir(
        tester, (c) async => throw ApiException(401, 'senha incorreta'));

    expect(desfecho.erro, isA<ApiException>());
    expect(find.byType(AlertDialog), findsNothing);
  });
}
