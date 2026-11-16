// A lista de tipos de passo da automação tem oito itens, e a folha de baixo
// para em 9/16 da tela: sem rolagem, o último ("Energia") ficava cortado e não
// havia como escolhê-lo. Visto num iPhone.
import 'package:deskside_client/screens/automations_screen.dart';
import 'package:deskside_client/services/api_client.dart';
import 'package:deskside_client/services/app_state.dart';
import 'package:deskside_client/services/token_store.dart';
import 'package:deskside_client/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('"Energia" dá para escolher num celular', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // Um iPhone comum: 390 x 844 pontos.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState(ApiClient(
      baseUrl: 'http://teste',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    ));
    final t = state.t;

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: AutomationEditorScreen(state: state),
    ));
    await tester.pump();

    await tester.tap(find.text(t.automationAddStep));
    await tester.pumpAndSettle();

    final energia = find.text(t.stepKindPower);
    expect(energia, findsOneWidget);
    await tester.ensureVisible(energia);
    await tester.pumpAndSettle();
    expect(energia.hitTestable(), findsOneWidget,
        reason: 'o último tipo de passo precisa ser tocável');
  });
}
