import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/devices_screen.dart';
import 'screens/lock_gate.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/app_state.dart';
import 'theme.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(ApiClient(baseUrl: backendPadrao));
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
