import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';

/// Erro de API com o código HTTP e uma mensagem amigável.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Cliente REST do backend do RemoteOne.
///
/// Mantém os tokens em memória (nesta sessão). A persistência entre execuções
/// entra depois, via armazenamento seguro.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// URL base do backend (ex.: http://192.168.0.10:8000). Editável para
  /// apontar o celular ao computador na mesma rede.
  String baseUrl;
  final http.Client _http;

  String? _accessToken;
  String? _refreshToken;

  bool get isAuthenticated => _accessToken != null;

  Map<String, String> get _jsonHeaders => {'Content-Type': 'application/json'};

  Map<String, String> get _authHeaders => {
        ..._jsonHeaders,
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<void> register(String email, String password) async {
    final res = await _http.post(
      _uri('/api/v1/auth/register'),
      headers: _jsonHeaders,
      body: jsonEncode({'email': email, 'password': password}),
    );
    _storeTokens(_decode(res, expected: 201));
  }

  Future<void> login(String email, String password) async {
    final res = await _http.post(
      _uri('/api/v1/auth/login'),
      headers: _jsonHeaders,
      body: jsonEncode({'email': email, 'password': password}),
    );
    _storeTokens(_decode(res));
  }

  void logout() {
    _accessToken = null;
    _refreshToken = null;
  }

  Future<List<Device>> listDevices() async {
    final res = await _http.get(_uri('/api/v1/devices'), headers: _authHeaders);
    final data = _decode(res) as List<dynamic>;
    return data
        .map((e) => Device.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Device> claim(String code) async {
    final res = await _http.post(
      _uri('/api/v1/pairing/claim'),
      headers: _authHeaders,
      body: jsonEncode({'code': code}),
    );
    return Device.fromJson(_decode(res, expected: 201) as Map<String, dynamic>);
  }

  /// Envia uma ação de entrada (mouse/teclado) ao computador pareado.
  Future<void> sendInput(String deviceId, Map<String, dynamic> action) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/input'),
      headers: _authHeaders,
      body: jsonEncode(action),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Pede ao computador para começar a transmitir a tela.
  Future<void> startScreen(String deviceId) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/screen/start'),
      headers: _authHeaders,
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Pede para parar a transmissão da tela (best-effort).
  Future<void> stopScreen(String deviceId) async {
    await _http.post(
      _uri('/api/v1/devices/$deviceId/screen/stop'),
      headers: _authHeaders,
    );
  }

  /// Busca o último frame da tela. Retorna null enquanto ainda não há frame
  /// (HTTP 503), o que é normal logo após iniciar a transmissão.
  Future<Uint8List?> fetchFrame(String deviceId) async {
    final res = await _http.get(
      _uri('/api/v1/devices/$deviceId/screen'),
      headers: _authHeaders,
    );
    if (res.statusCode == 200) {
      return res.bodyBytes;
    }
    if (res.statusCode == 503) {
      return null;
    }
    throw _error(res);
  }

  /// Abre o canal de tela em tempo real. O backend passa a empurrar os frames
  /// JPEG (binários) assim que o autenticamos com o token. O chamador escuta
  /// `channel.stream` (eventos `List<int>`) e fecha `channel.sink` ao sair.
  WebSocketChannel connectScreen(String deviceId) {
    final wsBase = baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final channel = WebSocketChannel.connect(
      Uri.parse('$wsBase/ws/viewer/$deviceId'),
    );
    channel.sink.add(jsonEncode({'token': _accessToken}));
    return channel;
  }

  // --- helpers ---------------------------------------------------------------

  void _storeTokens(dynamic body) {
    final map = body as Map<String, dynamic>;
    _accessToken = map['access_token'] as String?;
    _refreshToken = map['refresh_token'] as String? ?? _refreshToken;
  }

  dynamic _decode(http.Response res, {int expected = 200}) {
    if (res.statusCode != expected) {
      throw _error(res);
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body);
  }

  ApiException _error(http.Response res) {
    String message;
    try {
      final decoded = jsonDecode(res.body);
      message = (decoded is Map && decoded['detail'] != null)
          ? decoded['detail'].toString()
          : 'Erro ${res.statusCode}';
    } catch (_) {
      message = 'Erro ${res.statusCode}';
    }
    return ApiException(res.statusCode, message);
  }
}
