import 'package:flutter/material.dart';

import 'screens/devices_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/app_state.dart';

/// URL padrão do backend. Pode ser sobrescrita no build com
/// --dart-define=REMOTEONE_BACKEND=http://SEU_IP:8000 ou editada na tela de
/// login (útil para apontar o celular ao computador na mesma rede).
const _defaultBackend = String.fromEnvironment(
  'REMOTEONE_BACKEND',
  defaultValue: 'http://localhost:8000',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(ApiClient(baseUrl: _defaultBackend));
  await state.loadPreferences();
  await state.restoreSession();
  runApp(RemoteOneApp(state: state));
}

class RemoteOneApp extends StatelessWidget {
  const RemoteOneApp({super.key, required this.state});

  final AppState state;

  ThemeData _theme(Brightness brightness) => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: brightness,
        ),
        useMaterial3: true,
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'RemoteOne',
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: state.themeMode,
          home: state.isAuthenticated
              ? DevicesScreen(state: state)
              : LoginScreen(state: state),
        );
      },
    );
  }
}
