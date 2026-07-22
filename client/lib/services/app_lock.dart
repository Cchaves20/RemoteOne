import 'package:local_auth/local_auth.dart';

/// Autenticação biométrica (Face ID / Touch ID) para desbloquear o app.
///
/// Design **fail-open**: se a biometria não estiver disponível, não houver
/// nada cadastrado, ou ocorrer um erro, consideramos desbloqueado — assim um
/// problema no dispositivo nunca deixa o usuário trancado do lado de fora.
class AppLock {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> authenticate() async {
    try {
      final supported =
          await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
      if (!supported) return true; // sem biometria → não bloqueia
      return await _auth.authenticate(
        localizedReason: 'Desbloqueie o RemoteOne',
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } catch (_) {
      return true; // qualquer erro → não tranca o usuário
    }
  }
}
