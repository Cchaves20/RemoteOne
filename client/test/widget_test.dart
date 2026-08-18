import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deskside_client/l10n/strings.dart';
import 'package:deskside_client/main.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';

/// Constrói um AppState com um http.Client falso, roteado por [handler]. Fixa o
/// idioma em pt-BR para as asserções de texto serem determinísticas.
AppState _stateWith(Future<http.Response> Function(http.Request) handler) {
  final mock = MockClient((req) => handler(req));
  return AppState(ApiClient(
    baseUrl: 'http://test',
    httpClient: mock,
    tokenStore: InMemoryTokenStore(),
  ))
    ..language = AppLanguage.ptBr;
}

void main() {
  testWidgets('mostra a tela de login quando não autenticado', (tester) async {
    final state = _stateWith((_) async => http.Response('{}', 200));
    await tester.pumpWidget(DesksideApp(state: state));

    expect(find.text('Deskside'), findsOneWidget);
    expect(find.text('Entrar'), findsWidgets);
    expect(find.text('Criar uma conta'), findsOneWidget);
  });

  testWidgets('login bem-sucedido leva à lista de dispositivos', (tester) async {
    final state = _stateWith((req) async {
      if (req.url.path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
          200,
        );
      }
      if (req.url.path == '/api/v1/devices') {
        return http.Response(jsonEncode([]), 200);
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(DesksideApp(state: state));
    await tester.enterText(find.byType(TextField).at(0), 'caio@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'senhaSegura123');
    await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
    await tester.pumpAndSettle();

    expect(find.text('Meus computadores'), findsOneWidget);
    // A tela de primeiro uso, e não só o título dela: o que importa é que ela
    // diga **o que fazer**. O texto anterior ("toque em + e informe o código
    // exibido pelo agente") supunha um programa já instalado no computador e
    // nunca mencionava que havia algo a instalar — era um beco sem saída, e
    // este teste passava do mesmo jeito.
    expect(find.textContaining('Nenhum computador'), findsOneWidget);
    expect(find.textContaining('baixe o Deskside'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Tenho um código'), findsOneWidget);
  });

  testWidgets('erro de login exibe mensagem', (tester) async {
    final state = _stateWith((req) async {
      return http.Response(jsonEncode({'detail': 'e-mail ou senha inválidos'}), 401);
    });

    await tester.pumpWidget(DesksideApp(state: state));
    await tester.enterText(find.byType(TextField).at(0), 'x@y.com');
    await tester.enterText(find.byType(TextField).at(1), 'senhaSegura123');
    await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
    await tester.pumpAndSettle();

    expect(find.text('e-mail ou senha inválidos'), findsOneWidget);
    expect(find.text('Meus computadores'), findsNothing);
  });
}
