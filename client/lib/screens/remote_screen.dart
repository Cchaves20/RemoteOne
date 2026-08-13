import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../l10n/strings.dart';
import '../models/automation.dart';
import '../models/control_profile.dart';
import '../models/device.dart';
import '../models/remote_app.dart';
import '../models/remote_file.dart';
import '../models/system_stats.dart';
import '../services/app_state.dart';
import '../services/teclado_fisico.dart';
import '../services/video_session.dart';
import '../theme.dart';
import '../widgets/profile_bar.dart';
import '../widgets/remote_keyboard.dart';
import '../widgets/transitions.dart';
import 'automations_screen.dart' show runAutomationFlow;
import 'gesture_tutorial_screen.dart';

/// Controle remoto por toque direto: a tela do computador ocupa a tela inteira
/// e o toque age como num touchscreen — tocar leva o cursor ao ponto e clica.
///
/// - Toque: move o cursor ao ponto + clique esquerdo
/// - Arrastar (1 dedo): o cursor segue o dedo
/// - Duplo toque: seleciona a palavra; arrastando no segundo toque, estende
/// - Segurar: clique direito no ponto
/// - 2 dedos: rolar
/// - Botão de teclado: abre o teclado com teclas especiais
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with TickerProviderStateMixin {
  static const _scrollDivisor = 24.0;

  /// Tamanho do ícone e a espessura da dock (ícone + respiro).
  static const double _dockIcon = 42;
  static const double _dockThickness = _dockIcon + 8;

  /// Largura de uma medida no painel do computador. Fixa para que "Memória" e
  /// "Disco" caibam com o valor inteiro (`7,8 GB / 16,0 GB`) sem reticências.
  static const double _metricWidth = 150;

  /// Frame ao vivo, já decodificado. É um `ValueNotifier` de propósito: só o
  /// widget da imagem se reconstrói a cada frame, em vez da tela inteira
  /// (dock, botões, gestos) — o que economiza trabalho da CPU do celular e,
  /// com isso, latência.
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  /// Se já chegou algum frame (troca "aguardando" → "ao vivo" uma única vez).
  bool _hasFrame = false;

  /// Um frame de cada vez: se um novo chega enquanto o anterior é decodificado,
  /// o antigo é descartado. Melhor mostrar a imagem mais recente do que
  /// acumular uma fila e ficar para trás.
  bool _decoding = false;

  /// Tentativa de receber a tela por WebRTC. Enquanto ela não estiver ao vivo,
  /// o que aparece é o JPEG — que o agente continua mandando exatamente até o
  /// vídeo conectar. É esse encaixe que faz o fallback ser automático.
  VideoSession? _video;

  /// Avisa uma vez por sessão, não a cada mudança de estado.
  bool _videoFailureShown = false;

  double _aspectRatio = 16 / 9;
  bool _aspectResolved = false;
  String? _error;
  bool _keyboardVisible = false;

  double _pendingScroll = 0;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _flushTimer;

  int _frameCount = 0;
  int _fps = 0;
  Timer? _fpsTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;

  // Zoom (acessibilidade): em "modo lupa" os gestos ampliam/movem a tela; fora
  // dele, os gestos controlam o mouse. Como o GestureDetector fica DENTRO do
  // InteractiveViewer, o mapeamento do cursor continua correto mesmo ampliado.
  bool _zoomMode = false;
  final TransformationController _transform = TransformationController();
  Size _viewBox = Size.zero;

  // Dock de aplicativos, no estilo do macOS: uma barra flutuante sempre
  // visível sobre a tela, compacta (só ícones) e que se arrasta pela alça —
  // para cima/baixo quando está em pé, para os lados quando está deitada.
  late final AnimationController _dockAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  List<RemoteApp>? _dockApps;

  /// Nomes (normalizados) dos programas abertos agora no computador.
  ///
  /// Alimenta o anel branco da dock. Guardado como conjunto de nomes, e não a
  /// lista inteira, porque a pergunta que a dock faz é sempre "este aqui está
  /// aberto?".
  Set<String> _rodando = const {};

  /// Programas abertos que **não** têm atalho na área de trabalho — o terminal
  /// é o caso típico. Entram no fim da dock como indicação, não como botão:
  /// não há como trazer uma janela para frente ainda, e um botão que não faz
  /// nada é pior que um ícone que informa.
  List<RemoteApp> _avulsos = const [];

  Timer? _rodandoTimer;
  bool _rodandoInFlight = false;
  bool _rodandoFailed = false;
  bool _dockLoading = false;
  /// Posição ao longo da borda, de -1 (topo/esquerda) a 1 (base/direita).
  double _dockPos = 0;

  // Painéis retráteis: as métricas do computador e o controle de mídia. Ficam
  // fechados, e cada um tem um botão só seu — o que está em jogo aqui é a tela
  // do computador, e tudo o que fica permanentemente em cima dela come área
  // útil. Abrir é uma decisão do usuário, para o momento em que ele quer.
  late final AnimationController _statsAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final AnimationController _mediaAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  /// As curvas vivem aqui, e não no `build`: criadas a cada quadro, cada uma
  /// deixaria um ouvinte no controlador até o coletor de lixo passar.
  late final Animation<double> _statsCurve = CurvedAnimation(
    parent: _statsAnim,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _mediaCurve = CurvedAnimation(
    parent: _mediaAnim,
    curve: Curves.easeOutCubic,
  );
  bool _statsOpen = false;
  bool _mediaOpen = false;
  /// Som do computador saindo no telefone. Começa desligado: quem abre o app
  /// para mexer no computador não quer o som da casa dele no ônibus.
  bool _audioOn = false;
  /// Confere, alguns segundos depois de ligar, se a faixa de som chegou.
  Timer? _audioCheck;

  /// Servidores ICE do backend (STUN e, quando há, TURN). Buscados uma vez
  /// por tela: a credencial vale horas, e a reconexão reaproveita.
  List<Map<String, dynamic>>? _iceServers;

  /// Último texto conhecido da área de transferência do computador.
  String? _pcClipboard;

  /// Arquivos copiados no computador, da última consulta.
  List<RemoteFile> _pcFiles = const [];

  /// As telas do computador. Carregadas uma vez ao abrir: monitores não
  /// aparecem e somem a cada segundo, e um pedido por tique seria gasto puro.
  List<RemoteMonitor> _monitors = const [];

  /// Qual tela está sendo capturada. `null` = o principal.
  int? _selectedMonitor;

  /// Quantos arquivos copiados ficaram fora do alcance do computador. Uma
  /// lista vazia sem este número não distingue "não copiei nada" de "copiei
  /// de um disco que o agente não abre" — e a segunda merece uma explicação.
  int _pcIgnored = 0;
  SystemStats? _stats;
  bool _statsFailed = false;
  /// Um pedido de cada vez: numa rede lenta os pedidos de 2 em 2 s se
  /// empilhariam, e a resposta que chegasse por último venceria — que pode ser
  /// a mais velha.
  bool _statsInFlight = false;
  Timer? _statsTimer;

  /// O que está sendo digitado, para a barra de sugestões do teclado. Vive aqui
  /// porque quem move o cursor é esta tela, e mover o cursor invalida o rastro.
  final TypedWord _typedWord = TypedWord();

  // Barra seletora de perfis: a mesma ideia da dock, mas o que se escolhe é um
  // conjunto de atalhos. Começa visível (são só cinco ícones finos) e some
  // inteira pelo botão da barra de cima, para quem quer a tela limpa.
  bool _profilesOpen = true;
  ControlProfile? _profile;

  /// Ícone real do programa de cada perfil, por `id` de perfil.
  ///
  /// É um acúmulo, e não um retrato do momento: o Apple Music sai da frente
  /// quando se volta ao navegador, mas o perfil de mídia continua sendo o do
  /// Apple Music - é ele que se está controlando. Some só ao sair da tela.
  final Map<String, Uint8List> _profileIcons = {};
  Timer? _foregroundTimer;
  bool _foregroundInFlight = false;
  /// Desliga a consulta de vez depois de uma falha (agente antigo, sem o
  /// endpoint): insistir a cada 3 s daria erro sem fim e gastaria bateria.
  bool _foregroundFailed = false;

  @override
  void initState() {
    super.initState();
    // Mantém a tela do celular acesa durante a sessão de controle (#13).
    WakelockPlus.enable();
    _esconderBarrasDoAndroid();
    _connect();
    _flushTimer =
        Timer.periodic(const Duration(milliseconds: 60), (_) => _flushScroll());
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _fps = _frameCount;
          _frameCount = 0;
        });
      }
    });
    // A dock de aplicativos carrega em segundo plano, sem travar a tela.
    _loadDockApps();
    // Quem está na frente do computador, para os ícones dos perfis.
    _startForegroundPolling();
    _loadIceServers();
    _loadMonitors();
    // Perfis criados pelo usuário, do servidor. Se falhar, a barra fica com os
    // cinco de fábrica — que já é útil.
    widget.state.loadProfiles().then((_) {
      if (mounted) setState(() {});
    });
    // E as automações, que entram na mesma barra como mais um grupo. Falham em
    // silêncio pelo mesmo motivo dos perfis: sem elas a barra continua útil.
    widget.state.loadAutomations().then((_) {
      if (mounted) setState(() {});
    });
    // Reabre no perfil de atalhos da última vez (pode não existir mais — uma
    // versão nova pode ter tirado um de fábrica, e o usuário pode ter apagado
    // um dos seus).
    _profile = ControlProfile.byId(widget.state.profileId, _perfis());
    // Na primeira vez que se controla um PC, mostra o tutorial de gestos (#20).
    if (!widget.state.gestureTutorialSeen) {
      widget.state.markGestureTutorialSeen();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          fadeThroughRoute(GestureTutorialScreen(state: widget.state)),
        );
      });
    }
  }

  /// Mensagens de texto do servidor que não são sinalização de vídeo.
  ///
  /// Hoje só uma: alguém copiou algo no computador. Ela chega **sem pedido**,
  /// e por isso vem por aqui em vez de por uma consulta periódica - perguntar
  /// de segundo em segundo o que está copiado seria caro e indiscreto.
  void _handleTextMessage(String raw) {
    Map<String, dynamic> message;
    try {
      message = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (message['type'] != 'clipboard') return;
    final texto = (message['text'] as String?) ?? '';
    if (texto.isEmpty) return;
    _pcClipboard = texto;
    // Escreve direto na área de transferência do telefone: é isso que faz a
    // sincronia valer a pena - copiar no computador e colar no celular sem
    // passo nenhum no meio.
    Clipboard.setData(ClipboardData(text: texto));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text(widget.state.t.clipboardReceived),
    ));
  }

  /// Busca os servidores ICE e, se vierem depois de a sessão já ter começado,
  /// reconecta para usá-los.
  ///
  /// A busca é rápida, mas a tela não pode esperar por ela: o JPEG já está no
  /// ar nesse meio tempo, e é melhor mostrar a tela e melhorar depois do que
  /// segurar tudo por uma chamada HTTP.
  Future<void> _loadIceServers() async {
    final servers = await widget.state.iceServers();
    if (!mounted || servers == null) return;
    _iceServers = servers;
    if (_video?.isLive != true) _connect();
  }

  /// Os perfis que valem para este computador, na ordem escolhida.
  List<ControlProfile> _perfis() => ControlProfile.arrange(
        widget.state.customProfiles,
        widget.state.profileOrder,
        widget.device.deviceId,
      );

  /// As automações que valem para este computador.
  ///
  /// As fixadas noutra máquina ficam de fora: um botão que age num computador
  /// que não está à vista é pior do que botão nenhum.
  List<Automation> _automacoes() => widget.state.automations
      .where((a) => a.appliesTo(widget.device.deviceId))
      .toList(growable: false);

  /// Abre um programa de um perfil no computador que está sendo controlado.
  ///
  /// O caminho guardado pode ser o de outro computador — é o caso de um perfil
  /// atribuído a mais de uma máquina. Quem resolve isso é o agente, que procura
  /// pelo nome quando o caminho não existe; daqui só sai o pedido.
  Future<void> _abrirPrograma(ProfileAction a) async {
    final caminho = a.appPath;
    if (caminho == null || caminho.isEmpty) return;
    try {
      await widget.state.launchApp(widget.device, caminho);
    } catch (e) {
      _avisar(e.toString());
    }
  }

  /// Abre todos os programas do perfil aberto, de uma vez.
  ///
  /// Manda a lista inteira numa chamada só. Não é economia de rede: se fosse
  /// uma chamada por programa, bastaria a pessoa bloquear a tela depois do
  /// toque para o iOS suspender o app e a lista parar no meio — com o primeiro
  /// programa aberto e o resto não.
  ///
  /// O resultado é anunciado sempre, e nomeia quem falhou. O efeito acontece
  /// **no computador**, e de longe não se vê nada: sem o aviso, um toque que
  /// funcionou e um que não fez nada seriam idênticos.
  Future<void> _abrirTodos() async {
    final perfil = _profile;
    if (perfil == null) return;
    final programas = perfil.launches;
    if (programas.isEmpty) return;
    final t = widget.state.t;
    _avisar(t.appOpening(perfil.name(t)));
    try {
      final r = await widget.state.launchMany(
        widget.device,
        [for (final p in programas) p.appPath!],
        zones: [for (final p in programas) p.zone],
      );
      final falharam = r.where((x) => !x.ok).toList();
      if (falharam.isEmpty) {
        // `ok` **com** motivo é o desfecho do meio: o programa abriu e a janela
        // não foi para o lugar. Dizer que falhou seria mentira - ele está lá -,
        // e ficar calado deixaria a tela fora do lugar sem explicação.
        final semLugar = r.where((x) => x.error != null).toList();
        _avisar(semLugar.isEmpty
            ? t.openAllDone(r.length)
            : t.openAllNotPlaced(_nomesDe(semLugar, programas)));
        return;
      }
      _avisar(t.openAllPartial(
        r.length - falharam.length,
        r.length,
        _nomesDe(falharam, programas),
      ));
    } catch (e) {
      _avisar(e.toString());
    }
  }

  /// Os nomes dos programas de uma lista de resultados.
  ///
  /// O nome, e não o caminho: `C:\Users\...\Teams.lnk` não diz nada a quem
  /// está olhando o celular.
  static String _nomesDe(
    List<LaunchResult> quais,
    List<ProfileAction> programas,
  ) {
    return quais
        .map((x) => programas
            .firstWhere(
              (p) => p.appPath == x.id,
              orElse: () => programas.first,
            )
            .appName)
        .join(', ');
  }

  /// Ajusta o brilho da tela do computador em passos.
  ///
  /// Confirma com um aviso curto — e isso não é enfeite. O resultado do comando
  /// acontece **na outra ponta**: a tela que muda é a do computador, e quem
  /// está olhando o celular não veria diferença nenhuma. Sem confirmação, um
  /// toque que funcionou e um toque que não fez nada seriam idênticos.
  ///
  /// O erro aparece pelo mesmo caminho, e com o motivo que o computador deu:
  /// num computador de mesa com monitor externo não há brilho a ajustar por
  /// software, e a pessoa precisa saber que o problema não é o app.
  Future<void> _ajustarBrilho(int delta) async {
    final t = widget.state.t;
    try {
      final nivel = await widget.state.setBrightness(widget.device, delta: delta);
      _avisar(t.brightnessSet(nivel));
    } catch (e) {
      _avisar(e.toString());
    }
  }

  /// Descobre as telas do computador, uma vez.
  ///
  /// Falha em silêncio de propósito: um computador com um monitor só, ou um
  /// agente antigo que nem conhece o pedido, não deve gerar aviso nenhum — o
  /// botão simplesmente não aparece.
  Future<void> _loadMonitors() async {
    try {
      final telas = await widget.state.monitors(widget.device);
      if (!mounted) return;
      setState(() {
        _monitors = telas.monitors;
        _selectedMonitor = telas.selected;
      });
    } catch (_) {
      // Sem lista, sem botão.
    }
  }

  /// Folha de escolha da tela.
  Future<void> _openMonitors() async {
    HapticFeedback.selectionClick();
    final t = widget.state.t;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
              child: Text(
                t.monitorsTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                t.monitorsSub,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            for (final m in _monitors)
              ListTile(
                leading: Icon(
                  m.primary ? Icons.desktop_windows : Icons.monitor,
                  color: _isCurrentMonitor(m) ? auroraCyan : Colors.white70,
                ),
                title: Text(
                  m.name.isEmpty ? '#${m.id}' : m.name,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                subtitle: Text(
                  [
                    if (m.resolution.isNotEmpty) m.resolution,
                    if (m.primary) t.monitorPrimary,
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: _isCurrentMonitor(m)
                    ? const Icon(Icons.check, color: auroraCyan)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickMonitor(m.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Se esta é a tela em uso. Sem escolha explícita, vale o principal — que é
  /// exatamente o que o agente faz do lado de lá.
  bool _isCurrentMonitor(RemoteMonitor m) =>
      _selectedMonitor == null ? m.primary : _selectedMonitor == m.id;

  Future<void> _pickMonitor(int id) async {
    final anterior = _selectedMonitor;
    setState(() => _selectedMonitor = id);
    try {
      await widget.state.setMonitor(widget.device, id);
    } catch (e) {
      // Voltar ao que era: mostrar uma marca de seleção numa tela que não
      // mudou seria mentir sobre o estado do computador.
      if (mounted) setState(() => _selectedMonitor = anterior);
      _avisar(e.toString());
    }
  }

  void _connect() {
    _sub?.cancel();
    final q = widget.state.streamQuality;
    final channel = widget.state.api.connectScreen(
      widget.device.deviceId,
      fps: q.fps,
      quality: q.quality,
      maxWidth: q.maxWidth,
    );
    _channel = channel;

    // O mesmo socket carrega os frames JPEG (binário) e a sinalização de
    // WebRTC (texto). A sessão de vídeo é criada aqui e negocia em paralelo.
    _video?.dispose();
    _videoFailureShown = false;
    final video = widget.state.webrtcVideoEnabled
        ? (VideoSession(
            channel: channel,
            withAudio: _audioOn,
            // Os servidores vêm do backend (é de lá que sai a credencial
            // temporária do TURN). Quando não dá, a sessão usa o STUN público
            // que ela já trazia.
            iceServers: _iceServers,
          )..addListener(_onVideoChanged))
        : null;
    _video = video;

    _sub = channel.stream.listen(
      (event) {
        if (!mounted) return;
        // Texto = sinalização de WebRTC.
        if (event is String) {
          // A sinalização de WebRTC tem prioridade; o que ela não reconhecer
          // pode ser um aviso de área de transferência.
          if (video?.handleSignal(event) != true) _handleTextMessage(event);
          return;
        }
        if (event is! List<int>) return;
        final frame = event is Uint8List ? event : Uint8List.fromList(event);
        _frameCount++;
        _decodeFrame(frame);
      },
      onError: (Object _) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );

    // Só depois de o ouvinte estar no ar, senão a resposta do agente poderia
    // chegar antes de haver quem a tratasse.
    video?.start();
  }

  /// A sessão de vídeo mudou de estado: pode ser hora de trocar o que aparece.
  void _onVideoChanged() {
    final video = _video;
    if (!mounted || video == null) return;
    setState(() {
      // O som anda pela conexão direta: se ela caiu, não há mais som, e o
      // botão aceso diria o contrário. O agente também desliga a captura
      // sozinho quando fica sem ninguém ouvindo.
      //
      // "Falhou" sozinho não basta: a sessão também é marcada assim quando a
      // conexão está de pé e só falta imagem - e nesse caso o som continua
      // tocando. O que desliga o botão é a conexão ter ido embora.
      if (video.state == VideoState.failed && !video.peerAlive) _audioOn = false;
      if (video.isLive) {
        _hasFrame = true; // já há imagem, mesmo que nenhum JPEG tenha chegado
        _error = null;
        final ratio = video.aspectRatio;
        if (ratio != null && ratio > 0) {
          _aspectRatio = ratio;
          _aspectResolved = true;
        }
      }
    });

    // Falha no vídeo não pode ser silenciosa. A tela continua funcionando por
    // JPEG, então nada "quebra" visivelmente — e sem este aviso o motivo ficaria
    // só no log do aparelho, que num app instalado por sideload ninguém lê.
    if (video.state == VideoState.failed && !_videoFailureShown) {
      _videoFailureShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            '${widget.state.t.videoUnavailable}\n${video.error ?? ''}'.trim(),
          ),
        ),
      );
    }
  }

  /// Reconecta automaticamente se a conexão de tela cair (#12).
  void _scheduleReconnect() {
    if (_disposed) return;
    if (mounted) setState(() => _error = widget.state.t.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!_disposed) _connect();
    });
  }

  /// Decodifica o JPEG e publica o frame.
  ///
  /// Usa `decodeImageFromList` em vez de `Image.memory`: a imagem não passa
  /// pelo cache de imagens do Flutter, que trataria cada frame como uma
  /// imagem nova e encheria a memória em poucos segundos de transmissão.
  Future<void> _decodeFrame(Uint8List bytes) async {
    if (_decoding) return; // ainda desenhando o anterior: descarta este
    _decoding = true;
    try {
      final image = await decodeImageFromList(bytes);
      if (!mounted) {
        image.dispose();
        return;
      }
      final previous = _frame.value;
      _frame.value = image;
      // Libera o frame anterior só depois que o novo já foi ao ar.
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
      if (!_aspectResolved && image.height > 0) {
        _aspectResolved = true;
        setState(() => _aspectRatio = image.width / image.height);
      }
      if (!_hasFrame || _error != null) {
        setState(() {
          _hasFrame = true;
          _error = null;
        });
      }
    } catch (_) {
      // Frame corrompido (ex.: conexão instável): ignora e espera o próximo.
    } finally {
      _decoding = false;
    }
  }

  /// Esconde as barras do sistema enquanto se controla o computador.
  ///
  /// **Só no Android, e não é estética.** A navegação por gestos do Android põe
  /// o "voltar" na borda esquerda e na direita, e o "início" numa arrastada de
  /// baixo para cima — exatamente onde esta tela espera o dedo, porque o
  /// touchpad ocupa a área toda. Sem isto, arrastar o mouse até a beirada da
  /// tela fecha a sessão.
  ///
  /// `immersiveSticky` é o modo certo para o caso: as barras somem, e uma
  /// arrastada da borda as **revela** em vez de disparar o gesto. Quem quer
  /// mesmo sair arrasta duas vezes; quem só estava movendo o cursor, não sai.
  ///
  /// O iOS fica de fora de propósito: lá o comportamento atual já foi testado
  /// em uso, e esconder a barra de status mudaria uma tela que funciona por
  /// causa de um problema que aquela plataforma não tem.
  void _esconderBarrasDoAndroid() {
    if (!Platform.isAndroid) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// Devolve as barras ao sair. Sem isto, a lista de computadores e as
  /// configurações herdariam a tela cheia — e o app inteiro ficaria sem barra
  /// de navegação depois da primeira sessão de controle.
  void _devolverBarrasDoAndroid() {
    if (!Platform.isAndroid) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    _disposed = true;
    _devolverBarrasDoAndroid();
    _flushTimer?.cancel();
    _fpsTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _video?.removeListener(_onVideoChanged);
    _video?.dispose();
    _transform.dispose();
    _foco.dispose();
    _dockAnim.dispose();
    _statsTimer?.cancel();
    _foregroundTimer?.cancel();
    _rodandoTimer?.cancel();
    _audioCheck?.cancel();
    // Sair da tela sem desligar deixaria o computador capturando som para
    // ninguém. O agente também desliga sozinho quando a sessão cai, mas isto
    // resolve o caso comum antes de chegar lá.
    if (_audioOn) widget.state.setAudio(widget.device, false).ignore();
    _statsAnim.dispose();
    _mediaAnim.dispose();
    _typedWord.dispose();
    // Guarda o vocabulário aprendido nesta sessão. Aqui, e não a cada palavra:
    // escrever no disco a cada tecla custaria caro e não adiantaria nada.
    widget.state.saveLearnedWords();
    _frame.value?.dispose();
    _frame.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // --- dock de aplicativos ----------------------------------------------------

  /// Carrega os aplicativos do computador em segundo plano. Se falhar (ex.:
  /// agente antigo), a dock simplesmente não aparece — sem atrapalhar o
  /// controle remoto.
  Future<void> _loadDockApps() async {
    if (_dockLoading) return;
    setState(() => _dockLoading = true);
    try {
      // Só os atalhos da área de trabalho: é o conjunto que a pessoa escolheu
      // deixar à mão, então a dock fica curta e útil.
      final apps = await widget.state.listApps(widget.device, kind: 'desktop');
      if (!mounted) return;
      setState(() => _dockApps = apps);
      if (apps.isNotEmpty) _dockAnim.forward();
      _refreshRunning();
      // 10 s, e não 1 s como as métricas: cada consulta roda um PowerShell no
      // computador controlado. Um relógio rápido aqui transformaria a dock num
      // consumidor constante de CPU da máquina que se quer usar.
      _rodandoTimer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => _refreshRunning(),
      );
    } catch (_) {
      // Silencioso: a tela de Aplicativos mostra o erro em detalhe.
    } finally {
      if (mounted) setState(() => _dockLoading = false);
    }
  }

  /// Quem está aberto agora, para o anel da dock e para os avulsos.
  ///
  /// Falha em silêncio e **desiste**: agente antigo não conhece o pedido, e
  /// insistir de dez em dez segundos para sempre encheria o log dos dois lados
  /// sem nunca dar certo. A dock continua funcionando sem os anéis.
  Future<void> _refreshRunning() async {
    if (_rodandoInFlight || _rodandoFailed || !mounted) return;
    _rodandoInFlight = true;
    try {
      final abertos = await widget.state.listApps(widget.device, kind: 'running');
      if (!mounted) return;
      final naDock = (_dockApps ?? const <RemoteApp>[])
          .map((a) => RemoteApp.matchName(a.name))
          .toSet();
      setState(() {
        _rodando = abertos.map((a) => RemoteApp.matchName(a.name)).toSet();
        _avulsos = abertos
            .where((a) => !naDock.contains(RemoteApp.matchName(a.name)))
            .toList();
      });
    } catch (_) {
      _rodandoFailed = true;
      _rodandoTimer?.cancel();
      _rodandoTimer = null;
    } finally {
      _rodandoInFlight = false;
    }
  }


  /// Traz para frente um programa que já está aberto.
  ///
  /// O Windows pode recusar: só quem já está em primeiro plano tem direito de
  /// dar foco a outro, e o agente roda em segundo plano. Quando isso acontece,
  /// a janela pisca na barra de tarefas em vez de subir — e daqui não há como
  /// saber, porque o pedido chegou. Por isso a mensagem diz "trazendo", e não
  /// "pronto".
  Future<void> _focusFromDock(RemoteApp app) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.of(context);
    final t = widget.state.t;
    try {
      await widget.state.focusApp(widget.device, app.id);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(t.appFocusing(app.name)),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _launchFromDock(RemoteApp app) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.of(context);
    final t = widget.state.t;
    try {
      await widget.state.launchApp(widget.device, app.id);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(t.appOpening(app.name)),
      ));
      // Fora do relógio de 10 s: aqui a pessoa acabou de mandar abrir e está
      // olhando para o ícone. Esperar o próximo ciclo pareceria que não pegou.
      // Um segundo de folga porque o programa ainda não tem janela no instante
      // em que o `start` volta.
      Future.delayed(const Duration(seconds: 1), _refreshRunning);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // --- métricas do computador e mídia -----------------------------------------

  /// Abre ou fecha o painel de métricas.
  ///
  /// A consulta só existe enquanto o painel está aberto: medir custa uma ida e
  /// volta ao computador, e ninguém deve pagar isso por um painel fechado.
  void _toggleStats() {
    HapticFeedback.selectionClick();
    setState(() => _statsOpen = !_statsOpen);
    if (_statsOpen) {
      _statsAnim.forward();
      _refreshStats();
      _statsTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _refreshStats(),
      );
    } else {
      _statsAnim.reverse();
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }

  Future<void> _refreshStats() async {
    if (_statsInFlight || !mounted) return;
    _statsInFlight = true;
    try {
      final stats = await widget.state.systemStats(widget.device);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _statsFailed = false;
      });
    } catch (_) {
      // Sem SnackBar: o painel pergunta a cada 2 s, e um erro de rede viraria
      // uma fila de avisos. O próprio painel mostra que não conseguiu.
      if (mounted) setState(() => _statsFailed = true);
    } finally {
      _statsInFlight = false;
    }
  }

  void _toggleMedia() {
    HapticFeedback.selectionClick();
    setState(() => _mediaOpen = !_mediaOpen);
    if (_mediaOpen) {
      _mediaAnim.forward();
    } else {
      _mediaAnim.reverse();
    }
  }

  /// Pergunta de tempos em tempos qual programa está na frente.
  ///
  /// A cada 3 s, e não a cada segundo: trocar de janela é um gesto humano, e
  /// do outro lado a resposta pode custar uma extração de ícone.
  void _startForegroundPolling() {
    _refreshForeground();
    _foregroundTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshForeground(),
    );
  }

  Future<void> _refreshForeground() async {
    // Barra escondida ou lupa aberta: ninguém está olhando os ícones.
    if (_foregroundInFlight || _foregroundFailed) return;
    if (!_profilesOpen || _zoomMode) return;
    _foregroundInFlight = true;
    try {
      final app = await widget.state.foregroundApp(widget.device);
      if (!mounted || app == null) return;
      final icone = app.iconBytes;
      if (icone == null) return;
      final perfil = ControlProfile.forExecutable(app.exe);
      if (perfil == null) return;
      // Só reconstrói quando o ícone muda mesmo: isto roda a cada 3 s.
      final atual = _profileIcons[perfil.id];
      if (atual != null && _sameBytes(atual, icone)) return;
      setState(() => _profileIcons[perfil.id] = icone);
    } catch (_) {
      // Agente antigo ou sem rede: fica com os ícones desenhados, em silêncio.
      _foregroundFailed = true;
      _foregroundTimer?.cancel();
    } finally {
      _foregroundInFlight = false;
    }
  }

  /// Nome de placa de vídeo encurtado para caber no rótulo da medida.
  ///
  /// Tira o fabricante, que é a parte que não distingue nada: num notebook com
  /// duas placas, o que importa é "Iris Xe" contra "RTX 3060", e num rótulo de
  /// 150 px o nome inteiro seria cortado justamente antes disso.
  static String _curto(String nome) {
    var n = nome.trim();
    for (final prefixo in const [
      'NVIDIA ',
      'AMD ',
      'Intel(R) ',
      'Intel ',
      'Microsoft ',
    ]) {
      if (n.startsWith(prefixo)) {
        n = n.substring(prefixo.length);
        break;
      }
    }
    return n;
  }

  /// Compara dois ícones. O tamanho já separa quase todos os casos; o resto é
  /// uma varredura curta, e ela vale a pena para evitar redesenhar a tela.
  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _toggleProfiles() {
    HapticFeedback.selectionClick();
    setState(() => _profilesOpen = !_profilesOpen);
  }

  /// Escolhe (ou fecha) um perfil de atalhos. A escolha vai para o disco, sem
  /// esperar: o toque não pode ficar preso na gravação.
  void _selectProfile(ControlProfile? profile) {
    setState(() => _profile = profile);
    widget.state.setProfile(profile?.id);
  }

  Future<void> _media(String action) async {
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.state.mediaKey(widget.device, action);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(e.toString()),
      ));
    }
  }

  // --- zoom (lupa) ------------------------------------------------------------

  // A transformação é uma escala uniforme + deslocamento. Lemos/escrevemos
  // direto no armazenamento (coluna-major): [0]=escala, [12]/[13]=deslocamento.
  double get _scale => _transform.value[0];

  /// Amplia/reduz em torno do centro da tela, preservando o deslocamento atual.
  void _zoomBy(double factor) {
    if (_viewBox == Size.zero) return;
    final current = _scale;
    final target = (current * factor).clamp(1.0, 5.0);
    final f = target / current;
    if ((f - 1).abs() < 0.001) return;

    final tx = _transform.value[12];
    final ty = _transform.value[13];
    final focalX = _viewBox.width / 2;
    final focalY = _viewBox.height / 2;
    // Mantém o ponto central fixo: t' = foco − f·(foco − t)...
    var ntx = focalX - f * (focalX - tx);
    var nty = focalY - f * (focalY - ty);
    // ...e reenquadra: no novo zoom a imagem tem que continuar cobrindo a tela
    // (em 1× o deslocamento vira 0, então ela volta ao lugar).
    final minTx = _viewBox.width * (1 - target);
    final minTy = _viewBox.height * (1 - target);
    ntx = ntx.clamp(minTx, 0.0);
    nty = nty.clamp(minTy, 0.0);
    final m = Matrix4.identity();
    m[0] = target;
    m[5] = target;
    m[12] = ntx;
    m[13] = nty;
    _transform.value = m;
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

  /// Desloca a visão ampliada (setas), com limite para não passar das bordas.
  /// Frações positivas revelam conteúdo à esquerda/acima.
  void _pan(double dxFraction, double dyFraction) {
    if (_viewBox == Size.zero) return;
    final s = _scale;
    if (s <= 1.0) return; // sem zoom, não há para onde mover
    // Deslocamento válido: t ∈ [dim·(1−s), 0] mantém a imagem cobrindo a tela.
    final minTx = _viewBox.width * (1 - s);
    final minTy = _viewBox.height * (1 - s);
    final m = _transform.value.clone();
    m[12] = (m[12] + _viewBox.width * dxFraction).clamp(minTx, 0.0);
    m[13] = (m[13] + _viewBox.height * dyFraction).clamp(minTy, 0.0);
    _transform.value = m;
  }

  void _toggleZoomMode() {
    setState(() => _zoomMode = !_zoomMode);
    // Enquanto ampliado, pede um vídeo de maior qualidade (mais detalhe onde
    // importa); ao sair, volta à qualidade escolhida (economiza banda).
    _setStreamBoost(_zoomMode);
    if (_zoomMode) {
      // Ao entrar no modo lupa, já amplia um pouco (ajuda quem não usa pinça).
      if (_scale < 1.05) _zoomBy(2.0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(widget.state.t.zoomHint),
        ),
      );
    }
  }

  /// Aumenta a resolução/qualidade do vídeo no modo lupa e restaura ao sair.
  Future<void> _setStreamBoost(bool boosted) async {
    final q = widget.state.streamQuality;
    try {
      await widget.state.api.startScreen(
        widget.device.deviceId,
        fps: q.fps,
        quality: boosted ? 85 : q.quality,
        maxWidth: boosted ? 1920 : q.maxWidth,
      );
    } catch (_) {
      // Sem rede/agente: mantém o que está; não é crítico.
    }
  }

  // --- envio de comandos ------------------------------------------------------

  /// Envia um comando de entrada pelo caminho mais curto disponível.
  ///
  /// Com a conexão P2P de pé, vai pelo canal de dados: **um salto direto** até o
  /// computador. Sem ela, cai no HTTP, que atravessa `celular → VPS → agente`.
  /// A ordem importa — entrada é a função principal do app e não pode depender
  /// de o vídeo ter dado certo.
  /// Manda uma ação ao computador.
  ///
  /// `avisarFalha` existe porque nem toda ação é igual: mouse e teclas são de
  /// alta frequência e falham em silêncio de propósito (um aviso por movimento
  /// seria uma cascata de mensagens). Já tocar numa sugestão é um gesto único e
  /// deliberado — se não funcionar, ficar calado faz parecer que o app ignorou
  /// o toque.
  Future<void> _send(
    Map<String, dynamic> action, {
    bool avisarFalha = false,
  }) async {
    // Mexer no mouse leva o cursor para outro lugar: a palavra que o app achava
    // que estava sendo digitada deixa de corresponder ao que há na tela do
    // computador, e sugerir a partir dela seria sugerir sobre nada.
    final kind = action['kind'] as String?;
    if (kind != null && kind.startsWith('mouse')) _typedWord.reset();
    if (_video?.sendInput(action) == true) return;
    final messenger = avisarFalha ? ScaffoldMessenger.of(context) : null;
    try {
      await widget.state.api.sendInput(widget.device.deviceId, action);
    } catch (e) {
      // Silencioso por padrão: comandos de controle são de alta frequência.
      messenger?.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  ({double x, double y}) _norm(Offset local, Size box) => (
        x: (local.dx / box.width).clamp(0.0, 1.0),
        y: (local.dy / box.height).clamp(0.0, 1.0),
      );

  /// Quando e onde terminou o toque anterior, para reconhecer o duplo toque.
  ///
  /// O `GestureDetector` tem `onDoubleTap`, mas ele **consome** o ponteiro: um
  /// arrasto depois do segundo toque não chegaria ao `onScaleUpdate`, e é
  /// justamente o arrasto que estende a seleção. Reconhecer aqui, pelo tempo e
  /// pela distância, mantém o gesto inteiro nas mãos do mesmo detector.
  DateTime _lastTapEnd = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapSpot = Offset.zero;

  /// Selecionando agora: o botão está apertado no computador, e cada movimento
  /// do dedo estende a seleção em vez de só mover o cursor.
  bool _selecting = false;

  static const _doubleTapWindow = Duration(milliseconds: 320);
  static const _doubleTapSlop = 44.0;

  bool _isSecondTap(Offset local) {
    final agora = DateTime.now();
    final perto = (local - _lastTapSpot).distance <= _doubleTapSlop;
    return perto && agora.difference(_lastTapEnd) < _doubleTapWindow;
  }

  /// Começo de um toque. Se for o segundo em sequência, vira duplo clique que
  /// **segura** — a partir daí, arrastar seleciona.
  void _touchDown(Offset local, Size box) {
    // O detector avisa o mesmo dedo por dois caminhos (`onTapDown` e
    // `onScaleStart`). Sem esta guarda, o duplo clique sairia em dobro.
    if (_selecting || !_isSecondTap(local)) return;
    HapticFeedback.selectionClick();
    _selecting = true;
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    // `clicks: 1` = só aperta e segura, **sem clicar antes**: o primeiro toque
    // já mandou o seu clique. O computador vê clique + aperto dentro do
    // intervalo de duplo clique, que é o duplo clique de verdade.
    //
    // Com `clicks: 2` sairiam três cliques no total, e três cliques no Windows
    // selecionam o parágrafo inteiro em vez da palavra.
    _send({'kind': 'mouse_press', 'button': 'left', 'clicks': 1});
  }

  /// Fim de um toque, em qualquer caminho (soltou, cancelou, saiu da tela).
  void _touchUp() {
    _lastTapEnd = DateTime.now();
    if (!_selecting) return;
    _selecting = false;
    _send({'kind': 'mouse_release', 'button': 'left'});
  }

  void _tapAt(Offset local, Size box) {
    _lastTapSpot = local;
    // O segundo toque já mandou apertar; aqui só solta, senão sairia um clique
    // extra que desfaria a seleção que acabou de ser feita.
    if (_selecting) {
      _touchUp();
      return;
    }
    HapticFeedback.selectionClick();
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    _send({'kind': 'mouse_click', 'button': 'left'});
    _lastTapEnd = DateTime.now();
  }

  void _rightClickAt(Offset local, Size box) {
    // Segurar depois do duplo toque é o começo do arrasto que estende a
    // seleção, não um pedido de menu de contexto: o dedo fica parado antes de
    // andar, e o toque longo dispararia bem no meio disso.
    if (_selecting) return;
    HapticFeedback.mediumImpact();
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    _send({'kind': 'mouse_click', 'button': 'right'});
  }

  void _moveTo(Offset local, Size box) {
    final now = DateTime.now();
    if (now.difference(_lastMove).inMilliseconds < 40) return;
    _lastMove = now;
    final p = _norm(local, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
  }

  // --- mouse e trackpad -------------------------------------------------------

  /// Há um ponteiro de verdade conectado (mouse ou trackpad do iPad).
  ///
  /// Descoberto sem plugin nativo e sem adivinhação: **dedo não faz hover**.
  /// A simples chegada de um `PointerHoverEvent` prova que existe um
  /// dispositivo apontador, e o `kind` diz qual.
  bool _apontador = false;

  /// Um botão do mouse está apertado agora.
  ///
  /// Existe para os gestos de toque saírem do caminho enquanto o mouse manda:
  /// sem isto, o mesmo clique chegaria duas vezes ao computador - uma pela
  /// escuta do ponteiro, outra pelo `GestureDetector`, que no Flutter também
  /// recebe eventos de mouse.
  bool _mouseApertado = false;

  /// De que veio o gesto em curso: mouse ou dedo.
  ///
  /// Marcado na **descida** do ponteiro e não limpo na subida, porque um gesto
  /// dura mais que o evento que o começou: o `onTapUp` e o `onScaleEnd` chegam
  /// depois de o botão já ter sido solto, e uma bandeira que se apaga cedo
  /// deixaria o fim do gesto escapar para o caminho errado.
  ///
  /// Sem isto o mesmo clique sai duas vezes para o computador - uma pela
  /// escuta do ponteiro, outra pelo detector de toque, que no Flutter recebe
  /// mouse também. O sintoma seria duplo clique onde se pediu um.
  bool _gestoDeMouse = false;

  static bool _ehApontador(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

  // Bits da máscara de botões. Escritos aqui, e não importados das constantes
  // do Flutter, para não depender de qual biblioteca as reexporta: um import a
  // mais que o analisador considere redundante reprova a compilação inteira
  // com `--fatal-infos`, e estes três valores são estáveis desde sempre.
  static const int _botaoEsquerdo = 0x01;
  static const int _botaoDireito = 0x02;
  static const int _botaoMeio = 0x04;

  /// Traduz a máscara de botões do Flutter para o nome que o agente espera.
  ///
  /// É máscara, e não valor: com dois botões apertados os dois bits estão
  /// ligados. A ordem aqui define a precedência, e o esquerdo vem primeiro
  /// porque é o que quase sempre importa.
  static String? _botao(int mascara) {
    if (mascara & _botaoEsquerdo != 0) return 'left';
    if (mascara & _botaoDireito != 0) return 'right';
    if (mascara & _botaoMeio != 0) return 'middle';
    return null;
  }

  void _pontoMoveu(PointerHoverEvent e, Size box) {
    if (!_ehApontador(e.kind)) return;
    if (!_apontador) setState(() => _apontador = true);
    _moveTo(e.localPosition, box);
  }

  void _pontoDesceu(PointerDownEvent e, Size box) {
    // Tocar na tela do computador devolve as teclas para cá. Um botão da barra
    // de cima pode ter ficado com o foco no toque anterior, e a partir dali as
    // teclas parariam de chegar sem nenhum sinal do porquê. Aqui é seguro: esta
    // área não tem campo de texto nenhum.
    if (!_foco.hasPrimaryFocus) _foco.requestFocus();
    _gestoDeMouse = _ehApontador(e.kind);
    if (!_gestoDeMouse) return;
    final botao = _botao(e.buttons);
    if (botao == null) return;
    _mouseApertado = true;
    if (!_apontador) setState(() => _apontador = true);
    // Move antes de apertar: quem usa mouse pode ter entrado na área já
    // clicando, e sem esta posição o clique cairia onde o cursor estava antes.
    final p = _norm(e.localPosition, box);
    _send({'kind': 'mouse_move_to', 'x': p.x, 'y': p.y});
    _send({'kind': 'mouse_press', 'button': botao, 'clicks': 1});
  }

  void _pontoArrastou(PointerMoveEvent e, Size box) {
    if (!_ehApontador(e.kind) || !_mouseApertado) return;
    _moveTo(e.localPosition, box);
  }

  void _pontoSubiu(PointerUpEvent e, Size box) {
    if (!_ehApontador(e.kind) || !_mouseApertado) return;
    _mouseApertado = false;
    // `e.buttons` já vem zerado no evento de soltura - o botão que saiu é o
    // que estava na descida. Soltar os três é inofensivo e dispensa guardar
    // estado que só serviria para isto.
    for (final botao in const ['left', 'right', 'middle']) {
      _send({'kind': 'mouse_release', 'button': botao});
    }
  }

  // --- teclado físico ---------------------------------------------------------

  /// Para onde as teclas vão enquanto esta tela está no ar.
  ///
  /// Explícito, e não um `FocusScope` qualquer: precisa ser possível perguntar
  /// se **este** nó está na cadeia de foco. Sem isso, um campo de texto aberto
  /// numa folha (a área de transferência) receberia a letra e a mandaria ao
  /// computador ao mesmo tempo.
  final FocusNode _foco = FocusNode(debugLabel: 'teclas-do-computador');

  /// Tradutor de teclas. Sem estado, por isso `const` e compartilhado.
  static const TecladoFisico _tradutor = TecladoFisico();

  /// Já chegou alguma tecla de um teclado de verdade.
  ///
  /// Mesma ideia do ponteiro: em vez de perguntar ao sistema quais aparelhos
  /// existem — o que o iPadOS não responde a um app comum —, deixa o próprio
  /// evento provar. Ligado, o teclado da tela para de aparecer sozinho: quem
  /// tem teclado não quer metade da tela ocupada por outro.
  bool _tecladoFisico = false;

  /// Uma tecla física chegou.
  ///
  /// Devolve `handled` só quando algo foi mandado ao computador. `ignored` no
  /// resto deixa o iPadOS seguir com o atalho dele, que é o certo para as
  /// teclas que este app não usa.
  KeyEventResult _aoTeclar(FocusNode node, KeyEvent evento) {
    // Só a descida (e a repetição, que é segurar a tecla). A subida não gera
    // ação: o agente digita, não simula pressionar e soltar.
    if (evento is KeyUpEvent) return KeyEventResult.ignored;
    // Fora da cadeia de foco, ou com uma folha aberta por cima, as teclas são
    // de quem está na frente — não desta tela.
    if (!node.hasFocus) return KeyEventResult.ignored;
    final rota = ModalRoute.of(context);
    if (rota != null && !rota.isCurrent) return KeyEventResult.ignored;

    // A prova de que existe teclado é a tecla ter chegado, inclusive quando
    // ela é só um Shift — que não vira ação nenhuma.
    if (!_tecladoFisico) {
      setState(() => _tecladoFisico = true);
      _avisar(widget.state.t.physicalKeyboard);
    }

    final teclado = HardwareKeyboard.instance;
    final acao = _tradutor.traduzir(
      tecla: evento.logicalKey,
      caractere: evento.character,
      ctrl: teclado.isControlPressed,
      alt: teclado.isAltPressed,
      shift: teclado.isShiftPressed,
      meta: teclado.isMetaPressed,
    );
    if (acao == null) return KeyEventResult.ignored;
    _rastrearPalavra(acao);
    _send(acao);
    return KeyEventResult.handled;
  }

  /// Mantém o rastro da palavra digitada, o mesmo que o teclado da tela
  /// alimenta. Sem isto, alternar entre os dois deixaria a barra de sugestões
  /// oferecendo o fim de uma palavra que já mudou.
  void _rastrearPalavra(Map<String, dynamic> acao) {
    final kind = acao['kind'];
    if (kind == 'key_text') {
      for (final c in (acao['text'] as String).split('')) {
        _typedWord.addChar(c);
      }
      return;
    }
    if (kind == 'key_press' && acao['key'] == 'backspace') {
      _typedWord.backspace();
      return;
    }
    // Seta, Enter, atalho: o cursor foi para outro lugar e o rastro morreu.
    _typedWord.reset();
  }

  void _pontoRolou(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _pendingScroll += e.scrollDelta.dy;
    _flushScroll();
  }

  void _flushScroll() {
    final steps = (_pendingScroll / _scrollDivisor).truncate();
    if (steps == 0) return;
    _pendingScroll -= steps * _scrollDivisor;
    _send({'kind': 'mouse_scroll', 'dy': -steps});
  }

  // --- UI ---------------------------------------------------------------------

  /// Dock flutuante de aplicativos, no estilo do macOS: sempre visível sobre a
  /// tela, compacta (só ícones) e móvel — arraste pela alça para deslocá-la ao
  /// longo da borda. Em pé quando o celular está na horizontal; deitada quando
  /// está na vertical.
  Widget _appDock({required bool vertical, required Size area}) {
    final atalhos = _dockApps ?? const <RemoteApp>[];
    // Os avulsos entram **no fim**, depois dos atalhos: a ordem que a pessoa
    // montou na área de trabalho é estável, e o que está aberto muda o tempo
    // todo. Intercalar faria os ícones dançarem de lugar a cada dez segundos.
    final apps = [...atalhos, ..._avulsos];
    if (apps.isEmpty) return const SizedBox.shrink();

    // Limita o comprimento a ~65% da tela: fica curta e não cobre demais.
    final maxLength = (vertical ? area.height : area.width) * 0.65;
    final curved = CurvedAnimation(parent: _dockAnim, curve: Curves.easeOutBack);

    final pill = Container(
      decoration: glassPill(),
      padding: const EdgeInsets.all(6),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: vertical ? maxLength : double.infinity,
          maxWidth: vertical ? double.infinity : maxLength,
        ),
        child: vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                _dockGrip(vertical: true, area: area),
                Flexible(child: _dockList(apps, vertical: true)),
              ])
            : Row(mainAxisSize: MainAxisSize.min, children: [
                _dockGrip(vertical: false, area: area),
                Flexible(child: _dockList(apps, vertical: false)),
              ]),
      ),
    );

    return Align(
      // A posição ao longo da borda vem de _dockPos (-1 a 1); o Align já
      // mantém a dock dentro da área visível.
      alignment: vertical ? Alignment(1, _dockPos) : Alignment(_dockPos, 1),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ScaleTransition(
          scale: curved,
          child: FadeTransition(opacity: _dockAnim, child: pill),
        ),
      ),
    );
  }

  /// Alça de arrastar. Fica só nela para não brigar com a rolagem da lista.
  Widget _dockGrip({required bool vertical, required Size area}) {
    return GestureDetector(
      onPanUpdate: (d) {
        // Converte o arrasto em deslocamento relativo à metade da área.
        final half = (vertical ? area.height : area.width) / 2;
        if (half <= 0) return;
        final delta = (vertical ? d.delta.dy : d.delta.dx) / half;
        setState(() => _dockPos = (_dockPos + delta).clamp(-1.0, 1.0));
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          vertical ? Icons.drag_handle : Icons.drag_indicator,
          size: 18,
          color: Colors.white38,
        ),
      ),
    );
  }

  /// Lista de ícones. O tamanho no eixo cruzado é fixo: sem isso a lista
  /// ocuparia todo o espaço disponível e esticaria os ícones.
  Widget _dockList(List<RemoteApp> apps, {required bool vertical}) {
    return SizedBox(
      width: vertical ? _dockThickness : null,
      height: vertical ? null : _dockThickness,
      child: ListView.builder(
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: apps.length,
        itemBuilder: (context, i) => _dockTile(
          apps[i],
          avulso: i >= (_dockApps?.length ?? 0),
        ),
      ),
    );
  }

  /// Ícone do aplicativo: o ícone real do programa quando o computador
  /// conseguiu enviá-lo; senão, a inicial no gradiente da marca. O nome aparece
  /// ao segurar (tooltip), mantendo a dock compacta.
  Widget _dockTile(RemoteApp app, {bool avulso = false}) {
    final t = widget.state.t;
    // O avulso **é** um programa aberto, por definição: ele veio da lista de
    // abertos. O atalho precisa ser conferido.
    final aberto = avulso || _rodando.contains(RemoteApp.matchName(app.name));
    final icon = app.iconBytes;
    final Widget content = icon != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              icon,
              width: _dockIcon,
              height: _dockIcon,
              fit: BoxFit.contain,
              // Os ícones vêm em 128px e são exibidos em ~42: a reamostragem
              // de melhor qualidade evita serrilhado.
              filterQuality: FilterQuality.high,
              // Ícone ilegível: cai para a inicial, sem quebrar a dock.
              errorBuilder: (_, __, ___) => _initialTile(app),
            ),
          )
        : _initialTile(app);

    // O anel branco: é o que responde "está aberto?" sem ocupar espaço nenhum
    // a mais. Fica **em volta** do ícone, com uma folga, para não brigar com o
    // desenho do próprio programa.
    final Widget alvo = Container(
      width: _dockIcon + 8,
      height: _dockIcon + 8,
      decoration: aberto
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white, width: 1.5),
            )
          : null,
      child: Center(
        child: SizedBox(width: _dockIcon, height: _dockIcon, child: content),
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(3),
      child: Tooltip(
        // O avulso diz **por que** está ali: sem isso, um ícone que não abre
        // nada no meio de uma fileira de botões parece defeito.
        message: avulso ? t.dockOpenOnly(app.name) : app.name,
        // Os dois tocam, e fazem coisas diferentes: o atalho **abre**, o
        // avulso já está aberto e só precisa vir para frente. O avulso segue
        // um pouco apagado - ele não é algo que a pessoa escolheu deixar na
        // dock, e a diferença visual evita confundir o que é fixo com o que é
        // passageiro.
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () =>
              avulso ? _focusFromDock(app) : _launchFromDock(app),
          // Center evita que a restrição justa do eixo cruzado da lista
          // estique o ícone (era o motivo das "barras" alongadas).
          child: avulso ? Opacity(opacity: 0.78, child: alvo) : alvo,
        ),
      ),
    );
  }

  /// Alternativa quando não há ícone: inicial do nome no gradiente da marca.
  Widget _initialTile(RemoteApp app) {
    final initial =
        app.name.isEmpty ? '?' : app.name.substring(0, 1).toUpperCase();
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: auroraGradient,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
    );
  }

  // --- faixas retráteis (métricas e mídia) ------------------------------------

  /// Faixa das métricas do computador.
  ///
  /// `vertical` = coluna ao lado da imagem (celular deitado, onde a altura é
  /// escassa); horizontal = faixa sob a barra de cima (celular em pé, onde
  /// sobra altura). Nos dois casos ela **empurra** a imagem em vez de cobri-la.
  Widget _statsStrip({required bool vertical}) {
    return _strip(
      anim: _statsAnim,
      curved: _statsCurve,
      axis: vertical ? Axis.horizontal : Axis.vertical,
      // Sempre a partir da borda em que encosta: da esquerda quando é coluna,
      // de cima quando é faixa.
      from: vertical ? Alignment.centerLeft : Alignment.topCenter,
      border: vertical
          ? const Border(right: BorderSide(color: Colors.white12))
          : const Border(bottom: BorderSide(color: Colors.white12)),
      child: _statsCard(vertical: vertical),
    );
  }

  /// Faixa dos botões de mídia: no topo com o celular deitado, embaixo (acima
  /// do teclado) com ele em pé.
  Widget _mediaStrip({required bool atBottom}) {
    return _strip(
      anim: _mediaAnim,
      curved: _mediaCurve,
      axis: Axis.vertical,
      // Em pé ela nasce embaixo e sobe; deitada, nasce em cima e desce.
      from: atBottom ? Alignment.bottomCenter : Alignment.topCenter,
      border: const Border(
        top: BorderSide(color: Colors.white12),
        bottom: BorderSide(color: Colors.white12),
      ),
      child: _mediaCard(),
    );
  }

  /// Moldura comum das faixas: abre e fecha crescendo no próprio eixo, o que
  /// faz a imagem ceder espaço em vez de ficar coberta. Fechada, **não existe**
  /// na árvore — nem ocupa espaço, nem intercepta toque.
  ///
  /// O `SizeTransition` faria isto, mas o parâmetro que escolhe a borda de
  /// crescimento mudou de nome nas versões novas do Flutter: o antigo virou
  /// aviso aqui, e o novo não existiria no Flutter do Codemagic. `ClipRect` +
  /// `Align` é o que o próprio `SizeTransition` faz por dentro, com API que não
  /// mudou — e assim o efeito é o mesmo nas duas pontas.
  Widget _strip({
    required AnimationController anim,
    required Animation<double> curved,
    required Axis axis,
    required Alignment from,
    required Border border,
    required Widget child,
  }) {
    return AnimatedBuilder(
      animation: anim,
      child: child,
      builder: (context, inner) {
        if (anim.isDismissed) return const SizedBox.shrink();
        final fator = curved.value.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(
            alignment: from,
            heightFactor: axis == Axis.vertical ? fator : null,
            widthFactor: axis == Axis.horizontal ? fator : null,
            child: FadeTransition(
              opacity: curved,
              child: Container(
                // Mesma faixa escura da barra de cima: é parte da moldura do
                // app, não um cartão flutuando.
                decoration: BoxDecoration(
                  color: const Color(0xFF14162C),
                  border: border,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: inner,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Conteúdo do painel de métricas.
  ///
  /// `vertical` = uma coluna estreita (ao lado da imagem); horizontal = as
  /// medidas em `Wrap`, que vira duas colunas num celular e quatro num tablet
  /// — uma linha só de quatro cortaria "7,8 GB / 16,0 GB" com reticências.
  Widget _statsCard({required bool vertical}) {
    final t = widget.state.t;
    final stats = _stats;
    if (stats == null) {
      return SizedBox(
        width: vertical ? _metricWidth : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_statsFailed) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                _statsFailed ? t.systemUnavailable : '${t.systemPanel}…',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    // Se está drenando ou carregando. Importa mais que o número em si: 68%
    // na bateria e 68% na tomada são situações opostas para quem depende de o
    // computador continuar alcançável. Vazio quando o sistema não sabe
    // responder — máquina virtual, por exemplo.
    final String fonteDeEnergia = switch (stats.onBattery) {
      true => ' · ${t.batteryOnBattery}',
      false => ' · ${t.batteryPluggedIn}',
      null => '',
    };

    final tiles = <Widget>[
      _metric(
        label: t.systemCpu,
        value: '${stats.cpuPercent.round()}%',
        fraction: stats.cpuPercent / 100,
        vertical: vertical,
      ),
      _metric(
        label: t.systemMemory,
        value: '${SystemStats.formatBytes(stats.memoryUsed)}'
            ' / ${SystemStats.formatBytes(stats.memoryTotal)}',
        fraction: stats.memoryFraction,
        vertical: vertical,
      ),
      _metric(
        label: stats.diskName.isEmpty
            ? t.systemDisk
            : '${t.systemDisk} ${stats.diskName}',
        value: '${SystemStats.formatBytes(stats.diskUsed)}'
            ' / ${SystemStats.formatBytes(stats.diskTotal)}',
        fraction: stats.diskFraction,
        vertical: vertical,
      ),
      // As quatro que faltavam. Cada uma só entra na lista quando o computador
      // respondeu com ela: um desktop não tem bateria, uma máquina virtual não
      // tem GPU dedicada, e temperatura no Windows quase sempre depende de
      // driver do fabricante. Uma medida vazia na tela não informa nada e ainda
      // faz parecer que o app quebrou.
      if (stats.gpuPercent != null)
        _metric(
          // O nome da placa entra no rótulo quando veio: "GPU" sozinho não
          // diz se está sendo medida a integrada ou a dedicada, e num
          // notebook com as duas essa é a primeira pergunta.
          label: stats.gpuName == null
              ? t.systemGpu
              : '${t.systemGpu} · ${_curto(stats.gpuName!)}',
          value: '${stats.gpuPercent!.round()}%',
          fraction: stats.gpuPercent! / 100,
          vertical: vertical,
        ),
      if (stats.temperatureCelsius != null)
        _metric(
          label: t.systemTemperature,
          value: '${stats.temperatureCelsius!.round()} °C',
          // Escala de 30 a 100 °C: a barra cheia é o ponto em que a máquina
          // começa a se proteger, não um limite teórico. Uma escala de 0 a 100
          // deixaria toda temperatura normal parecendo "quase nada".
          fraction: ((stats.temperatureCelsius! - 30) / 70).clamp(0.0, 1.0),
          vertical: vertical,
        ),
      _metric(
        label: t.systemNetwork,
        // Seta para baixo é o que desce para o computador; para cima, o que
        // sobe. É a convenção de todo medidor de rede.
        value: '↓ ${SystemStats.formatRate(stats.networkRxBps)}'
            '   ↑ ${SystemStats.formatRate(stats.networkTxBps)}',
        fraction: null,
        vertical: vertical,
      ),
      if (stats.batteryPercent != null)
        _metric(
          label: t.systemBattery,
          value: '${stats.batteryPercent}%$fonteDeEnergia',
          fraction: stats.batteryPercent! / 100,
          vertical: vertical,
        ),
      _metric(
        label: t.systemUptime,
        value: stats.uptimeLabel(
          days: t.unitDay,
          hours: t.unitHour,
          minutes: t.unitMinute,
        ),
        fraction: null,
        vertical: vertical,
      ),
    ];

    // Rolável desde que o painel passou de quatro medidas para até oito. Num
    // celular deitado a coluna não cabe mais na altura da tela, e o Flutter
    // resolveria isso com a faixa amarela de estouro por cima da imagem do
    // computador. Rolar é a resposta certa: nenhuma medida some, e o painel
    // continua ocupando só o espaço que tem.
    final Widget medidas = vertical
        ? SizedBox(
            width: _metricWidth,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: tiles,
              ),
            ),
          )
        : ConstrainedBox(
            // Em pé sobra altura, mas não a ponto de deixar oito medidas
            // empurrarem a tela do computador para um quarto do celular.
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 10,
                children: [
                  for (final tile in tiles)
                    SizedBox(width: _metricWidth, child: tile),
                ],
              ),
            ),
          );

    // Uma medida que falhou não apaga a última leitura boa: o painel segue
    // mostrando o que sabe, com o aviso embaixo.
    if (!_statsFailed) return medidas;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        medidas,
        const SizedBox(height: 6),
        Text(
          t.systemUnavailable,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }

  /// Uma medida: rótulo, valor e (quando faz sentido) a barra de proporção.
  Widget _metric({
    required String label,
    required String value,
    required double? fraction,
    required bool vertical,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: vertical ? 5 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (fraction != null) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.white12,
                // Vermelho quando aperta: a cor é a informação que se lê de
                // longe, antes de ler o número.
                valueColor: AlwaysStoppedAnimation(
                  fraction >= 0.9
                      ? const Color(0xFFEF5350)
                      : fraction >= 0.7
                          ? const Color(0xFFFFB74D)
                          : auroraCyan,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Botões de mídia. As teclas são globais no computador: valem para quem
  /// estiver tocando som, sem precisar deixar o player em foco.
  Widget _mediaCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _mediaButtons(),
        // A linha do volume só existe com o som ligado: sem som, um controle
        // de volume é um botão que não faz nada.
        if (_audioOn) _gainRow(),
      ],
    );
  }

  /// Volume do som que vem do computador.
  ///
  /// Existe para um jeito específico de usar: deixar o computador quase mudo
  /// (volume no mínimo, **sem** silenciar - silenciado não sobra o que
  /// capturar) e recuperar o volume aqui. Quem amplifica é o computador, antes
  /// de codificar: amplificar no telefone amplificaria junto o ruído do
  /// codificador, e o que se ouviria seria chiado.
  Widget _gainRow() {
    final t = widget.state.t;
    final ganho = widget.state.audioGain;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          const Icon(Icons.volume_up, size: 18, color: Colors.white54),
          Expanded(
            child: Slider(
              value: ganho.clamp(1.0, 32.0),
              min: 1,
              max: 32,
              // 31 passos de 1x: o suficiente para acertar o volume sem virar
              // uma busca por um valor exato.
              divisions: 31,
              label: '${ganho.round()}x',
              onChanged: (v) => setState(() => widget.state.audioGain = v),
              // O envio é no fim do arrasto, não a cada pixel: seriam dezenas
              // de chamadas por segundo para um valor que só a última importa.
              onChangeEnd: _applyGain,
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${ganho.round()}x',
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Tooltip(
            message: t.audioGainHint,
            child: const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.info_outline, size: 16, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyGain(double gain) async {
    await widget.state.setAudioGain(gain);
    if (!_audioOn) return;
    try {
      await widget.state.sendAudioGain(widget.device);
    } catch (_) {
      // Sem rede: o valor fica guardado e vale no próximo "ligar".
    }
  }

  Widget _mediaButtons() {
    final t = widget.state.t;
    return Row(
      // A faixa ocupa a largura toda; os botões ficam centrados nela.
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _mediaButton(Icons.volume_down, t.mediaVolumeDown, 'volume_down'),
        _mediaButton(Icons.volume_off, t.mediaMute, 'mute'),
        _mediaButton(Icons.skip_previous, t.mediaPrevious, 'previous'),
        _mediaButton(Icons.play_arrow, t.mediaPlayPause, 'play_pause',
            big: true),
        _mediaButton(Icons.skip_next, t.mediaNext, 'next'),
        _mediaButton(Icons.volume_up, t.mediaVolumeUp, 'volume_up'),
        // Separador: o que vem à direita não é uma tecla do computador, e sim
        // para onde o som vai.
        const SizedBox(
          height: 28,
          child: VerticalDivider(width: 18, color: Colors.white24),
        ),
        Tooltip(
          message: _audioOn ? t.audioOff : t.audioOn,
          child: IconButton(
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
            padding: EdgeInsets.zero,
            color: _audioOn ? auroraCyan : Colors.white,
            icon: Icon(_audioOn ? Icons.headphones : Icons.headset_off),
            onPressed: _toggleAudio,
          ),
        ),
      ],
    );
  }

  /// Liga ou desliga o som do computador no telefone.
  ///
  /// O som anda pela conexão direta que leva a tela; sem ela, não há por onde
  /// passar - e é melhor dizer isso do que ligar um botão que não faz som.
  Future<void> _toggleAudio() async {
    HapticFeedback.selectionClick();
    final t = widget.state.t;
    final messenger = ScaffoldMessenger.of(context);
    final ligar = !_audioOn;
    if (ligar && _video?.isLive != true) {
      // Três motivos diferentes, três saídas diferentes: desligado nas
      // configurações se resolve num toque, negociando é só esperar, e falha
      // é outra conversa. Uma frase só para os três não ajudava ninguém.
      final texto = _video == null
          ? t.audioNeedsVideoEnabled
          : (_video!.state == VideoState.negotiating
              ? t.audioWaitVideo
              : t.audioNeedsVideo);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(texto),
      ));
      return;
    }
    try {
      await widget.state.setAudio(widget.device, ligar);
      if (!mounted) return;
      setState(() => _audioOn = ligar);
      // A faixa de som não entra numa sessão já negociada: ligar o som refaz
      // a sessão de vídeo. É por isso que a imagem pisca aqui - e é o preço
      // de a oferta comum não carregar nada de áudio.
      if (ligar && _video?.withAudio != true) _connect();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }
    if (!ligar) return;
    // O pedido vai pelo servidor; a faixa de som vem pela conexão direta. Se
    // um dos lados estiver desatualizado, o pedido dá certo e a faixa nunca
    // chega — e sem este aviso o usuário fica com um botão aceso e silêncio.
    _audioCheck?.cancel();
    // 10 s porque ligar o som pode ter acabado de refazer a sessão de vídeo,
    // e uma negociação nova leva alguns segundos.
    _audioCheck = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_audioOn) return;
      if (_video?.audioLive == true) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(widget.state.t.audioNoTrack),
      ));
    });
  }

  Widget _mediaButton(
    IconData icon,
    String tooltip,
    String action, {
    bool big = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        // Toque generoso: são botões que se aperta sem olhar.
        iconSize: big ? 34 : 26,
        constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
        padding: EdgeInsets.zero,
        color: Colors.white,
        icon: Icon(icon),
        onPressed: () => _media(action),
      ),
    );
  }

  /// Seta de deslocamento posicionada numa borda (só no modo lupa).
  Widget _panArrow(Alignment alignment, IconData icon, VoidCallback onTap) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: IconButton(
            iconSize: 32,
            icon: Icon(icon, color: Colors.white),
            onPressed: onTap,
          ),
        ),
      ),
    );
  }

  /// Alterna entre "aguardando" e a tela ao vivo com um fade suave. As chaves
  /// são estáveis, então a animação ocorre só na troca de estado — não a cada
  /// frame recebido.
  Widget _liveView() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: !_hasFrame
          ? _waitingView(const ValueKey('waiting'))
          : _screenView(const ValueKey('live')),
    );
  }

  Widget _waitingView(Key key) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          _error ?? widget.state.t.waitingScreen,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }

  Widget _screenView(Key key) {
    return Center(
      key: key,
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: Container(
          // Borda visível delimitando a tela do computador (A1).
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final box = Size(constraints.maxWidth, constraints.maxHeight);
              _viewBox = box;
              // A imagem é a única folha que troca: vídeo por WebRTC quando ele
              // está ao vivo, JPEG no resto do tempo. Tudo em volta (zoom,
              // gestos, dock, mapeamento do cursor) fica igual nos dois casos —
              // é por isso que a substituição acontece só aqui.
              final video = _video;
              final Widget image = video != null && video.isLive
                  ? RTCVideoView(
                      video.renderer,
                      // `contain`, e não `cover`: o AspectRatio acima já usa a
                      // proporção do próprio vídeo, então as duas coincidem e a
                      // imagem preenche a caixa exatamente. Se houver
                      // descasamento momentâneo (antes de o tamanho do vídeo ser
                      // conhecido), `contain` mostra o quadro inteiro em vez de
                      // cortar — cortar esconderia parte da área de trabalho e
                      // faria o toque apontar para pixels invisíveis.
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      filterQuality: FilterQuality.medium,
                    )
                  : ValueListenableBuilder<ui.Image?>(
                      // Só esta folha se reconstrói quando chega um frame novo.
                      valueListenable: _frame,
                      builder: (context, frame, _) {
                        if (frame == null) return const SizedBox.expand();
                        return RawImage(
                          image: frame,
                          fit: BoxFit.fill,
                          // Suaviza quando ampliada (menos "quadradinhos").
                          filterQuality: FilterQuality.medium,
                        );
                      },
                    );

              // Modo lupa: o InteractiveViewer amplia/move (pinça e botões +/−),
              // e as setas nas bordas deslocam a visão sem precisar arrastar.
              if (_zoomMode) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: 1.0,
                        maxScale: 5.0,
                        child: image,
                      ),
                    ),
                    _panArrow(Alignment.centerLeft, Icons.chevron_left,
                        () => _pan(0.30, 0)),
                    _panArrow(Alignment.centerRight, Icons.chevron_right,
                        () => _pan(-0.30, 0)),
                    _panArrow(Alignment.topCenter, Icons.expand_less,
                        () => _pan(0, 0.30)),
                    _panArrow(Alignment.bottomCenter, Icons.expand_more,
                        () => _pan(0, -0.30)),
                  ],
                );
              }

              // Modo controle: aplica a mesma transformação de forma estática
              // (Transform) e deixa o GestureDetector receber os toques. Como o
              // detector fica DENTRO do Transform, o toque chega em coordenadas
              // da imagem — o zoom não distorce o mapeamento do cursor.
              // Escuta o controlador de zoom em vez de depender de um
              // `setState` da tela: fora do modo lupa nada mais redesenha.
              return ClipRect(
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _transform,
                  builder: (context, matrix, child) => Transform(
                    transform: matrix,
                    transformHitTests: true,
                    child: child,
                  ),
                  // A escuta do ponteiro envolve o detector de toque, e os
                  // dois compartilham o mesmo `box` - que é o da imagem, já
                  // dentro do `AspectRatio`. Duas consequências boas de graça:
                  // o mapeamento não sofre com as barras pretas, e o cursor só
                  // comanda o computador **enquanto está sobre o vídeo**. Fora
                  // dele, nenhum evento chega aqui e o iPad usa o cursor dele
                  // normalmente, que é o comportamento pedido.
                  child: Listener(
                    onPointerHover: (e) => _pontoMoveu(e, box),
                    onPointerDown: (e) => _pontoDesceu(e, box),
                    onPointerMove: (e) => _pontoArrastou(e, box),
                    onPointerUp: (e) => _pontoSubiu(e, box),
                    onPointerSignal: _pontoRolou,
                    child: GestureDetector(
                    // O mouse já foi tratado pela escuta acima; deixar o
                    // gesto seguir mandaria tudo em dobro.
                    onTapDown: (d) {
                      if (_gestoDeMouse) return;
                      _touchDown(d.localPosition, box);
                    },
                    onTapUp: (d) {
                      if (_gestoDeMouse) return;
                      _tapAt(d.localPosition, box);
                    },
                    // Sem `onTapCancel`: ele dispara assim que o dedo anda
                    // além do limiar de toque, que é exatamente o começo do
                    // arrasto de seleção. Quem solta o botão é o `onScaleEnd`,
                    // que vale para os dois desfechos.
                    onLongPressStart: (d) {
                      if (_gestoDeMouse) return;
                      _rightClickAt(d.localPosition, box);
                    },
                    onScaleStart: (d) {
                      if (_gestoDeMouse) return;
                      if (d.pointerCount < 2) _touchDown(d.localFocalPoint, box);
                    },
                    onScaleUpdate: (d) {
                      if (_gestoDeMouse) return;
                      if (d.pointerCount >= 2) {
                        _pendingScroll += d.focalPointDelta.dy;
                      } else {
                        // Com o botão segurado, mover é estender a seleção.
                        _moveTo(d.localFocalPoint, box);
                      }
                    },
                    onScaleEnd: (_) {
                      if (_gestoDeMouse) return;
                      _touchUp();
                    },
                    child: image,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    // Na vertical, o teclado aparece automaticamente (modo digitação); na
    // horizontal, é opcional (mais tela). Layout em Column: a barra de
    // controles e o teclado ficam FORA da imagem, sem cobri-la.
    //
    // Com teclado físico ligado, ele deixa de aparecer sozinho: quem está com
    // um teclado de verdade na frente não quer metade da tela ocupada pelo
    // desenho de outro. Continua a um toque de distância pelo botão da barra —
    // as teclas especiais dos perfis ainda são úteis.
    final showKeyboard =
        _tecladoFisico ? _keyboardVisible : (isPortrait || _keyboardVisible);
    // A dock continua flutuando sobre a imagem (é o comportamento de dock, e
    // ela é estreita); os painéis, não. Eles ocupam espaço próprio e empurram
    // a imagem, do mesmo jeito que o teclado — assim nada fica por cima da
    // tela do computador, que é o que a pessoa veio olhar.
    final Widget viewArea = LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);

        // Deitado, os dois docks ficam nas bordas laterais - e no celular eles
        // são estreitos o bastante para flutuar sem incomodar. Num iPad em
        // paisagem, não: eles passaram a cobrir justamente a tela do
        // computador, que é o que a pessoa veio olhar.
        //
        // A imagem recua o suficiente para eles caberem ao lado dela. Continuam
        // flutuando e arrastáveis como antes; o que muda é que agora flutuam
        // sobre margem, e não sobre conteúdo.
        //
        // Isto também é pré-requisito do ponteiro: o mouse mapeia para o
        // retângulo da imagem, e área de imagem escondida atrás de um dock
        // seria área onde apontar não corresponde a clicar.
        final margemDock = isPortrait
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: _dockThickness + 16);

        return Stack(
          // expand é essencial: sem ele o Stack se dimensiona pelo filho não
          // posicionado (a dock) e, quando ela está vazia, a tela inteira
          // encolheria para um ponto.
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: Padding(padding: margemDock, child: _liveView())),
            // No modo lupa a dock sai da frente, para não atrapalhar quem
            // está ampliando a imagem.
            if (!_zoomMode) _appDock(vertical: !isPortrait, area: area),
            // A barra de perfis mora na borda oposta à da dock (esquerda com o
            // celular deitado, topo em pé): as duas flutuam, e disputar a mesma
            // borda faria uma cobrir a outra.
            if (!_zoomMode && _profilesOpen)
              ProfileBar(
                vertical: !isPortrait,
                area: area,
                profiles: _perfis(),
                selected: _profile,
                appIcons: _profileIcons,
                automations: _automacoes(),
                // O mesmo caminho da tela de perfis, e de propósito: a mesma
                // confirmação para os passos destrutivos e o mesmo relatório
                // por passo. `emQual` poupa a pergunta de computador — aqui a
                // pessoa está olhando para um.
                onRunAutomation: (a) {
                  HapticFeedback.selectionClick();
                  runAutomationFlow(
                    context,
                    widget.state,
                    a,
                    emQual: widget.device.deviceId,
                  );
                },
                strings: widget.state.t,
                onSelect: _selectProfile,
                // Um toque deliberado e único, como o da sugestão do teclado:
                // se falhar, ficar calado faria parecer que o app ignorou.
                onAction: (a) {
                  HapticFeedback.selectionClick();
                  // Três naturezas na mesma barra: os perfis de fábrica mandam
                  // teclas, os do usuário abrem programas, e o brilho ajusta o
                  // sistema. Só os dois últimos precisam saber em qual
                  // computador estão.
                  if (a.isLaunch) {
                    _abrirPrograma(a);
                    return;
                  }
                  if (a.isBrightness) {
                    _ajustarBrilho(a.brightnessDelta!);
                    return;
                  }
                  if (a.isOpenAll) {
                    _abrirTodos();
                    return;
                  }
                  _send(a.input, avisarFalha: true);
                },
              ),
          ],
        );
      },
    );

    final Widget tela = Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(showToggle: !isPortrait || _tecladoFisico),
            // Deitado, as métricas viram uma coluna ao lado da imagem: a tela
            // é baixa e uma faixa horizontal comeria altura demais. Em pé, o
            // contrário — sobra altura, e a faixa fica no topo.
            if (isPortrait) _statsStrip(vertical: false),
            if (!isPortrait) _mediaStrip(atBottom: false),
            Expanded(
              child: isPortrait
                  ? viewArea
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _statsStrip(vertical: true),
                        Expanded(child: viewArea),
                      ],
                    ),
            ),
            if (isPortrait) _mediaStrip(atBottom: true),
            if (showKeyboard)
              RemoteKeyboard(
                onText: (text) => _send({'kind': 'key_text', 'text': text}),
                onKey: (key) => _send({'kind': 'key_press', 'key': key}),
                onCombo: (mods, key) =>
                    _send({'kind': 'key_combo', 'modifiers': mods, 'key': key}),
                onReplace: (backspaces, text) => _send(
                  {
                    'kind': 'key_replace',
                    'backspaces': backspaces,
                    'text': text,
                  },
                  avisarFalha: true,
                ),
                typed: _typedWord,
                suggester: widget.state.suggestionsEnabled
                    ? widget.state.wordSuggester
                    : null,
              ),
          ],
        ),
      ),
    );

    // O `Focus` envolve a tela inteira porque teclado não tem posição: a tecla
    // vale onde quer que o dedo esteja. `autofocus` para funcionar já na
    // abertura, sem exigir um toque antes da primeira letra.
    return Focus(
      focusNode: _foco,
      autofocus: true,
      onKeyEvent: _aoTeclar,
      child: tela,
    );
  }

  /// Botão da barra de cima que abre/fecha um painel. Aceso quando aberto —
  /// é o que diz de onde veio a faixa que apareceu.
  Widget _barToggle({
    required IconData icon,
    required bool open,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      // Compacto: a barra já carrega voltar, nome, indicador, lupa e teclado.
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: open ? auroraCyan : Colors.white),
      onPressed: onPressed,
    );
  }

  /// Folha da área de transferência.
  ///
  /// Duas direções que **não** são simétricas, e a assimetria não é escolha
  /// minha: o computador avisa sozinho quando alguém copia (o Windows tem um
  /// contador para isso), mas ler a área de transferência do iPhone mostra um
  /// aviso na tela toda vez - então essa direção é sempre a pedido, num toque.
  Future<void> _openClipboard() async {
    HapticFeedback.selectionClick();
    final t = widget.state.t;
    // Busca o que está no computador antes de abrir: a folha já nasce com a
    // informação, em vez de abrir vazia e piscar.
    String? lido;
    RemoteClipboard? conteudo;
    try {
      final atual = await widget.state.clipboard(widget.device);
      conteudo = atual;
      lido = atual.text;
      _pcClipboard = atual.text;
      _pcFiles = atual.files;
      _pcIgnored = atual.ignored;
    } catch (_) {
      // Sem rede ou agente antigo: mostra o último conhecido (ou nada).
    }
    // A imagem **não** fica guardada em `_pcImagem` como o texto: são
    // megabytes, e segurá-los na tela pelo resto da sessão custaria memória
    // por algo que a pessoa já viu. Vale só enquanto a folha está aberta.
    final imagem = conteudo;
    // `final` para o Dart poder promover o tipo dentro dos fechamentos abaixo
    // (com uma variável que ainda pode mudar, ele exige `!` em toda leitura).
    final doPc = lido ?? _pcClipboard;
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF14162C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            top: 18,
            // Sobe junto com o teclado do sistema, se ele aparecer.
            bottom: 18 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.clipboardTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(t.clipboardOnComputer,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (doPc == null || doPc.isEmpty) ? t.clipboardEmpty : doPc,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
              // A imagem copiada, quando há uma. Fica logo abaixo do texto
              // porque são as duas coisas que a pessoa "tem copiado agora";
              // os arquivos vêm depois, e são de outra natureza (caminhos).
              if (imagem != null && imagem.hasImage) ...[
                const SizedBox(height: 14),
                Text(
                  t.clipboardImage(imagem.imageWidth ?? 0, imagem.imageHeight ?? 0),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: double.infinity,
                    // Teto de altura: uma captura de tela em pé ocuparia a
                    // folha inteira e empurraria os botões para fora da vista.
                    constraints: const BoxConstraints(maxHeight: 220),
                    color: Colors.black26,
                    child: Image.memory(
                      imagem.image!,
                      fit: BoxFit.contain,
                      // Imagem ilegível não pode derrubar a folha: o texto e os
                      // arquivos continuam valendo.
                      errorBuilder: (_, __, ___) => Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          t.clipboardImageFailed,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Salvar em vez de colar: pôr uma imagem na área de
                // transferência do iOS exige um plugin nativo que este app não
                // tem. A folha de compartilhar resolve o mesmo problema por um
                // caminho que já existe - dali a imagem vai para Fotos, para o
                // WhatsApp ou para onde a pessoa quiser.
                OutlinedButton.icon(
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: Text(t.clipboardImageShare),
                  onPressed: () => _compartilharImagem(imagem),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(t.clipboardPull),
                      onPressed: (doPc == null || doPc.isEmpty)
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(text: doPc),
                              );
                              if (!sheetContext.mounted) return;
                              Navigator.of(sheetContext).pop();
                              _avisar(t.clipboardPulled);
                            },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.upload, size: 18),
                      label: Text(t.clipboardPush),
                      onPressed: () async {
                        // Lê a área de transferência do telefone só agora, no
                        // toque: é o que o iOS espera de um app bem-comportado.
                        final dados =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final texto = dados?.text ?? '';
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                        if (texto.isEmpty) {
                          _avisar(t.clipboardPhoneEmpty);
                          return;
                        }
                        try {
                          await widget.state
                              .setClipboard(widget.device, texto);
                          _pcClipboard = texto;
                          _avisar(t.clipboardPushed);
                        } catch (e) {
                          _avisar(e.toString());
                        }
                      },
                    ),
                  ),
                ],
              ),
              // Arquivos copiados: o Windows guarda o **caminho**, não os
              // bytes. Copiar um vídeo no Explorer e trazê-lo para cá é isto -
              // e quem busca por caminho é a transferência de arquivos.
              if (_pcFiles.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(t.clipboardFiles(_pcFiles.length),
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 190),
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final f in _pcFiles) _clipboardFileTile(f, t),
                      ],
                    ),
                  ),
                ),
              ],
              // Recusados: sem esta linha, quem copiou de `D:\` ou de uma
              // pasta de rede vê a mesma tela de quem não copiou nada, e não
              // tem como saber que o limite é a pasta do usuário.
              if (_pcIgnored > 0) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 15, color: Colors.white38),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        t.clipboardOutside(_pcIgnored),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(height: 28, color: Colors.white12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: widget.state.clipboardSync,
                title: Text(t.clipboardSync,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: Text(
                  t.clipboardSyncSub,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onChanged: (v) async {
                  try {
                    await widget.state.setClipboardSync(widget.device, v);
                    setSheet(() {});
                  } catch (e) {
                    _avisar(e.toString());
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Manda a imagem copiada no computador para a folha de compartilhar do iOS.
  ///
  /// **Não** é "colar no telefone", e a diferença é uma limitação real: pôr uma
  /// imagem na área de transferência do iOS exige um plugin nativo, porque o
  /// `Clipboard` do Flutter só trata texto. A folha de compartilhar chega ao
  /// mesmo lugar por um caminho que o app já usa para os arquivos — dali a
  /// imagem vai para Fotos, para uma conversa, para onde a pessoa quiser.
  ///
  /// Grava num arquivo temporário porque é isso que a folha aceita: ela
  /// compartilha arquivos, não bytes soltos na memória.
  Future<void> _compartilharImagem(RemoteClipboard c) async {
    final bytes = c.image;
    if (bytes == null) return;
    final t = widget.state.t;
    final origem = _shareOrigin();
    Navigator.of(context).pop();
    try {
      final dir = await getTemporaryDirectory();
      // Nome com a hora: duas imagens compartilhadas na mesma sessão não podem
      // sobrescrever uma à outra enquanto a primeira ainda está sendo enviada.
      final agora = DateTime.now().millisecondsSinceEpoch;
      final local = File('${dir.path}/deskside-$agora.${c.imageExtension}');
      await local.writeAsBytes(bytes);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(local.path, mimeType: c.imageMime)],
        sharePositionOrigin: origem,
      ));
    } catch (e) {
      _avisar('${t.clipboardImageFailed}: $e');
    }
  }

  /// Um arquivo copiado no computador, pronto para trazer.
  ///
  /// Pasta não dá para baixar (o download é de arquivo), e passar do teto de
  /// transferência também não — nos dois casos o botão fica apagado com o
  /// motivo à vista, em vez de falhar depois do toque.
  Widget _clipboardFileTile(RemoteFile file, Strings t) {
    final grande = file.size > _maxTransferBytes;
    final bloqueado = file.isDir || grande;
    final String detalhe;
    if (file.isDir) {
      detalhe = t.clipboardIsFolder;
    } else if (grande) {
      detalhe = t.clipboardTooBig;
    } else {
      detalhe = _formatBytes(file.size);
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        file.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
        color: bloqueado ? Colors.white24 : Colors.white70,
        size: 20,
      ),
      title: Text(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: bloqueado ? Colors.white38 : Colors.white,
          fontSize: 14,
        ),
      ),
      subtitle: Text(detalhe,
          style: TextStyle(
            color: grande ? Colors.orangeAccent : Colors.white38,
            fontSize: 11,
          )),
      trailing: IconButton(
        icon: const Icon(Icons.download, size: 20),
        color: auroraCyan,
        onPressed: bloqueado ? null : () => _bringFile(file),
      ),
    );
  }

  /// Teto da transferência de arquivos, o mesmo do agente e do backend.
  static const int _maxTransferBytes = 100 * 1024 * 1024;

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const unidades = ['KB', 'MB', 'GB'];
    var valor = bytes / 1024;
    var i = 0;
    while (valor >= 1024 && i < unidades.length - 1) {
      valor /= 1024;
      i++;
    }
    return '${valor.toStringAsFixed(valor >= 10 ? 0 : 1)} ${unidades[i]}';
  }

  /// Traz um arquivo copiado no computador e oferece à folha de compartilhar
  /// do iOS — é assim que se escolhe onde guardar sem pedir permissão nenhuma.
  Future<void> _bringFile(RemoteFile file) async {
    final t = widget.state.t;
    final origem = _shareOrigin();
    Navigator.of(context).pop();
    _avisar(t.clipboardBringing(file.name));
    try {
      final bytes = await widget.state.downloadFile(widget.device, file.path);
      final dir = await getTemporaryDirectory();
      final local = File('${dir.path}/${file.name}');
      await local.writeAsBytes(bytes);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(local.path)],
        title: file.name,
        sharePositionOrigin: origem,
      ));
    } catch (e) {
      _avisar('${t.fileDownloadFailed}: $e');
    }
  }

  /// De onde a folha de compartilhar do iPad deve sair. No iPhone é ignorado,
  /// mas no iPad sem isto o sistema não sabe onde ancorar e recusa.
  Rect _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return const Rect.fromLTWH(0, 0, 1, 1);
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 3),
      content: Text(texto),
    ));
  }

  /// Em que pé está a imagem, na barra de cima.
  ///
  /// Antes aqui só havia "N fps", e um número de quadros não distingue as três
  /// razões de o vídeo direto não estar de pé: desligado nas configurações,
  /// ainda negociando, ou falhou. Ficar sem essa distinção custou caro — "só
  /// fps" foi exatamente o relato que não dizia onde o caminho parou.
  Widget _videoStatus() {
    final t = widget.state.t;
    final video = _video;
    final String texto;
    Color cor = Colors.white38;
    VoidCallback? aoTocar;

    if (video == null) {
      // Nem tentou: o vídeo direto está desligado nas configurações.
      texto = t.videoDisabled;
      cor = Colors.orangeAccent;
    } else if (video.isLive) {
      texto = video.inputReady ? t.videoDirectMode : t.videoMode;
    } else if (video.state == VideoState.failed) {
      texto = t.videoFailedShort;
      cor = Colors.orangeAccent;
      // O motivo já apareceu uma vez, num aviso que passou. Aqui ele volta
      // quando a pessoa quiser, que é quando ela está tentando entender.
      aoTocar = () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 8),
            content: Text('${t.videoUnavailable}\n${video.error ?? ''}'.trim()),
          ));
    } else if (video.state == VideoState.negotiating) {
      texto = t.videoConnecting;
    } else {
      // 0 fps com a imagem no ar significa tela parada: o agente deixa de
      // enviar frames idênticos para poupar rede e bateria.
      texto = _fps == 0 && _hasFrame ? t.screenStill : '$_fps fps';
    }

    return GestureDetector(
      onTap: aoTocar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(texto, style: TextStyle(color: cor, fontSize: 12)),
      ),
    );
  }

  Widget _topBar({required bool showToggle}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      // Faixa escura com um leve brilho da marca, separando a barra da tela.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF14162C), Colors.black],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              widget.device.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_zoomMode) ...[
            IconButton(
              tooltip: widget.state.t.zoomOut,
              icon: const Icon(Icons.remove_circle_outline, color: Colors.white),
              onPressed: () => _zoomBy(1 / 1.4),
            ),
            IconButton(
              tooltip: widget.state.t.zoomIn,
              icon: const Icon(Icons.add_circle_outline, color: Colors.white),
              onPressed: () => _zoomBy(1.4),
            ),
            IconButton(
              tooltip: widget.state.t.zoomFit,
              icon: const Icon(Icons.fit_screen, color: Colors.white),
              onPressed: _resetZoom,
            ),
            IconButton(
              tooltip: widget.state.t.zoomExit,
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: _toggleZoomMode,
            ),
          ] else ...[
            _videoStatus(),
            // Os dois painéis retráteis moram aqui, na moldura do app: fora
            // da imagem do computador, que é o que a pessoa veio olhar.
            _barToggle(
              icon: Icons.memory,
              open: _statsOpen,
              tooltip: widget.state.t.systemPanel,
              onPressed: _toggleStats,
            ),
            _barToggle(
              icon: Icons.music_note,
              open: _mediaOpen,
              tooltip: widget.state.t.mediaPanel,
              onPressed: _toggleMedia,
            ),
            // A barra de perfis não é uma faixa: ela flutua, como a dock. Por
            // isso este botão só a mostra ou esconde — não empurra a imagem.
            _barToggle(
              icon: Icons.tune,
              open: _profilesOpen,
              tooltip: widget.state.t.profilesPanel,
              onPressed: _toggleProfiles,
            ),
            // Só aparece quando há mais de uma tela: um botão que abre uma
            // lista de um item só é ruído na barra.
            if (_monitors.length > 1)
              _barToggle(
                icon: Icons.desktop_windows,
                open: _selectedMonitor != null,
                tooltip: widget.state.t.monitorsTitle,
                onPressed: _openMonitors,
              ),
            // Área de transferência: abre uma folha, não uma faixa - é uma
            // visita curta, não algo para ficar na tela.
            _barToggle(
              icon: Icons.content_paste,
              open: widget.state.clipboardSync,
              tooltip: widget.state.t.clipboardTitle,
              onPressed: _openClipboard,
            ),
            IconButton(
              tooltip: widget.state.t.zoomEnter,
              icon: const Icon(Icons.zoom_in, color: Colors.white),
              onPressed: _toggleZoomMode,
            ),
            if (showToggle)
              IconButton(
                icon: Icon(
                  _keyboardVisible ? Icons.keyboard_hide : Icons.keyboard,
                  color: Colors.white,
                ),
                onPressed: () =>
                    setState(() => _keyboardVisible = !_keyboardVisible),
              ),
          ],
        ],
      ),
    );
  }
}
