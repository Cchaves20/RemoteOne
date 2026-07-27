import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import '../models/device.dart';
import '../models/remote_app.dart';
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

  /// Se o app tenta receber a tela por WebRTC (vídeo H.264) antes de cair no
  /// JPEG. Ligado por padrão — é o caminho bom —, mas desligável: se o WebRTC
  /// se comportar mal, dá para voltar ao que funciona sem reinstalar o app.
  bool webrtcVideoEnabled = true;
  AppLanguage language = AppLanguage.system;

  bool get isAuthenticated => api.isAuthenticated;

  /// Textos no idioma atual (resolve "sistema" para um dos cinco suportados).
  Strings get t => Strings(_resolvedLanguage);

  AppLanguage get _resolvedLanguage {
    if (language != AppLanguage.system) return language;
    return switch (ui.PlatformDispatcher.instance.locale.languageCode) {
      'pt' => AppLanguage.ptBr,
      'zh' => AppLanguage.zh,
      'fr' => AppLanguage.fr,
      'es' => AppLanguage.es,
      _ => AppLanguage.en,
    };
  }

  Future<void> setLanguage(AppLanguage lang) async {
    language = lang;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', lang.name);
  }

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
    webrtcVideoEnabled = prefs.getBool('webrtcVideo') ?? true;
    language = AppLanguage.values.firstWhere(
      (l) => l.name == prefs.getString('language'),
      orElse: () => AppLanguage.system,
    );
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

  Future<void> setWebrtcVideoEnabled(bool enabled) async {
    webrtcVideoEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('webrtcVideo', enabled);
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

  // --- aplicativos do computador ---------------------------------------------

  Future<List<RemoteApp>> listApps(Device device, {String kind = 'installed'}) =>
      api.listApps(device.deviceId, kind: kind);

  Future<void> launchApp(Device device, String id) =>
      api.launchApp(device.deviceId, id);

  Future<void> closeApp(Device device, String id) =>
      api.closeApp(device.deviceId, id);

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
