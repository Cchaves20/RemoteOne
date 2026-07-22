import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Armazenamento dos tokens de autenticação. Abstraído para permitir uma
/// versão em memória nos testes (sem tocar no armazenamento nativo).
abstract class TokenStore {
  Future<void> save(String? access, String? refresh);
  Future<(String?, String?)> load();
  Future<void> clear();
}

/// Guarda os tokens no armazenamento seguro do sistema (Keychain no iOS,
/// KeyStore no Android). Persiste o login entre aberturas do app.
class SecureTokenStore implements TokenStore {
  static const _storage = FlutterSecureStorage();
  static const _kAccess = 'remoteone_access';
  static const _kRefresh = 'remoteone_refresh';

  @override
  Future<void> save(String? access, String? refresh) async {
    await _write(_kAccess, access);
    await _write(_kRefresh, refresh);
  }

  @override
  Future<(String?, String?)> load() async {
    return (
      await _storage.read(key: _kAccess),
      await _storage.read(key: _kRefresh),
    );
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }

  Future<void> _write(String key, String? value) async {
    if (value == null) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }
}

/// Versão em memória (usada nos testes).
class InMemoryTokenStore implements TokenStore {
  String? _access;
  String? _refresh;

  @override
  Future<void> save(String? access, String? refresh) async {
    _access = access;
    _refresh = refresh;
  }

  @override
  Future<(String?, String?)> load() async => (_access, _refresh);

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }
}
