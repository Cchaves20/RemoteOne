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

void main() {
  final state = AppState(ApiClient(baseUrl: _defaultBackend));
  runApp(RemoteOneApp(state: state));
}

class RemoteOneApp extends StatelessWidget {
  const RemoteOneApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteOne',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return state.isAuthenticated
              ? DevicesScreen(state: state)
              : LoginScreen(state: state);
        },
      ),
    );
  }
}
