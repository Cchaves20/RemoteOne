import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import 'control_profile.dart';
import 'window_zone.dart';

/// Um passo de automação: uma coisa que o computador faz, e quanto esperar
/// depois dela.
///
/// O conjunto do que uma automação pode fazer é exatamente o conjunto do que a
/// pessoa já podia fazer tocando nos botões — abrir um programa, fechar um
/// programa, mandar um atalho, mexer no som, no brilho e na energia. Isso não é
/// modéstia de escopo: é o que garante que cada passo tem um comportamento já
/// conhecido, testado e explicado em outro lugar do app.
///
/// `waitMs` é a pausa **depois** deste passo, e existe por um motivo concreto:
/// abrir um programa e mandar um atalho no instante seguinte não funciona — o
/// programa ainda não existe para receber a tecla.
class AutomationStep {
  const AutomationStep({
    required this.kind,
    this.waitMs,
    this.path,
    this.appName = '',
    this.zone,
    this.processName,
    this.action,
    this.level,
    this.delta,
  });

  /// Abrir um programa, opcionalmente numa zona da tela.
  AutomationStep.launch({
    required String appName,
    required String path,
    WindowZone? zone,
    int? waitMs,
  }) : this(
          kind: kindLaunch,
          appName: appName,
          path: path,
          zone: zone,
          // Um segundo e meio é o padrão porque abrir e posicionar é o passo
          // mais lento de todos, e um passo seguinte que chega cedo demais
          // erraria a janela. Editável: quem abre um editor pesado precisa de
          // mais, e quem só abre o bloco de notas não precisa de nada.
          waitMs: waitMs ?? 1500,
        );

  /// Fechar um programa pelo nome ("slack", "outlook").
  AutomationStep.close({required String processName, int? waitMs})
      : this(kind: kindClose, processName: processName, waitMs: waitMs);

  /// Mandar um atalho de teclado, no mesmo formato do teclado remoto.
  AutomationStep.input({required Map<String, dynamic> keys, int? waitMs})
      : this(kind: kindInput, action: keys, waitMs: waitMs);

  /// Uma tecla de mídia (volume, mudo, play).
  AutomationStep.media({required String action, int? waitMs})
      : this(kind: kindMedia, action: action, waitMs: waitMs);

  /// Pôr o brilho num valor. Absoluto, e não um passo: numa automação "brilho
  /// em 80%" tem um resultado previsível, e "+10%" depende de onde estava.
  AutomationStep.brightness({required int level, int? waitMs})
      : this(kind: kindBrightness, level: level, waitMs: waitMs);

  /// Desligar, reiniciar ou suspender.
  AutomationStep.power({required String action, int? waitMs})
      : this(kind: kindPower, action: action, waitMs: waitMs);

  // Os construtores nomeados acima **não** são `const`, de propósito. Dois
  // passos idênticos são um caso normal ("baixar o volume" duas vezes), e com
  // `const` o Dart os canonizaria no mesmo objeto: a lista arrastável do editor
  // usa `ObjectKey`, e duas chaves iguais na mesma lista derrubam a tela.
  static const kindLaunch = 'launch';
  static const kindClose = 'close';
  static const kindInput = 'input';
  static const kindMedia = 'media';
  static const kindBrightness = 'brightness';
  static const kindPower = 'power';

  final String kind;
  final int? waitMs;

  /// `launch`: o caminho do atalho no computador.
  final String? path;

  /// `launch`: o nome para mostrar. Não vai ao servidor — o passo guarda o
  /// caminho, que é o que o computador usa. Fica aqui para a lista do editor
  /// não virar uma coluna de caminhos do Windows.
  final String appName;

  final WindowZone? zone;

  /// `close`: o nome do processo.
  final String? processName;

  /// `input`: o mapa de teclas. `media`/`power`: o nome do comando.
  ///
  /// Um campo para dois formatos porque é assim que ele viaja: o servidor
  /// aceita `dict | str` no mesmo lugar, e separar aqui criaria dois campos que
  /// nunca aparecem juntos.
  final Object? action;

  final int? level;
  final int? delta;

  /// Se este passo é do tipo que não se desfaz sozinho.
  ///
  /// Fechar um programa pode perder o que não foi salvo; suspender ou desligar
  /// tira a máquina do ar. Nenhum dos dois tem "voltar atrás" a um toque de
  /// distância, e é por isso que a tela confirma antes de rodar.
  bool get isDestructive => kind == kindClose || kind == kindPower;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (waitMs != null) 'wait_ms': waitMs,
        if (path != null) 'id': path,
        if (zone != null) 'zone': zone!.toJson(),
        if (processName != null) 'name': processName,
        if (action != null) 'action': action,
        if (level != null) 'level': level,
        if (delta != null) 'delta': delta,
      };

  factory AutomationStep.fromJson(Map<String, dynamic> json) => AutomationStep(
        kind: (json['kind'] as String?) ?? kindMedia,
        waitMs: (json['wait_ms'] as num?)?.toInt(),
        path: json['id'] as String?,
        // O nome não viaja: é recomposto do caminho para a lista do editor
        // continuar legível depois de fechar e reabrir o app.
        appName: _nomeDoCaminho(json['id'] as String?),
        zone: json['zone'] == null
            ? null
            : WindowZone.fromJson(json['zone'] as Map<String, dynamic>),
        processName: json['name'] as String?,
        action: json['action'],
        level: (json['level'] as num?)?.toInt(),
        delta: (json['delta'] as num?)?.toInt(),
      );

  /// "C:\...\Microsoft Teams.lnk" → "Microsoft Teams".
  static String _nomeDoCaminho(String? caminho) {
    if (caminho == null || caminho.isEmpty) return '';
    final base = caminho.split(RegExp(r'[\\/]')).last;
    final ponto = base.lastIndexOf('.');
    return ponto > 0 ? base.substring(0, ponto) : base;
  }

  /// Como o passo se lê na lista do editor.
  String describe(Strings t) {
    switch (kind) {
      case kindLaunch:
        return t.stepLaunch(appName.isEmpty ? (path ?? '') : appName);
      case kindClose:
        return t.stepClose(processName ?? '');
      case kindBrightness:
        return t.stepBrightness(level ?? 0);
      case kindMedia:
        return t.mediaLabel(action as String? ?? '');
      case kindPower:
        // `powerLabel` já existe para os botões de energia da tela de
        // dispositivos, e é o mesmo conjunto de comandos: reaproveitar evita
        // dois textos para "suspender" que podem discordar na tradução.
        return t.powerLabel(action as String? ?? '');
      case kindInput:
        return t.stepKeys(_atalhoLegivel);
      default:
        return kind;
    }
  }

  /// "Ctrl+S" a partir do mapa de teclas, sem depender de um rótulo guardado.
  String get _atalhoLegivel {
    final mapa = action;
    if (mapa is! Map) return '';
    final tecla = (mapa['key'] ?? mapa['text'] ?? '').toString();
    final mods = ((mapa['modifiers'] as List?) ?? const [])
        .map((m) => m.toString())
        .toList();
    return [...mods, tecla].map(_capitalizar).join('+');
  }

  static String _capitalizar(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  IconData get icon {
    switch (kind) {
      case kindLaunch:
        return Icons.launch;
      case kindClose:
        return Icons.close;
      case kindBrightness:
        return Icons.brightness_6;
      case kindMedia:
        return Icons.volume_up;
      case kindPower:
        return Icons.power_settings_new;
      default:
        return Icons.keyboard;
    }
  }

  AutomationStep comEspera(int? ms) => AutomationStep(
        kind: kind,
        waitMs: ms,
        path: path,
        appName: appName,
        zone: zone,
        processName: processName,
        action: action,
        level: level,
        delta: delta,
      );

  AutomationStep comZona(WindowZone? nova) => AutomationStep(
        kind: kind,
        waitMs: waitMs,
        path: path,
        appName: appName,
        zone: nova,
        processName: processName,
        action: action,
        level: level,
        delta: delta,
      );

  /// As teclas de mídia que o computador aceita, na ordem do seletor.
  static const List<String> mediaActions = [
    'mute',
    'volume_down',
    'volume_up',
    'play_pause',
    'next',
    'previous',
  ];

  /// Os comandos de energia. `suspend` e não `sleep`: é o nome que o agente
  /// conhece, e escrever o outro faria o passo falhar só no computador.
  static const List<String> powerActions = ['suspend', 'shutdown', 'restart'];
}

/// O que aconteceu com um passo depois de rodar.
///
/// Identificado pelo **índice**, e não por um nome: dois passos podem ser
/// idênticos ("baixar o volume" duas vezes), e a tela precisa saber qual dos
/// dois falhou.
///
/// `error` também vem com `ok` verdadeiro: é onde cabe o aviso de que a janela
/// abriu mas não foi para o lugar pedido. Aviso não é falha.
class StepResult {
  const StepResult({required this.index, required this.ok, this.error});

  final int index;
  final bool ok;
  final String? error;

  factory StepResult.fromJson(Map<String, dynamic> json) => StepResult(
        index: (json['index'] as num?)?.toInt() ?? 0,
        ok: json['ok'] as bool? ?? false,
        error: json['error'] as String?,
      );
}

/// Uma automação: a sequência de passos que um toque executa.
///
/// Mora ao lado dos perfis, na mesma tela, e **não** dentro de um perfil. A
/// diferença entre as duas coisas cabe numa frase e aparece no uso: num perfil
/// a ordem não significa nada — são botões lado a lado, e você toca no que
/// quiser —, enquanto numa automação a ordem é o recurso inteiro.
class Automation {
  const Automation({
    required this.id,
    required this.name,
    this.icon = 'tune',
    this.steps = const [],
    this.deviceId = '',
  });

  /// Identificador gerado pelo servidor. Vazio numa automação ainda não salva.
  final String id;
  final String name;

  /// A chave do ícone, não o desenho. Mesma paleta dos perfis: o servidor
  /// guarda a chave porque o desenho é do app.
  final String icon;

  final List<AutomationStep> steps;

  /// Em qual computador ela roda. Vazio = pergunta na hora.
  ///
  /// Singular, ao contrário do perfil: um perfil é um punhado de atalhos que
  /// vale em várias máquinas, mas uma automação abre programas *daquele*
  /// computador e pode terminar suspendendo *aquela* máquina.
  final String deviceId;

  IconData get iconData => profileIcon(icon);

  /// Se algum passo é do tipo que não se desfaz sozinho — o que faz a tela
  /// confirmar antes de rodar.
  bool get hasDestructive => steps.any((s) => s.isDestructive);

  Map<String, dynamic> toJson() => {
        'name': name,
        'icon': icon,
        'steps': [for (final s in steps) s.toJson()],
        'device_id': deviceId,
      };

  factory Automation.fromJson(Map<String, dynamic> json) => Automation(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        icon: (json['icon'] as String?) ?? 'tune',
        steps: [
          for (final s in ((json['steps'] as List?) ?? const []))
            AutomationStep.fromJson(s as Map<String, dynamic>),
        ],
        deviceId: (json['device_id'] as String?) ?? '',
      );

  Automation copyWith({
    String? name,
    String? icon,
    List<AutomationStep>? steps,
    String? deviceId,
  }) =>
      Automation(
        id: id,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        steps: steps ?? this.steps,
        deviceId: deviceId ?? this.deviceId,
      );
}
