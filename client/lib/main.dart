import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'screens/devices_screen.dart';
import 'screens/lock_gate.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/app_state.dart';
import 'theme.dart';

/// URL do backend passada no build, se houver.
///
/// `--dart-define=REMOTEONE_BACKEND=http://SEU_IP:8000`. Vazio significa "não
/// definiram", e aí vale a regra de [_defaultBackend].
const _buildBackend = String.fromEnvironment('REMOTEONE_BACKEND');

/// O backend a usar quando ninguém escolheu ainda.
///
/// **Na web, a própria origem da página.** O app é servido pelo mesmo domínio
/// que atende a API, e por dois motivos que se reforçam: pedir a outra origem
/// esbarraria no CORS do navegador, e uma página em `https` não pode falar com
/// um servidor em `http` (conteúdo misto). Usar `Uri.base` faz o app abrir
/// funcionando, sem ninguém digitar endereço nenhum.
///
/// Nas outras plataformas, `localhost` continua sendo o palpite de
/// desenvolvimento - e a tela de login deixa trocar.
String get _defaultBackend {
  if (_buildBackend.isNotEmpty) return _buildBackend;
  if (kIsWeb) return Uri.base.origin;
  return 'http://localhost:8000';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(ApiClient(baseUrl: _defaultBackend));
  // Só o carregamento local (rápido) roda antes de desenhar a tela.
  await state.loadPreferences();
  // Mostra a UI imediatamente; a restauração da sessão (rede) roda depois,
  // sem travar a abertura. Assim, um servidor fora do ar nunca causa tela
  // branca — a UI reage via ChangeNotifier quando a sessão resolve.
  runApp(RemoteOneApp(state: state));
  state.restoreSession();
}

class RemoteOneApp extends StatelessWidget {
  const RemoteOneApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'RemoteOne',
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
