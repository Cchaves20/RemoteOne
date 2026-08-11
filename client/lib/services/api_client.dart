import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/automation.dart';
import '../models/cadastro.dart';
import '../models/conta.dart';
import '../models/control_profile.dart';
import '../models/device.dart';
import '../models/foreground_app.dart';
import '../models/keep_awake.dart';
import '../models/remote_app.dart';
import '../models/remote_file.dart';
import '../models/system_stats.dart';
import '../models/window_zone.dart';
import 'token_store.dart';

/// Erro de API com o código HTTP e uma mensagem amigável.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Cliente REST do backend do Deskside.
///
/// Os tokens são guardados em disco (armazenamento seguro) para manter o login
/// entre aberturas do app; nos testes, um `TokenStore` em memória é injetado.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? httpClient, TokenStore? tokenStore})
      : _http = httpClient ?? http.Client(),
        _store = tokenStore ?? SecureTokenStore();

  /// URL base do backend (ex.: http://192.168.0.10:8000). Editável para
  /// apontar o celular ao computador na mesma rede.
  String baseUrl;
  final http.Client _http;
  final TokenStore _store;

  String? _accessToken;
  String? _refreshToken;

  /// Tempo máximo de espera por resposta do servidor (evita travas longas
  /// quando o backend está inacessível).
  static const _timeout = Duration(seconds: 15);

  bool get isAuthenticated => _accessToken != null;

  Map<String, String> get _jsonHeaders => {'Content-Type': 'application/json'};

  Map<String, String> get _authHeaders => {
        ..._jsonHeaders,
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Primeira etapa do cadastro: valida o formulário e manda o código.
  ///
  /// **Não cria conta.** Devolve para onde o código foi (normalizado pelo
  /// servidor — telefone em E.164, e-mail em minúsculas), que é o que a tela de
  /// verificação manda de volta. Usar o valor do servidor, e não o que foi
  /// digitado, evita que o app repita a normalização e erre de outro jeito.
  Future<SignupPending> signupStart({
    required String firstName,
    required String lastName,
    required DateTime birthDate,
    String? email,
    String? phone,
    String? country,
    required String password,
    required String passwordConfirm,
  }) async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/signup/start'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'first_name': firstName,
            'last_name': lastName,
            // Só a data, sem hora: `toIso8601String()` traria um horário que o
            // servidor recusaria, e um fuso que faria a data mudar de dia.
            'birth_date':
                birthDate.toIso8601String().split('T').first,
            if (email != null) 'email': email,
            if (phone != null) 'phone': phone,
            if (country != null) 'country': country,
            'password': password,
            'password_confirm': passwordConfirm,
          }),
        )
        .timeout(_timeout);
    return SignupPending.fromJson(
        _decode(res, expected: 201) as Map<String, dynamic>);
  }

  /// Segunda etapa: confere o código e cria a conta, guardando os tokens.
  Future<void> signupVerify(String destination, String code) async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/signup/verify'),
          headers: _jsonHeaders,
          body: jsonEncode({'destination': destination, 'code': code}),
        )
        .timeout(_timeout);
    _storeTokens(_decode(res, expected: 201));
    await _persist();
  }

  Future<SignupPending> signupResend(String destination) async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/signup/resend'),
          headers: _jsonHeaders,
          body: jsonEncode({'destination': destination}),
        )
        .timeout(_timeout);
    return SignupPending.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Pede o código de recuperação de senha.
  ///
  /// **Responde igual exista a conta ou não** — é o servidor que garante isso,
  /// e o app não tem como (nem deve) saber a diferença: descobrir quais
  /// endereços têm conta é justamente o que a resposta uniforme impede.
  Future<SignupPending> forgotPassword({
    String? email,
    String? phone,
    String? country,
  }) async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/password/forgot'),
          headers: _jsonHeaders,
          body: jsonEncode({
            if (email != null) 'email': email,
            if (phone != null) 'phone': phone,
            if (country != null) 'country': country,
          }),
        )
        .timeout(_timeout);
    return SignupPending.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Troca a senha com o código recebido e **já abre a sessão**.
  Future<void> resetPassword(
    String destination,
    String code,
    String password,
    String passwordConfirm,
  ) async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/password/reset'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'destination': destination,
            'code': code,
            'password': password,
            'password_confirm': passwordConfirm,
          }),
        )
        .timeout(_timeout);
    _storeTokens(_decode(res));
    await _persist();
  }

  /// Entra com e-mail **ou** telefone. O telefone vai com o país junto:
  /// `987654321` não identifica ninguém sem saber de onde é.
  Future<void> login(
    String password, {
    String? email,
    String? phone,
    String? country,
    String? totpCode,
  }) async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/login'),
          headers: _jsonHeaders,
          body: jsonEncode({
            if (email != null) 'email': email,
            if (phone != null) 'phone': phone,
            if (country != null) 'country': country,
            'password': password,
            if (totpCode != null && totpCode.isNotEmpty) 'totp_code': totpCode,
          }),
        )
        .timeout(_timeout);
    _storeTokens(_decode(res));
    await _persist();
  }

  // --- verificação em duas etapas (2FA) --------------------------------------

  /// Inicia a configuração do 2FA: retorna o segredo e o URI (para QR Code).
  Future<Map<String, String>> setupTwoFactor() async {
    final res = await _http.post(
      _uri('/api/v1/auth/2fa/setup'),
      headers: _authHeaders,
    );
    final body = _decode(res) as Map<String, dynamic>;
    return {
      'secret': body['secret'] as String,
      'otpauth_uri': body['otpauth_uri'] as String,
    };
  }

  /// Confirma a ativação do 2FA com um código do autenticador.
  Future<void> enableTwoFactor(String code) async {
    final res = await _http.post(
      _uri('/api/v1/auth/2fa/enable'),
      headers: _authHeaders,
      body: jsonEncode({'code': code}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Desativa o 2FA (exige a senha atual).
  Future<void> disableTwoFactor(String password) async {
    final res = await _http.post(
      _uri('/api/v1/auth/2fa/disable'),
      headers: _authHeaders,
      body: jsonEncode({'password': password}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// A conta de quem está logado.
  ///
  /// Substituiu o antigo `fetchTwoFactorEnabled`, que lia o `/me` inteiro para
  /// devolver um `bool`: agora a tela de conta também precisa saber se a conta
  /// se identifica por e-mail ou por telefone, e uma segunda chamada à mesma
  /// rota para pegar outro campo dela seria duas viagens pelo mesmo dado.
  Future<Conta> fetchAccount() async {
    final res = await _http.get(_uri('/api/v1/auth/me'), headers: _authHeaders);
    return Conta.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Restaura a sessão a partir dos tokens salvos. Renova o access token com o
  /// refresh; retorna false (e limpa) se não houver sessão válida.
  Future<bool> restore() async {
    final (access, refresh) = await _store.load();
    if (refresh == null) return false;
    _accessToken = access;
    _refreshToken = refresh;
    try {
      await refreshAccess();
      return true;
    } on ApiException catch (e) {
      // Só desloga se o servidor rejeitou o refresh (token inválido/expirado).
      // Erros de rede não devem forçar novo login: mantém a sessão e o app
      // revalida quando o servidor voltar a responder.
      if (e.statusCode == 401) {
        await logout();
        return false;
      }
      return true;
    } catch (_) {
      // Falha de rede (servidor fora do ar, Wi-Fi caiu): segue autenticado.
      return true;
    }
  }

  /// Troca o refresh token por um novo access token.
  Future<void> refreshAccess() async {
    final res = await _http
        .post(
          _uri('/api/v1/auth/refresh'),
          headers: _jsonHeaders,
          body: jsonEncode({'refresh_token': _refreshToken}),
        )
        .timeout(_timeout);
    final body = _decode(res) as Map<String, dynamic>;
    _accessToken = body['access_token'] as String?;
    await _persist();
  }

  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    await _store.clear();
  }

  // --- conta -----------------------------------------------------------------

  /// Troca o e-mail da conta (exige a senha atual).
  Future<void> updateEmail(String currentPassword, String newEmail) async {
    final res = await _http.patch(
      _uri('/api/v1/auth/me/email'),
      headers: _authHeaders,
      body: jsonEncode({
        'current_password': currentPassword,
        'new_email': newEmail,
      }),
    );
    _decode(res); // 200 ou lança
  }

  /// Troca o telefone da conta (exige a senha atual).
  ///
  /// O país vai junto e o servidor normaliza: sem isso, gravar "(11)
  /// 98765-4321" produziria uma forma que o login — que normaliza — nunca
  /// encontraria, e a pessoa ficaria fora da própria conta.
  Future<void> updatePhone(
    String currentPassword,
    String newPhone,
    String country,
  ) async {
    final res = await _http.patch(
      _uri('/api/v1/auth/me/phone'),
      headers: _authHeaders,
      body: jsonEncode({
        'current_password': currentPassword,
        'new_phone': newPhone,
        'country': country,
      }),
    );
    _decode(res); // 200 ou lança
  }

  /// Troca a senha da conta (exige a senha atual).
  ///
  /// Guarda o par de tokens que vem na resposta, e isso não é detalhe: trocar a
  /// senha **cancela no servidor todos os tokens da conta**, para derrubar
  /// sessões abertas em outros aparelhos. O que este aparelho tem em mãos morre
  /// junto, e sem trocar pelo par novo o app seria deslogado na requisição
  /// seguinte — a pessoa trocaria a senha e cairia na tela de login sem
  /// entender por quê.
  Future<void> updatePassword(
      String currentPassword, String newPassword) async {
    final res = await _http.patch(
      _uri('/api/v1/auth/me/password'),
      headers: _authHeaders,
      body: jsonEncode({
        'current_password': currentPassword,
        'new_password': newPassword,
      }),
    );
    _storeTokens(_decode(res));
    await _persist();
  }

  /// Exclui a conta (exige a senha). Ao concluir, limpa a sessão local.
  Future<void> deleteAccount(String password) async {
    final res = await _http.delete(
      _uri('/api/v1/auth/me'),
      headers: _authHeaders,
      body: jsonEncode({'password': password}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
    await logout();
  }

  Future<void> _persist() => _store.save(_accessToken, _refreshToken);

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

  /// Renomeia (apelido) um computador da conta.
  Future<Device> renameDevice(String deviceId, String name) async {
    final res = await _http.patch(
      _uri('/api/v1/devices/$deviceId'),
      headers: _authHeaders,
      body: jsonEncode({'name': name}),
    );
    return Device.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Desvincula um computador da conta.
  Future<void> removeDevice(String deviceId) async {
    final res = await _http.delete(
      _uri('/api/v1/devices/$deviceId'),
      headers: _authHeaders,
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Acorda um computador desligado via Wake-on-LAN (usa outro PC ligado na
  /// mesma rede como "peer"). Lança ApiException(409) quando não há peer.
  Future<void> wakeDevice(String deviceId) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/wake'),
      headers: _authHeaders,
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  // --- aplicativos do computador ---------------------------------------------

  /// Lista os aplicativos: `kind` = 'installed' (instalados) ou 'running'
  /// (abertos agora). Pode demorar alguns segundos — o computador é consultado
  /// na hora.
  Future<List<RemoteApp>> listApps(String deviceId, {String kind = 'installed'}) async {
    final res = await _http
        .get(
          _uri('/api/v1/devices/$deviceId/apps?kind=$kind'),
          headers: _authHeaders,
        )
        .timeout(const Duration(seconds: 25));
    final data = _decode(res) as List<dynamic>;
    return data
        .map((e) => RemoteApp.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Abre um aplicativo no computador (id = caminho do atalho).
  Future<void> launchApp(String deviceId, String id) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/apps/launch'),
      headers: _authHeaders,
      body: jsonEncode({'id': id}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Encerra um aplicativo em execução (id = PID).
  Future<void> closeApp(String deviceId, String id) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/apps/close'),
      headers: _authHeaders,
      body: jsonEncode({'id': id}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  // --- métricas e mídia -------------------------------------------------------

  /// Mede CPU, memória e disco do computador. O agente responde na hora.
  Future<SystemStats> systemStats(String deviceId) async {
    final res = await _http
        .get(_uri('/api/v1/devices/$deviceId/system'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    return SystemStats.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Qual programa está em primeiro plano no computador, com o ícone dele.
  ///
  /// `null` quando não há nenhum em foco — resposta normal, não erro.
  Future<ForegroundApp?> foregroundApp(String deviceId) async {
    final res = await _http
        .get(_uri('/api/v1/devices/$deviceId/foreground'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    return ForegroundApp.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Se o computador está sendo mantido pronto para ser alcançado.
  ///
  /// Pergunta ao agente a cada vez em vez de guardar: o estado depende de o
  /// notebook estar ou não na tomada, o que muda sem passar pelo servidor.
  Future<KeepAwakeState> keepAwake(String deviceId) async {
    final res = await _http
        .get(_uri('/api/v1/devices/$deviceId/keep-awake'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    return KeepAwakeState.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Liga ou desliga o "manter pronto". O agente grava a escolha em disco.
  Future<void> setKeepAwake(String deviceId, bool enabled) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/keep-awake'),
      headers: _authHeaders,
      body: jsonEncode({'enabled': enabled}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// O que está na área de transferência do computador: o texto e os
  /// **arquivos copiados** (que no Windows são caminhos, não bytes).
  Future<RemoteClipboard> clipboard(String deviceId) async {
    final res = await _http
        .get(_uri('/api/v1/devices/$deviceId/clipboard'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    return RemoteClipboard.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Os perfis que o usuário criou e a ordem escolhida para a barra.
  ///
  /// Ficam no servidor, e não no aparelho: a mesma conta é usada em mais de um
  /// aparelho, e o app instalado por sideload é reinstalado com frequência.
  Future<({List<ControlProfile> profiles, List<String> order})> profiles() async {
    final res = await _http
        .get(_uri('/api/v1/profiles'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    final json = _decode(res) as Map<String, dynamic>;
    return (
      profiles: ((json['profiles'] as List?) ?? [])
          .map((e) => ControlProfile.fromJson(e as Map<String, dynamic>))
          .toList(),
      order: ((json['order'] as List?) ?? []).map((e) => e as String).toList(),
    );
  }

  Future<ControlProfile> createProfile(ControlProfile profile) async {
    final res = await _http.post(
      _uri('/api/v1/profiles'),
      headers: _authHeaders,
      body: jsonEncode(profile.toJson()),
    );
    return ControlProfile.fromJson(
        _decode(res, expected: 201) as Map<String, dynamic>);
  }

  Future<ControlProfile> updateProfile(ControlProfile profile) async {
    final res = await _http.put(
      _uri('/api/v1/profiles/${profile.id}'),
      headers: _authHeaders,
      body: jsonEncode(profile.toJson()),
    );
    return ControlProfile.fromJson(_decode(res) as Map<String, dynamic>);
  }

  Future<void> deleteProfile(String id) async {
    final res = await _http.delete(
      _uri('/api/v1/profiles/$id'),
      headers: _authHeaders,
    );
    if (res.statusCode != 204) throw _error(res);
  }

  /// Guarda a ordem da barra. A lista vai inteira, de fábrica e criados
  /// juntos: a barra é uma só.
  Future<void> setProfileOrder(List<String> ids) async {
    final res = await _http.put(
      _uri('/api/v1/profiles/order'),
      headers: _authHeaders,
      body: jsonEncode({'ids': ids}),
    );
    if (res.statusCode != 204) throw _error(res);
  }

  /// As automações da conta.
  Future<List<Automation>> automations() async {
    final res = await _http
        .get(_uri('/api/v1/automations'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    final json = _decode(res) as Map<String, dynamic>;
    return ((json['automations'] as List?) ?? [])
        .map((e) => Automation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Automation> createAutomation(Automation a) async {
    final res = await _http.post(
      _uri('/api/v1/automations'),
      headers: _authHeaders,
      body: jsonEncode(a.toJson()),
    );
    return Automation.fromJson(_decode(res, expected: 201) as Map<String, dynamic>);
  }

  Future<Automation> updateAutomation(Automation a) async {
    final res = await _http.put(
      _uri('/api/v1/automations/${a.id}'),
      headers: _authHeaders,
      body: jsonEncode(a.toJson()),
    );
    return Automation.fromJson(_decode(res) as Map<String, dynamic>);
  }

  Future<void> deleteAutomation(String id) async {
    final res = await _http.delete(
      _uri('/api/v1/automations/$id'),
      headers: _authHeaders,
    );
    if (res.statusCode != 204) throw _error(res);
  }

  /// Roda a automação e devolve o que aconteceu com cada passo.
  ///
  /// A espera é longa de propósito: a sequência inteira roda **no computador**,
  /// numa mensagem só, e pode incluir esperas entre os passos. É esse desenho
  /// que faz a automação sobreviver ao iOS suspender o app assim que a tela
  /// apaga — se o telefone conduzisse passo a passo, bloquear o aparelho pararia
  /// a rotina no meio.
  ///
  /// `deviceId` só é usado quando a automação não fixou um computador.
  Future<List<StepResult>> runAutomation(String id, {String? deviceId}) async {
    final onde = (deviceId == null || deviceId.isEmpty)
        ? ''
        : '?device_id=${Uri.encodeQueryComponent(deviceId)}';
    final res = await _http
        .post(_uri('/api/v1/automations/$id/run$onde'), headers: _authHeaders)
        .timeout(const Duration(seconds: 160));
    final json = _decode(res) as Map<String, dynamic>;
    return ((json['results'] as List?) ?? [])
        .map((e) => StepResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// As telas do computador, e qual delas está sendo capturada.
  Future<RemoteMonitors> monitors(String deviceId) async {
    final res = await _http
        .get(_uri('/api/v1/devices/$deviceId/monitors'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    return RemoteMonitors.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Escolhe qual tela capturar. `null` volta ao monitor principal.
  Future<void> setMonitor(String deviceId, int? monitor) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/monitors'),
      headers: _authHeaders,
      body: jsonEncode({'monitor': monitor}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Coloca um texto na área de transferência do computador.
  Future<void> setClipboard(String deviceId, String text) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/clipboard'),
      headers: _authHeaders,
      body: jsonEncode({'text': text}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Liga ou desliga o aviso automático de cópia nova no computador.
  Future<void> setClipboardSync(String deviceId, bool enabled) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/clipboard/sync'),
      headers: _authHeaders,
      body: jsonEncode({'enabled': enabled}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Servidores ICE para negociar o vídeo direto (STUN e, quando o servidor
  /// tem, TURN com credencial temporária).
  Future<List<Map<String, dynamic>>> iceServers() async {
    final res = await _http
        .get(_uri('/api/v1/ice-servers'), headers: _authHeaders)
        .timeout(const Duration(seconds: 8));
    final body = _decode(res) as Map<String, dynamic>;
    return (body['ice_servers'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Liga ou desliga o som do computador no telefone. O som viaja pela mesma
  /// conexão direta que leva a tela, numa faixa Opus.
  Future<void> setAudio(String deviceId, bool enabled, {double gain = 1}) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/audio'),
      headers: _authHeaders,
      body: jsonEncode({'enabled': enabled, 'gain': gain}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Aciona uma tecla de mídia: `play_pause`, `next`, `previous`, `volume_up`,
  /// `volume_down` ou `mute`.
  Future<void> mediaKey(String deviceId, String action) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/media'),
      headers: _authHeaders,
      body: jsonEncode({'action': action}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
  }

  /// Abre vários programas de uma vez e devolve o resultado de cada um.
  ///
  /// Uma chamada, e não uma por programa, por causa do iOS: quem aperta o botão
  /// e bloqueia a tela teria a lista interrompida no meio, com o primeiro
  /// programa aberto e o resto não. O computador recebe a lista inteira e o
  /// telefone pode sair da frente no instante seguinte.
  ///
  /// A resposta vem na mesma ordem do pedido, com o identificador de cada um —
  /// é o que permite dizer *qual* não abriu.
  ///
  /// `zones` é **paralelo** a `apps`, e a escolha é deliberada: um agente que
  /// ainda não atualizou não conhece o campo, ignora e abre os programas como
  /// sempre. A degradação certa — "abriu sem posicionar" é exatamente o
  /// comportamento anterior. Vai só quando alguém escolheu alguma zona.
  Future<List<LaunchResult>> launchMany(
    String deviceId,
    List<String> apps, {
    List<WindowZone?>? zones,
  }) async {
    final temZona = zones != null && zones.any((z) => z != null);
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/apps/launch-many'),
      headers: _authHeaders,
      body: jsonEncode({
        'apps': apps,
        if (temZona) 'zones': [for (final z in zones) z?.toJson()],
      }),
    );
    if (res.statusCode != 200) {
      throw _error(res);
    }
    final corpo = jsonDecode(res.body) as Map<String, dynamic>;
    return ((corpo['results'] as List?) ?? [])
        .map((e) => LaunchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Ajusta o brilho da tela do computador e devolve o nível resultante.
  ///
  /// `delta` é um passo relativo (+10, −10) e `level` um valor absoluto; manda-se
  /// um ou outro, nunca os dois. O passo é somado **no computador**: fazer o
  /// telefone ler, somar e escrever custaria duas idas e voltas por toque, e
  /// dois toques rápidos se atropelariam — os dois leriam o mesmo valor antigo e
  /// o segundo desfaria o primeiro.
  ///
  /// Lança `ApiException(409)` com o motivo quando o computador não permite
  /// (monitor externo, por exemplo). Isso é resposta, não falha de rede: o
  /// motivo é a única informação útil que existe aqui.
  Future<int> setBrightness(String deviceId, {int? level, int? delta}) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/brightness'),
      headers: _authHeaders,
      body: jsonEncode(level != null ? {'level': level} : {'delta': delta}),
    );
    if (res.statusCode != 200) {
      throw _error(res);
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['level'] as int;
  }

  // --- arquivos ---------------------------------------------------------------

  /// Lista uma pasta do computador. Caminho vazio = a pasta do usuário.
  Future<RemoteListing> listFiles(String deviceId, {String path = ''}) async {
    final res = await _http
        .get(
          _uri('/api/v1/devices/$deviceId/files?path=${Uri.encodeQueryComponent(path)}'),
          headers: _authHeaders,
        )
        .timeout(const Duration(seconds: 30));
    return RemoteListing.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Baixa um arquivo do computador.
  ///
  /// O tempo limite é largo porque quem manda é o tamanho do arquivo, não a
  /// pressa de quem espera.
  Future<Uint8List> downloadFile(String deviceId, String path) async {
    final res = await _http
        .get(
          _uri('/api/v1/devices/$deviceId/files/download'
              '?path=${Uri.encodeQueryComponent(path)}'),
          headers: _authHeaders,
        )
        .timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) {
      throw _error(res);
    }
    return res.bodyBytes;
  }

  /// Envia um arquivo ao computador. Devolve onde ele foi salvo.
  Future<String> uploadFile(
    String deviceId,
    String name,
    Uint8List bytes,
  ) async {
    final res = await _http
        .post(
          _uri('/api/v1/devices/$deviceId/files/upload'
              '?name=${Uri.encodeQueryComponent(name)}'),
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/octet-stream',
          },
          body: bytes,
        )
        .timeout(const Duration(minutes: 10));
    final corpo = _decode(res) as Map<String, dynamic>;
    return corpo['path'] as String? ?? '';
  }

  /// Envia um comando de energia (shutdown/restart/suspend) ao computador.
  Future<void> powerDevice(String deviceId, String action) async {
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/power'),
      headers: _authHeaders,
      body: jsonEncode({'action': action}),
    );
    if (res.statusCode != 204) {
      throw _error(res);
    }
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

  /// Pede ao computador para começar a transmitir a tela. `fps`, `quality` e
  /// `maxWidth` ajustam desempenho/qualidade (o backend limita à faixa aceita).
  Future<void> startScreen(
    String deviceId, {
    int? fps,
    int? quality,
    int? maxWidth,
  }) async {
    final body = <String, dynamic>{};
    if (fps != null) body['fps'] = fps;
    if (quality != null) body['quality'] = quality;
    if (maxWidth != null) body['max_width'] = maxWidth;
    final res = await _http.post(
      _uri('/api/v1/devices/$deviceId/screen/start'),
      headers: _authHeaders,
      body: jsonEncode(body),
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
  WebSocketChannel connectScreen(
    String deviceId, {
    int? fps,
    int? quality,
    int? maxWidth,
  }) {
    final wsBase = baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final channel = WebSocketChannel.connect(
      Uri.parse('$wsBase/ws/viewer/$deviceId'),
    );
    // A qualidade escolhida vale no cold start (quando este é o 1º viewer).
    channel.sink.add(jsonEncode({
      'token': _accessToken,
      if (fps != null) 'fps': fps,
      if (quality != null) 'quality': quality,
      if (maxWidth != null) 'max_width': maxWidth,
    }));
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
