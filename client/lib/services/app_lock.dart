import 'package:local_auth/local_auth.dart';

/// Autenticação biométrica (Face ID / Touch ID) para desbloquear o app.
///
/// Só libera sem verificar quando o aparelho não tem como verificar: sem
/// biometria, sem nada cadastrado, sem senha. Assim um aparelho sem Face ID
/// nunca deixa o dono trancado do lado de fora.
///
/// Rosto não reconhecido, "Cancelar", tempo esgotado ou qualquer outro erro
/// mantêm o app trancado; o botão "Desbloquear" tenta de novo. No local_auth 3
/// esses casos chegam como [LocalAuthException], não mais como `false`.
class AppLock {
  AppLock({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  Future<bool> authenticate() async {
    try {
      final supported =
          await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
      if (!supported) return true; // sem biometria → não bloqueia
      return await _auth.authenticate(
        localizedReason: 'Desbloqueie o Deskside',
        // O antigo `stickyAuth` do local_auth 2: se o app for para segundo
        // plano no meio (uma ligação, o Face ID pedindo a senha do aparelho),
        // a verificação continua de onde parou em vez de falhar.
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (e) {
      return aparelhoNaoTemComoVerificar(e.code);
    } catch (_) {
      return false;
    }
  }
}

/// Os únicos erros que liberam o app: o aparelho não tem com o que verificar.
bool aparelhoNaoTemComoVerificar(LocalAuthExceptionCode codigo) =>
    switch (codigo) {
      LocalAuthExceptionCode.noBiometricHardware ||
      LocalAuthExceptionCode.noBiometricsEnrolled ||
      LocalAuthExceptionCode.noCredentialsSet =>
        true,
      _ => false,
    };
