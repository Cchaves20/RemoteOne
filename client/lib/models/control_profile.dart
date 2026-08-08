// `Icons` mora no material (o widgets.dart só traz o `IconData`).
import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// Um botão de perfil: o atalho que ele dispara no computador.
///
/// São três construtores porque o computador aceita três formas diferentes de
/// tecla, e escolher a errada falha **em silêncio**: `key_press` só entende
/// teclas com nome próprio (Esc, F5, setas), uma letra avulsa precisa ir como
/// texto digitado, e o resto é atalho com modificador. Deixar isso explícito no
/// construtor é o que impede um perfil novo de nascer quebrado.
class ProfileAction {
  const ProfileAction._({
    required this.icon,
    required this.shortcut,
    required this.label,
    this.modifiers = const [],
    this.key,
    this.text,
    this.appPath,
    this.appName = '',
    this.brightnessDelta,
  });

  /// Atalho com modificadores: `Ctrl+S`, `Alt+Tab`, `Win+E`.
  const ProfileAction.combo({
    required IconData icon,
    required String shortcut,
    required String Function(Strings) label,
    required List<String> modifiers,
    required String key,
  }) : this._(
          icon: icon,
          shortcut: shortcut,
          label: label,
          modifiers: modifiers,
          key: key,
        );

  /// Tecla com nome próprio, sem modificador: Espaço, Esc, F5, setas.
  const ProfileAction.special({
    required IconData icon,
    required String shortcut,
    required String Function(Strings) label,
    required String key,
  }) : this._(icon: icon, shortcut: shortcut, label: label, key: key);

  /// Uma letra solta (o `f` de tela cheia, o `m` de mudo). Vai como texto: o
  /// computador só aceita nome de tecla em `key_press`, e "f" não é um nome.
  const ProfileAction.letter({
    required IconData icon,
    required String shortcut,
    required String Function(Strings) label,
    required String text,
  }) : this._(icon: icon, shortcut: shortcut, label: label, text: text);

  /// Ajustar o brilho da tela do computador, em passos.
  ///
  /// Mora na barra de perfis porque ela é a área de atalhos — e brilho é
  /// exatamente isso: um ajuste de um toque, no meio de outra coisa. Não é
  /// tecla nem programa; é o **terceiro** tipo de ação, e por isso não tem
  /// `input`: quem trata é a tela, que sabe em qual computador ajustar.
  ///
  /// Passo relativo, e não um controle deslizante: um deslizante numa barra de
  /// ícones de 42 px não teria onde caber, e cada arrasto viraria dezenas de
  /// pedidos ao computador.
  const ProfileAction.brightness({
    required IconData icon,
    required String shortcut,
    required String Function(Strings) label,
    required int delta,
  }) : this._(
          icon: icon,
          shortcut: shortcut,
          label: label,
          brightnessDelta: delta,
        );

  /// Abrir um programa no computador.
  ///
  /// É o quarto tipo, e o único que **não é tecla**: o computador recebe um
  /// pedido de "abra isto", não um evento de teclado. Por isso `input` não
  /// serve aqui — quem trata é a tela, que sabe em qual computador abrir.
  ///
  /// `appPath` é o caminho de onde o programa foi escolhido. Pode não existir
  /// em outro computador do mesmo perfil; o agente então procura pelo nome.
  ProfileAction.launch({required String appName, required String appPath})
      : this._(
          icon: Icons.launch,
          // O nome do programa é o nome do programa em qualquer país: não
          // passa pelo sistema de idiomas.
          shortcut: appName,
          label: _fixo(appName),
          appName: appName,
          appPath: appPath,
        );

  static String Function(Strings) _fixo(String valor) => (_) => valor;

  final IconData icon;

  /// Como o atalho se escreve ("Ctrl+S"). Fora do sistema de idiomas de
  /// propósito: as teclas do teclado físico dizem Ctrl, Alt, Esc e Tab em
  /// qualquer país, então traduzir aqui afastaria o texto do que está impresso.
  final String shortcut;

  final String Function(Strings) label;
  final List<String> modifiers;
  final String? key;
  final String? text;

  /// Caminho do programa a abrir. `null` em toda ação de teclado — é este
  /// campo que separa os dois mundos.
  final String? appPath;

  /// Nome do programa. Vazio nas ações de teclado.
  final String appName;

  /// Quanto somar ao brilho. `null` em toda ação que não é de brilho.
  final int? brightnessDelta;

  /// Se esta ação abre um programa em vez de mandar teclas.
  bool get isLaunch => appPath != null;

  /// Se esta ação ajusta o brilho em vez de mandar teclas.
  bool get isBrightness => brightnessDelta != null;

  /// A mensagem que vai para o computador, no mesmo formato do teclado remoto.
  Map<String, dynamic> get input {
    final letra = text;
    if (letra != null) return {'kind': 'key_text', 'text': letra};
    if (modifiers.isEmpty) return {'kind': 'key_press', 'key': key};
    return {'kind': 'key_combo', 'modifiers': modifiers, 'key': key};
  }
}

/// Os ícones que um perfil criado pode ter.
///
/// Uma paleta fechada, e não um ícone qualquer: o servidor guarda só a
/// **chave**, porque o desenho é do app — que sabe o tema, a densidade da tela
/// e como o ícone se comporta em cima da imagem do computador. Guardar o
/// desenho amarraria o dado à versão do app que o criou.
const Map<String, IconData> profileIcons = {
  'tune': Icons.tune,
  'movie': Icons.movie,
  'music_note': Icons.music_note,
  'language': Icons.language,
  'work': Icons.work,
  'slideshow': Icons.slideshow,
  'sports_esports': Icons.sports_esports,
  'chat': Icons.chat_bubble,
  'photo': Icons.photo_camera,
  'code': Icons.code,
  'shopping': Icons.shopping_cart,
  'school': Icons.school,
  'home': Icons.home,
  'favorite': Icons.favorite,
};

/// O desenho de uma chave. Chave desconhecida (guardada por uma versão mais
/// nova do app) cai no genérico em vez de sumir.
IconData profileIcon(String? key) => profileIcons[key] ?? Icons.tune;

/// A chave de um desenho, para guardar no servidor.
String profileIconKey(IconData icon) {
  for (final e in profileIcons.entries) {
    if (e.value == icon) return e.key;
  }
  return 'tune';
}

/// Um perfil de controle: o punhado de atalhos que serve para um jeito de usar
/// o computador (assistir um filme, navegar, escrever, apresentar).
///
/// Os cinco que vêm prontos são fixos, e isso é uma escolha: o valor está em
/// ter algo útil no primeiro toque, sem ninguém precisar montar uma lista de
/// atalhos antes de o app servir para alguma coisa. Por cima deles o usuário
/// monta os seus, que abrem programas em vez de mandar teclas — e esses vivem
/// no servidor, porque a conta é usada em mais de um aparelho.
class ControlProfile {
  const ControlProfile({
    required this.id,
    required this.icon,
    required this.name,
    required this.actions,
    this.executables = const [],
    this.devices = const [],
    this.custom = false,
    this.rawName = '',
  });

  /// Um perfil montado pelo usuário, como o servidor o entrega.
  ///
  /// Cada programa vira um botão. Um perfil sem programa nenhum é legítimo —
  /// alguém que criou e ainda não escolheu nada —, e aparece vazio em vez de
  /// sumir sem explicação.
  factory ControlProfile.fromJson(Map<String, dynamic> json) {
    final apps = (json['apps'] as List?) ?? const [];
    return ControlProfile(
      id: json['id'] as String,
      icon: profileIcon(json['icon'] as String?),
      name: _fixed((json['name'] as String?) ?? ''),
      rawName: (json['name'] as String?) ?? '',
      custom: true,
      devices: ((json['devices'] as List?) ?? const [])
          .map((e) => e as String)
          .toList(),
      actions: [
        for (final a in apps.cast<Map<String, dynamic>>())
          ProfileAction.launch(
            appName: (a['name'] as String?) ?? '',
            appPath: (a['path'] as String?) ?? '',
          ),
      ],
    );
  }

  /// Nome que o usuário escreveu: não passa pelo sistema de idiomas.
  static String Function(Strings) _fixed(String valor) => (_) => valor;

  /// Como o perfil aparece no servidor. O `id` fica de fora: quem o define é
  /// o servidor, e ele nunca muda.
  Map<String, dynamic> toJson() => {
        'name': rawName,
        'icon': profileIconKey(icon),
        'apps': [
          for (final a in actions)
            {'name': a.appName, 'path': a.appPath ?? ''},
        ],
        'devices': devices,
      };

  /// Identificador guardado no disco. Nunca traduzido — o nome muda com o
  /// idioma, o `id` não pode mudar, senão o perfil escolhido se perderia ao
  /// trocar de idioma.
  final String id;
  final IconData icon;
  final String Function(Strings) name;
  final List<ProfileAction> actions;

  /// Executáveis que este perfil atende, em minúsculas e com extensão.
  ///
  /// É por esta lista que o ícone do perfil vira o ícone do programa de
  /// verdade: com o PowerPoint na frente, o perfil de apresentação passa a
  /// mostrar o ícone do PowerPoint. A comparação é pelo executável, e não pelo
  /// nome, porque o nome muda com o idioma do Windows.
  final List<String> executables;

  /// Computadores em que este perfil aparece. Vazio = todos.
  ///
  /// Só os criados pelo usuário usam isto: os de fábrica são atalhos de
  /// teclado, que valem em qualquer Windows.
  final List<String> devices;

  /// Se veio do servidor (foi montado pelo usuário) em vez de vir no app.
  final bool custom;

  /// O nome como o usuário o escreveu. Vazio nos perfis de fábrica, cujo nome
  /// é função do idioma — e por isso não existe fora de um idioma.
  final String rawName;

  bool matches(String exe) => executables.contains(exe.toLowerCase());

  /// Se este perfil deve aparecer ao controlar um computador.
  bool appliesTo(String deviceId) => devices.isEmpty || devices.contains(deviceId);

  /// O perfil ao qual um programa pertence, se algum.
  static ControlProfile? forExecutable(String exe) {
    for (final p in builtIn) {
      if (p.matches(exe)) return p;
    }
    return null;
  }

  static ControlProfile? byId(String? id, [List<ControlProfile>? entre]) {
    if (id == null) return null;
    for (final p in entre ?? builtIn) {
      if (p.id == id) return p;
    }
    // Perfil removido (numa versão nova, ou pelo próprio usuário): melhor
    // abrir sem perfil do que quebrar.
    return null;
  }

  /// Os perfis que valem para um computador, na ordem escolhida.
  ///
  /// `ordem` traz a fila inteira que o usuário arrastou, de fábrica e criados
  /// misturados. O que ela não menciona vai para o fim, na ordem natural: é o
  /// que faz um perfil novo (criado noutro aparelho, ou trazido por uma versão
  /// nova do app) aparecer em vez de sumir por não estar na lista.
  ///
  /// `deviceId` nulo não filtra nada. É o que o editor usa: lá se arruma a
  /// coleção inteira, e esconder um perfil porque ele não vale para a máquina
  /// atual faria a pessoa achar que ele sumiu.
  static List<ControlProfile> arrange(
    List<ControlProfile> custom,
    List<String> ordem, [
    String? deviceId,
  ]) {
    final todos = [...builtIn, ...custom]
        .where((p) => deviceId == null || p.appliesTo(deviceId))
        .toList();
    final porId = {for (final p in todos) p.id: p};
    final saida = <ControlProfile>[];
    for (final id in ordem) {
      final p = porId.remove(id);
      if (p != null) saida.add(p);
    }
    // `todos` e não `porId.values`: preserva a ordem natural dos que sobraram.
    saida.addAll(todos.where((p) => porId.containsKey(p.id)));
    return saida;
  }

  /// Os perfis que vêm com o app.
  ///
  /// `final` e não `const` porque cada rótulo é uma função do idioma, e uma
  /// função escrita na hora não é constante em Dart. A lista é criada uma vez.
  static final List<ControlProfile> builtIn = [
    ControlProfile(
      id: 'sistema',
      executables: [
        'explorer.exe',
        'taskmgr.exe',
        'cmd.exe',
        'powershell.exe',
        'pwsh.exe',
        'windowsterminal.exe',
        'control.exe',
        'systemsettings.exe',
      ],
      icon: Icons.desktop_windows,
      name: (t) => t.profileSystem,
      actions: [
        ProfileAction.combo(
          icon: Icons.swap_horiz,
          shortcut: 'Alt+Tab',
          label: (t) => t.actionSwitchWindow,
          modifiers: ['alt'],
          key: 'tab',
        ),
        ProfileAction.combo(
          icon: Icons.wallpaper,
          shortcut: 'Win+D',
          label: (t) => t.actionShowDesktop,
          modifiers: ['meta'],
          key: 'd',
        ),
        ProfileAction.combo(
          icon: Icons.folder,
          shortcut: 'Win+E',
          label: (t) => t.actionFileExplorer,
          modifiers: ['meta'],
          key: 'e',
        ),
        ProfileAction.combo(
          icon: Icons.monitor_heart,
          shortcut: 'Ctrl+Shift+Esc',
          label: (t) => t.actionTaskManager,
          modifiers: ['ctrl', 'shift'],
          key: 'escape',
        ),
        ProfileAction.combo(
          icon: Icons.align_horizontal_left,
          shortcut: 'Win+Left',
          label: (t) => t.actionSnapLeft,
          modifiers: ['meta'],
          key: 'left',
        ),
        ProfileAction.combo(
          icon: Icons.align_horizontal_right,
          shortcut: 'Win+Right',
          label: (t) => t.actionSnapRight,
          modifiers: ['meta'],
          key: 'right',
        ),
        ProfileAction.combo(
          icon: Icons.close,
          shortcut: 'Alt+F4',
          label: (t) => t.actionCloseWindow,
          modifiers: ['alt'],
          key: 'f4',
        ),
        // Brilho fecha o par que o documento do projeto pede junto com o
        // volume ("controle de recursos do sistema"). O volume já mora na
        // faixa de mídia; o brilho vem para cá, que é a área de atalhos.
        //
        // Passos de 10: cinco toques atravessam a faixa inteira, e é grosso o
        // bastante para a diferença ser visível num toque só.
        ProfileAction.brightness(
          icon: Icons.brightness_low,
          shortcut: '−10%',
          label: (t) => t.actionBrightnessDown,
          delta: -10,
        ),
        ProfileAction.brightness(
          icon: Icons.brightness_high,
          shortcut: '+10%',
          label: (t) => t.actionBrightnessUp,
          delta: 10,
        ),
      ],
    ),
    ControlProfile(
      id: 'video',
      executables: [
        // Tocadores e serviços de música/vídeo mais comuns no Windows. O
        // Apple Music da Microsoft Store se chama AppleMusic.exe; o iTunes
        // antigo continua por aí.
        'applemusic.exe',
        'itunes.exe',
        'spotify.exe',
        'vlc.exe',
        'mpc-hc64.exe',
        'mpv.exe',
        'potplayermini64.exe',
        'wmplayer.exe',
        'music.ui.exe',
        'video.ui.exe',
        'netflix.exe',
      ],
      icon: Icons.movie,
      name: (t) => t.profileVideo,
      actions: [
        ProfileAction.special(
          icon: Icons.play_arrow,
          shortcut: 'Space',
          label: (t) => t.mediaPlayPause,
          key: 'space',
        ),
        ProfileAction.special(
          icon: Icons.fast_rewind,
          shortcut: 'Left',
          label: (t) => t.actionRewind,
          key: 'left',
        ),
        ProfileAction.special(
          icon: Icons.fast_forward,
          shortcut: 'Right',
          label: (t) => t.actionForward,
          key: 'right',
        ),
        ProfileAction.letter(
          icon: Icons.fullscreen,
          shortcut: 'F',
          label: (t) => t.actionFullscreen,
          text: 'f',
        ),
        ProfileAction.letter(
          icon: Icons.volume_off,
          shortcut: 'M',
          label: (t) => t.mediaMute,
          text: 'm',
        ),
        ProfileAction.special(
          icon: Icons.fullscreen_exit,
          shortcut: 'Esc',
          label: (t) => t.actionExitFullscreen,
          key: 'escape',
        ),
      ],
    ),
    ControlProfile(
      id: 'navegador',
      executables: [
        'chrome.exe',
        'msedge.exe',
        'firefox.exe',
        'opera.exe',
        'brave.exe',
        'vivaldi.exe',
      ],
      icon: Icons.public,
      name: (t) => t.profileBrowser,
      actions: [
        ProfileAction.combo(
          icon: Icons.add,
          shortcut: 'Ctrl+T',
          label: (t) => t.actionNewTab,
          modifiers: ['ctrl'],
          key: 't',
        ),
        ProfileAction.combo(
          icon: Icons.close,
          shortcut: 'Ctrl+W',
          label: (t) => t.actionCloseTab,
          modifiers: ['ctrl'],
          key: 'w',
        ),
        ProfileAction.combo(
          icon: Icons.restore,
          shortcut: 'Ctrl+Shift+T',
          label: (t) => t.actionReopenTab,
          modifiers: ['ctrl', 'shift'],
          key: 't',
        ),
        ProfileAction.combo(
          icon: Icons.arrow_back,
          shortcut: 'Alt+Left',
          label: (t) => t.actionPageBack,
          modifiers: ['alt'],
          key: 'left',
        ),
        ProfileAction.combo(
          icon: Icons.arrow_forward,
          shortcut: 'Alt+Right',
          label: (t) => t.actionPageForward,
          modifiers: ['alt'],
          key: 'right',
        ),
        ProfileAction.special(
          icon: Icons.refresh,
          shortcut: 'F5',
          label: (t) => t.actionReload,
          key: 'f5',
        ),
        ProfileAction.combo(
          icon: Icons.link,
          shortcut: 'Ctrl+L',
          label: (t) => t.actionAddressBar,
          modifiers: ['ctrl'],
          key: 'l',
        ),
      ],
    ),
    ControlProfile(
      id: 'trabalho',
      executables: [
        'winword.exe',
        'excel.exe',
        'onenote.exe',
        'notepad.exe',
        'wordpad.exe',
        'notepad++.exe',
        'code.exe',
        'acrobat.exe',
        'acrord32.exe',
        'soffice.bin',
        'swriter.exe',
      ],
      icon: Icons.description,
      name: (t) => t.profileWork,
      actions: [
        ProfileAction.combo(
          icon: Icons.save,
          shortcut: 'Ctrl+S',
          label: (t) => t.save,
          modifiers: ['ctrl'],
          key: 's',
        ),
        ProfileAction.combo(
          icon: Icons.undo,
          shortcut: 'Ctrl+Z',
          label: (t) => t.actionUndo,
          modifiers: ['ctrl'],
          key: 'z',
        ),
        ProfileAction.combo(
          icon: Icons.redo,
          shortcut: 'Ctrl+Y',
          label: (t) => t.actionRedo,
          modifiers: ['ctrl'],
          key: 'y',
        ),
        ProfileAction.combo(
          icon: Icons.copy,
          shortcut: 'Ctrl+C',
          label: (t) => t.actionCopy,
          modifiers: ['ctrl'],
          key: 'c',
        ),
        ProfileAction.combo(
          icon: Icons.paste,
          shortcut: 'Ctrl+V',
          label: (t) => t.actionPaste,
          modifiers: ['ctrl'],
          key: 'v',
        ),
        ProfileAction.combo(
          icon: Icons.search,
          shortcut: 'Ctrl+F',
          label: (t) => t.actionFind,
          modifiers: ['ctrl'],
          key: 'f',
        ),
        ProfileAction.combo(
          icon: Icons.print,
          shortcut: 'Ctrl+P',
          label: (t) => t.actionPrint,
          modifiers: ['ctrl'],
          key: 'p',
        ),
      ],
    ),
    ControlProfile(
      id: 'apresentacao',
      executables: [
        'powerpnt.exe',
        'simpress.exe',
        'prezi.exe',
      ],
      icon: Icons.slideshow,
      name: (t) => t.profileSlides,
      actions: [
        ProfileAction.special(
          icon: Icons.play_arrow,
          shortcut: 'F5',
          label: (t) => t.actionStartSlides,
          key: 'f5',
        ),
        ProfileAction.special(
          icon: Icons.arrow_back,
          shortcut: 'Left',
          label: (t) => t.actionPreviousSlide,
          key: 'left',
        ),
        ProfileAction.special(
          icon: Icons.arrow_forward,
          shortcut: 'Right',
          label: (t) => t.actionNextSlide,
          key: 'right',
        ),
        ProfileAction.letter(
          icon: Icons.dark_mode,
          shortcut: 'B',
          label: (t) => t.actionBlackScreen,
          text: 'b',
        ),
        ProfileAction.special(
          icon: Icons.close,
          shortcut: 'Esc',
          label: (t) => t.actionExitSlides,
          key: 'escape',
        ),
      ],
    ),
  ];
}
