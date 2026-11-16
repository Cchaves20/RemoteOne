// Ao abrir o app, a tela de login aparecia por um segundo antes da lista: o
// login guardado só era lido junto com a renovação da sessão pela internet.
// Agora é lido antes da primeira tela, e a renovação vem depois.
import 'dart:convert';

import 'package:deskside_client/main.dart';
import 'package:deskside_client/screens/devices_screen.dart';
import 'package:deskside_client/screens/login_screen.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Um servidor em que o access token guardado ('velho') já venceu, e o
/// refresh guardado ('r1') troca por 'novo'/'r2'.
class _Servidor {
  int renovacoes = 0;
  bool recusarRefresh = false;

  late final cliente = MockClient((req) async {
    final caminho = req.url.path;
    if (caminho == '/api/v1/auth/refresh') {
      renovacoes++;
      if (recusarRefresh) {
        return http.Response(jsonEncode({'detail': 'invalid'}), 401);
      }
      return http.Response(
          jsonEncode({'access_token': 'novo', 'refresh_token': 'r2'}), 200);
    }
    if (req.headers['Authorization'] != 'Bearer novo') {
      return http.Response(jsonEncode({'detail': 'expired'}), 401,
          headers: {'www-authenticate': 'Bearer'});
    }
    return switch (caminho) {
      '/api/v1/auth/me' => http.Response(
          jsonEncode({'id': 1, 'email': 'a@b.com', 'plano': 'pago'}), 200),
      _ => http.Response('[]', 200),
    };
  });
}

Future<AppState> _abrir(_Servidor servidor, {bool logado = true}) async {
  SharedPreferences.setMockInitialValues({});
  final tokens = InMemoryTokenStore();
  if (logado) await tokens.save('velho', 'r1');
  final state = AppState(ApiClient(
      baseUrl: 'http://teste',
      tokenStore: tokens,
      httpClient: servidor.cliente));
  await state.loadPreferences();
  await state.carregarSessaoGuardada();
  return state;
}

void main() {
  testWidgets('com login guardado, a primeira tela é a lista', (tester) async {
    final state = await tester.runAsync(() => _abrir(_Servidor()));
    await tester.pumpWidget(DesksideApp(state: state!));

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(DevicesScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sem login guardado, a primeira tela é o login', (tester) async {
    final state =
        await tester.runAsync(() => _abrir(_Servidor(), logado: false));
    await tester.pumpWidget(DesksideApp(state: state!));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(DevicesScreen), findsNothing);
  });

  test('a renovação da abertura e a recarga da lista renovam uma vez só',
      () async {
    final servidor = _Servidor();
    final state = await _abrir(servidor);

    // Como na abertura: a lista pede os dados enquanto a sessão é renovada.
    await Future.wait([state.restoreSession(), state.recarregar()]);

    expect(servidor.renovacoes, 1);
    expect(state.isAuthenticated, isTrue);
    expect(state.conta, isNotNull);
    state.dispose();
  });

  test('sessão recusada pelo servidor volta ao login', () async {
    final servidor = _Servidor()..recusarRefresh = true;
    final state = await _abrir(servidor);
    expect(state.isAuthenticated, isTrue);

    await state.restoreSession();

    expect(state.isAuthenticated, isFalse);
    state.dispose();
  });
}
