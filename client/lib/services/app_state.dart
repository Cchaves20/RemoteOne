import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import 'api_client.dart';

/// Estado global do app: autenticação, dispositivos e preferências.
class AppState extends ChangeNotifier {
  AppState(this.api);

  final ApiClient api;

  List<Device> devices = [];
  Device? selected;
  ThemeMode themeMode = ThemeMode.system;

  bool get isAuthenticated => api.isAuthenticated;

  /// Carrega as preferências salvas (tema) na inicialização.
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode = switch (prefs.getString('themeMode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', mode.name);
  }

  String get serverUrl => api.baseUrl;
  set serverUrl(String value) {
    api.baseUrl = value;
    notifyListeners();
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

  Future<void> logout() async {
    api.logout();
    devices = [];
    selected = null;
    notifyListeners();
  }
}
