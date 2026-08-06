import 'package:flutter/material.dart';

import 'screens/devices_screen.dart';
import 'screens/lock_gate.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/app_state.dart';
import 'theme.dart';

/// URL padrão do backend. Pode ser sobrescrita no build com
/// --dart-define=DESKSIDE_BACKEND=http://SEU_IP:8000 ou editada na tela de
/// login (útil para apontar o celular ao computador na mesma rede).
const _defaultBackend = String.fromEnvironment(
  'DESKSIDE_BACKEND',
  defaultValue: 'http://localhost:8000',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(ApiClient(baseUrl: _defaultBackend));
  // Só o carregamento local (rápido) roda antes de desenhar a tela.
  await state.loadPreferences();
  // Mostra a UI imediatamente; a restauração da sessão (rede) roda depois,
  // sem travar a abertura. Assim, um servidor fora do ar nunca causa tela
  // branca — a UI reage via ChangeNotifier quando a sessão resolve.
  runApp(DesksideApp(state: state));
  state.restoreSession();
}

class DesksideApp extends StatelessWidget {
  const DesksideApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'Deskside',
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: state.themeMode,
          home: LockGate(
            state: state,
            child: state.isAuthenticated
                ? DevicesScreen(state: state)
                : LoginScreen(state: state),
          ),
        );
      },
    );
  }
}
