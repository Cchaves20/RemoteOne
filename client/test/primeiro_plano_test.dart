// O nome do programa no monitor grande do início acompanha o computador:
// some quando o programa fecha, em vez de ficar o da primeira vez.
import 'dart:convert';

import 'package:deskside_client/screens/devices_screen.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:deskside_client/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('o programa fechado sai do monitor na próxima consulta', (tester) async {
    SharedPreferences.setMockInitialValues({});
    String? programa = 'Google Chrome';
    var consultas = 0;
    final tokens = InMemoryTokenStore();
    await tokens.save('a', 'r');
    final state = AppState(ApiClient(
      baseUrl: 'http://teste',
      tokenStore: tokens,
      httpClient: MockClient((req) async {
        final c = req.url.path;
        if (c.contains('refresh')) {
          return http.Response(jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
        }
        if (c == '/api/v1/auth/me') {
          return http.Response(
              jsonEncode({
                'id': 1,
                'email': 'a@b.c',
                'first_name': 'Ana',
                'last_name': 'Lima',
                'plano': 'pago',
                'termos_versao': '2026-11.2',
                'termos_atual': '2026-11.2',
              }),
              200);
        }
        if (c == '/api/v1/devices') {
          return http.Response(
              jsonEncode([
                {'device_id': 'pc', 'name': 'PC', 'os': 'windows', 'hostname': 'PC', 'online': true},
              ]),
              200);
        }
        if (c.endsWith('/foreground')) {
          consultas++;
          return http.Response(
              jsonEncode({
                'app': programa == null ? null : {'exe': 'chrome', 'name': programa},
              }),
              200);
        }
        return http.Response('[]', 200);
      }),
    ));
    await tester.runAsync(state.restoreSession);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: DevicesScreen(state: state),
    ));
    // O mock responde fora do relógio falso do teste: deixa o tempo real
    // andar um pouco entre os quadros.
    Future<void> assentar() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await assentar();
    expect(find.text('Google Chrome'), findsOneWidget);
    final antes = consultas;

    // Fechou o Chrome. Antes dos 30 s, nada de consulta nova.
    programa = null;
    await tester.pump(const Duration(seconds: 10));
    expect(consultas, antes);
    expect(find.text('Google Chrome'), findsOneWidget);

    // Passaram os 30 s: pergunta de novo, e o nome some.
    await tester.pump(const Duration(seconds: 25));
    await assentar();
    expect(consultas, greaterThan(antes));
    expect(find.text('Google Chrome'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
