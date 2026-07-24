import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/stream_quality.dart';
import 'api_client.dart';

/// Estado global do app: autenticação, dispositivos e preferências.
class AppState extends ChangeNotifier {
  AppState(this.api);

  final ApiClient api;

  List<Device> devices = [];
  Device? selected;
  ThemeMode themeMode = ThemeMode.system;
  bool appLockEnabled = false;
  bool twoFactorEnabled = false;
  bool gestureTutorialSeen = false;
  StreamQuality streamQuality = StreamQuality.equilibrado;

  bool get isAuthenticated => api.isAuthenticated;

  /// Carrega as preferências salvas (tema, bloqueio) na inicialização.
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode = switch (prefs.getString('themeMode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    appLockEnabled = prefs.getBool('appLock') ?? false;
    gestureTutorialSeen = prefs.getBool('gestureTutorialSeen') ?? false;
    streamQuality = StreamQuality.fromName(prefs.getString('streamQuality'));
    // Reaponta ao mesmo servidor usado no login anterior. Precisa vir antes
    // de restoreSession(), senão o refresh do token vai para localhost e falha.
    final savedUrl = prefs.getString('serverUrl');
    if (savedUrl != null && savedUrl.isNotEmpty) {
      api.baseUrl = _normalizeServerUrl(savedUrl);
    }
    notifyListeners();
  }

  Future<void> setStreamQuality(StreamQuality quality) async {
    streamQuality = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('streamQuality', quality.name);
  }

  Future<void> markGestureTutorialSeen() async {
    gestureTutorialSeen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gestureTutorialSeen', true);
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    appLockEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('appLock', enabled);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', mode.name);
  }

  /// Tenta retomar a sessão salva (login persistente). Ignora falhas de rede.
  Future<void> restoreSession() async {
    bool restored;
    try {
      restored = await api.restore();
    } catch (_) {
      restored = false;
    }
    if (restored) {
      try {
        await refreshDevices();
        twoFactorEnabled = await api.fetchTwoFactorEnabled();
      } catch (_) {
        // Sem rede agora: segue autenticado; a lista atualiza depois.
      }
    }
    notifyListeners();
  }

  String get serverUrl => api.baseUrl;
  set serverUrl(String value) {
    final normalized = _normalizeServerUrl(value);
    api.baseUrl = normalized;
    notifyListeners();
    // Persiste para reabrir o app já apontando ao mesmo servidor.
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString('serverUrl', normalized));
  }

  /// Normaliza a URL do servidor: remove espaços e barras finais e, se o
  /// usuário esquecer o esquema, assume https (evita o redirecionamento 308
  /// http→https que quebra o login).
  static String _normalizeServerUrl(String value) {
    var v = value.trim();
    if (v.isNotEmpty && !v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    return v.replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> login(String email, String password, {String? totpCode}) async {
    await api.login(email, password, totpCode: totpCode);
    await refreshDevices();
    try {
      twoFactorEnabled = await api.fetchTwoFactorEnabled();
    } catch (_) {
      // Status do 2FA é secundário; não deve derrubar o login.
    }
    notifyListeners();
  }

  // --- verificação em duas etapas (2FA) --------------------------------------

  Future<Map<String, String>> setupTwoFactor() => api.setupTwoFactor();

  Future<void> enableTwoFactor(String code) async {
    await api.enableTwoFactor(code);
    twoFactorEnabled = true;
    notifyListeners();
  }

  Future<void> disableTwoFactor(String password) async {
    await api.disableTwoFactor(password);
    twoFactorEnabled = false;
    notifyListeners();
  }

  Future<void> register(String email, String password) async {
    await api.register(email, password);
    await refreshDevices();
    notifyListeners();
  }

  Future<void> refreshDevices() async {
    devices = await api.listDevices();
    notifyListeners();
  }

  Future<Device> pair(String code) async {
    final device = await api.claim(code);
    await refreshDevices();
    return device;
  }

  void selectDevice(Device device) {
    selected = device;
    notifyListeners();
  }

  Future<void> renameDevice(Device device, String name) async {
    await api.renameDevice(device.deviceId, name);
    await refreshDevices();
  }

  Future<void> removeDevice(Device device) async {
    await api.removeDevice(device.deviceId);
    if (selected?.deviceId == device.deviceId) selected = null;
    await refreshDevices();
  }

  Future<void> powerDevice(Device device, String action) async {
    await api.powerDevice(device.deviceId, action);
  }

  Future<void> wakeDevice(Device device) async {
    await api.wakeDevice(device.deviceId);
  }

  // --- conta -----------------------------------------------------------------

  Future<void> updateEmail(String currentPassword, String newEmail) =>
      api.updateEmail(currentPassword, newEmail);

  Future<void> updatePassword(String currentPassword, String newPassword) =>
      api.updatePassword(currentPassword, newPassword);

  Future<void> deleteAccount(String password) async {
    await api.deleteAccount(password);
    devices = [];
    selected = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await api.logout();
    devices = [];
    selected = null;
    notifyListeners();
  }
}
