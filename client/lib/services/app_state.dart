import 'package:flutter/foundation.dart';

import '../models/device.dart';
import 'api_client.dart';

/// Estado global do app: autenticação e dispositivos.
class AppState extends ChangeNotifier {
  AppState(this.api);

  final ApiClient api;

  List<Device> devices = [];
  Device? selected;

  bool get isAuthenticated => api.isAuthenticated;

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
