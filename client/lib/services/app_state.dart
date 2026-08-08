import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import '../models/control_profile.dart';
import '../models/device.dart';
import '../models/foreground_app.dart';
import '../models/keep_awake.dart';
import '../models/remote_app.dart';
import '../models/remote_file.dart';
import '../models/stream_quality.dart';
import '../models/system_stats.dart';
import 'api_client.dart';
import 'word_suggester.dart';

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

  /// Barra de sugestões no teclado remoto. Ligada por padrão, e desligável —
  /// ela nunca corrige sozinha, mas quem digita comando o dia todo pode achar
  /// que ela só ocupa espaço.
  bool suggestionsEnabled = true;

  /// Se o computador avisa o telefone quando alguém copia algo por lá.
  ///
  /// Desligado por padrão, e a escolha é sobre privacidade: o que passa pela
  /// área de transferência de alguém costuma incluir senha, e mandá-la sozinha
  /// para outro aparelho tem que ser deliberado.
  bool clipboardSync = false;

  /// Quanto o som do computador é amplificado antes de ser codificado.
  ///
  /// Serve a um jeito específico de usar: computador no volume mínimo (sem
  /// silenciar, senão não sobra o que capturar) e o volume de verdade
  /// recuperado aqui. 1 = como o computador entregou.
  double audioGain = 1;

  /// Perfil de atalhos aberto por último na barra seletora (`null` = nenhum).
  /// Guardado porque quem usa o app para assistir filme abre no mesmo perfil
  /// todo dia, e reescolher a cada sessão seria um passo sem motivo.
  String? profileId;

  AppLanguage language = AppLanguage.system;

  /// Palavras que já foram digitadas, carregadas do disco na inicialização.
  Map<String, int> _learnedWords = {};
  WordSuggester? _suggester;

  /// Sugeridor do idioma atual, com o histórico de quem usa.
  WordSuggester get wordSuggester => _suggester ??= WordSuggester.forLanguage(
        _resolvedLanguage,
        learned: _learnedWords,
      );

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
    // As palavras comuns são do idioma; o histórico de quem usa não é, e por
    // isso sobrevive à troca.
    _learnedWords = {..._suggester?.learned ?? _learnedWords};
    _suggester = null;
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
    suggestionsEnabled = prefs.getBool('suggestions') ?? true;
    profileId = prefs.getString('profileId');
    audioGain = (prefs.getDouble('audioGain') ?? 1).clamp(1.0, 32.0);
    clipboardSync = prefs.getBool('clipboardSync') ?? false;
    _learnedWords = _decodeLearned(prefs.getString('learnedWords'));
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

  /// Guarda (ou esquece) o perfil de atalhos escolhido. Não avisa os ouvintes:
  /// quem manda na barra é a tela de controle, e um `notifyListeners` aqui
  /// reconstruiria o app inteiro a cada toque num perfil.
  Future<void> setProfile(String? id) async {
    profileId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove('profileId');
    } else {
      await prefs.setString('profileId', id);
    }
  }

  Future<void> setSuggestionsEnabled(bool enabled) async {
    suggestionsEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('suggestions', enabled);
  }

  /// Guarda o que foi aprendido digitando. Chamado ao sair do controle, e não a
  /// cada palavra: escrever no disco a cada tecla seria caro e sem ganho.
  Future<void> saveLearnedWords() async {
    final aprendidas = _suggester?.learned;
    if (aprendidas == null || aprendidas.isEmpty) return;
    _learnedWords = {...aprendidas};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('learnedWords', jsonEncode(aprendidas));
  }

  static Map<String, int> _decodeLearned(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      // Histórico corrompido não pode impedir o app de abrir: recomeça vazio.
      return {};
    }
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

  // --- métricas e mídia --------------------------------------------------------

  Future<SystemStats> systemStats(Device device) =>
      api.systemStats(device.deviceId);

  Future<void> mediaKey(Device device, String action) =>
      api.mediaKey(device.deviceId, action);

  /// Abre vários programas de uma vez. Devolve o resultado de cada um.
  Future<List<LaunchResult>> launchMany(Device device, List<String> apps) =>
      api.launchMany(device.deviceId, apps);

  /// Ajusta o brilho da tela do computador. Devolve o nível resultante.
  Future<int> setBrightness(Device device, {int? level, int? delta}) =>
      api.setBrightness(device.deviceId, level: level, delta: delta);

  /// Área de transferência do computador (texto e arquivos copiados).
  Future<RemoteClipboard> clipboard(Device device) =>
      api.clipboard(device.deviceId);

  /// Perfis criados pelo usuário e a ordem da barra.
  ///
  /// Guardados aqui e não relidos a cada tela: a lista muda quando o usuário
  /// mexe nela, e um pedido por abertura de tela seria gasto sem contrapartida.
  List<ControlProfile> customProfiles = const [];
  List<String> profileOrder = const [];

  /// Recarrega os perfis do servidor. Falha em silêncio: sem eles a barra
  /// continua com os cinco de fábrica, que é melhor do que uma tela de erro.
  Future<void> loadProfiles() async {
    try {
      final r = await api.profiles();
      customProfiles = r.profiles;
      profileOrder = r.order;
      notifyListeners();
    } catch (_) {
      // Backend antigo ou rede fora: a barra fica só com os de fábrica.
    }
  }

  Future<ControlProfile> createProfile(ControlProfile p) async {
    final criado = await api.createProfile(p);
    customProfiles = [...customProfiles, criado];
    notifyListeners();
    return criado;
  }

  Future<void> updateProfile(ControlProfile p) async {
    final salvo = await api.updateProfile(p);
    customProfiles = [
      for (final c in customProfiles) c.id == salvo.id ? salvo : c,
    ];
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    await api.deleteProfile(id);
    customProfiles = customProfiles.where((c) => c.id != id).toList();
    profileOrder = profileOrder.where((i) => i != id).toList();
    notifyListeners();
  }

  Future<void> setProfileOrder(List<String> ids) async {
    final anterior = profileOrder;
    profileOrder = ids;
    notifyListeners();
    try {
      await api.setProfileOrder(ids);
    } catch (e) {
      // Mostrar uma ordem que o servidor não guardou seria mentir: ela
      // voltaria sozinha na próxima abertura, sem nada explicando.
      profileOrder = anterior;
      notifyListeners();
      rethrow;
    }
  }

  Future<RemoteMonitors> monitors(Device device) =>
      api.monitors(device.deviceId);

  Future<void> setMonitor(Device device, int? monitor) =>
      api.setMonitor(device.deviceId, monitor);

  Future<void> setClipboard(Device device, String text) =>
      api.setClipboard(device.deviceId, text);

  /// Liga/desliga o aviso automático de cópia nova no computador, e guarda a
  /// escolha. Desligado por padrão: o que passa pela área de transferência de
  /// alguém costuma incluir senha, e mandar isso sozinho para outro aparelho
  /// tem que ser uma decisão consciente.
  Future<void> setClipboardSync(Device device, bool enabled) async {
    await api.setClipboardSync(device.deviceId, enabled);
    clipboardSync = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('clipboardSync', enabled);
  }

  /// Servidores ICE do backend. Falha em silêncio para a lista padrão: sem
  /// eles o vídeo direto ainda tenta pelo STUN público, e um erro aqui não
  /// pode impedir de ver a tela.
  Future<List<Map<String, dynamic>>?> iceServers() async {
    try {
      final servers = await api.iceServers();
      return servers.isEmpty ? null : servers;
    } catch (_) {
      return null;
    }
  }

  /// Liga ou desliga o som do computador no telefone, com o ganho atual.
  Future<void> setAudio(Device device, bool enabled) =>
      api.setAudio(device.deviceId, enabled, gain: audioGain);

  /// Só o ganho, sem mexer no liga/desliga (o agente aplica na hora).
  Future<void> sendAudioGain(Device device) =>
      api.setAudio(device.deviceId, true, gain: audioGain);

  /// Guarda o ganho escolhido. Sem `notifyListeners`: quem manda no controle é
  /// a tela de controle, e arrastar o cursor reconstruiria o app inteiro.
  Future<void> setAudioGain(double gain) async {
    audioGain = gain.clamp(1.0, 32.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('audioGain', audioGain);
  }

  /// Se o computador está sendo mantido pronto para ser alcançado.
  Future<KeepAwakeState> keepAwake(Device device) =>
      api.keepAwake(device.deviceId);

  /// Liga ou desliga o "manter pronto" naquele computador.
  Future<void> setKeepAwake(Device device, bool enabled) =>
      api.setKeepAwake(device.deviceId, enabled);

  /// Qual programa está em primeiro plano no computador (para os ícones dos
  /// perfis). `null` quando não há nenhum em foco.
  Future<ForegroundApp?> foregroundApp(Device device) =>
      api.foregroundApp(device.deviceId);

  // --- arquivos ----------------------------------------------------------------

  Future<RemoteListing> listFiles(Device device, {String path = ''}) =>
      api.listFiles(device.deviceId, path: path);

  Future<Uint8List> downloadFile(Device device, String path) =>
      api.downloadFile(device.deviceId, path);

  Future<String> uploadFile(Device device, String name, Uint8List bytes) =>
      api.uploadFile(device.deviceId, name, bytes);

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
