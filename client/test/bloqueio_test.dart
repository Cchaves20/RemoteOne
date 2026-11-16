// No local_auth 3, rosto não reconhecido e "Cancelar" chegam como exceção, e
// o bloqueio tratava qualquer exceção como "liberado". Visto num iPhone.
import 'package:deskside_client/services/app_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

class _Biometria implements LocalAuthentication {
  _Biometria({this.temBiometria = true, this.resposta = true, this.erro});

  final bool temBiometria;
  final bool resposta;
  final Object? erro;

  @override
  Future<bool> isDeviceSupported() async => temBiometria;

  @override
  Future<bool> get canCheckBiometrics async => temBiometria;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object?> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    if (erro != null) throw erro!;
    return resposta;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<bool> _tenta(_Biometria biometria) =>
    AppLock(auth: biometria).authenticate();

LocalAuthException _falha(LocalAuthExceptionCode codigo) =>
    LocalAuthException(code: codigo);

void main() {
  test('rosto reconhecido libera', () async {
    expect(await _tenta(_Biometria()), isTrue);
  });

  test('"Cancelar" mantém trancado', () async {
    expect(
        await _tenta(
            _Biometria(erro: _falha(LocalAuthExceptionCode.userCanceled))),
        isFalse);
  });

  test('rosto não reconhecido mantém trancado', () async {
    expect(await _tenta(_Biometria(resposta: false)), isFalse);
    for (final codigo in [
      LocalAuthExceptionCode.biometricLockout,
      LocalAuthExceptionCode.temporaryLockout,
      LocalAuthExceptionCode.timeout,
      LocalAuthExceptionCode.systemCanceled,
      LocalAuthExceptionCode.unknownError,
    ]) {
      expect(await _tenta(_Biometria(erro: _falha(codigo))), isFalse,
          reason: codigo.name);
    }
  });

  test('erro que não é do local_auth mantém trancado', () async {
    expect(await _tenta(_Biometria(erro: StateError('x'))), isFalse);
  });

  test('aparelho sem como verificar libera', () async {
    expect(await _tenta(_Biometria(temBiometria: false)), isTrue);
    for (final codigo in [
      LocalAuthExceptionCode.noBiometricHardware,
      LocalAuthExceptionCode.noBiometricsEnrolled,
      LocalAuthExceptionCode.noCredentialsSet,
    ]) {
      expect(await _tenta(_Biometria(erro: _falha(codigo))), isTrue,
          reason: codigo.name);
    }
  });
}
