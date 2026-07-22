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
    streamQuality = StreamQuality.fromName(prefs.getString('streamQuality'));
    // Reaponta ao mesmo servidor usado no login anterior. Precisa vir antes
    // de restoreSession(), senão o refresh do token vai para localhost e falha.
    final savedUrl = prefs.getString('serverUrl');
    if (savedUrl != null && savedUrl.isNotEmpty) {
      api.baseUrl = savedUrl;
    }
    notifyListeners();
  }

  Future<void> setStreamQuality(StreamQuality quality) async {
    streamQuality = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('streamQuality', quality.name);
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
      } catch (_) {
        // Sem rede agora: segue autenticado; a lista atualiza depois.
      }
    }
    notifyListeners();
  }

  String get serverUrl => api.baseUrl;
  set serverUrl(String value) {
    api.baseUrl = value;
    notifyListeners();
    // Persiste para reabrir o app já apontando ao mesmo servidor.
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString('serverUrl', value));
  }

  Future<void> login(String email, String password) async {
    await api.login(email, password);
    await refreshDevices();
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
