import '../l10n/strings.dart';

/// Um atalho da linha acima do teclado: o rótulo, o que se aperta e como se
/// escreve na tecla ("Ctrl S").
class AtalhoDoPrograma {
  const AtalhoDoPrograma(this.rotulo, this.modificadores, this.tecla);

  final String rotulo;
  final List<String> modificadores;
  final String tecla;

  /// "Ctrl S", "Ctrl Shift N", "Alt ←": o que aparece na tecla, em fonte
  /// monoespaçada.
  String get combinacao {
    final mods = modificadores
        .map((m) => switch (m) {
              'ctrl' => 'Ctrl',
              'alt' => 'Alt',
              'shift' => 'Shift',
              'meta' => '⌘',
              _ => m,
            })
        .join(' ');
    final t = switch (tecla) {
      'left' => '←',
      'f2' => 'F2',
      _ => tecla.toUpperCase(),
    };
    return mods.isEmpty ? t : '$mods $t';
  }
}

/// Os atalhos que mudam com o programa em primeiro plano.
///
/// Pelo nome do executável (o mesmo que escolhe o perfil automático). Os
/// programas que mais aparecem ganham os seus; os outros, os de sempre
/// (copiar, colar, desfazer, selecionar tudo), que valem em qualquer lugar.
///
/// [mac] troca Ctrl por ⌘: no Mac, Ctrl+C não copia.
List<AtalhoDoPrograma> atalhosPara(Strings t, String? exe, {bool mac = false}) {
  final ctrl = mac ? 'meta' : 'ctrl';
  final nome = (exe ?? '').toLowerCase();
  bool eh(List<String> nomes) => nomes.any(nome.contains);

  if (eh(['code', 'cursor', 'codium'])) {
    return [
      AtalhoDoPrograma(t.atalhoSalvar, [ctrl], 's'),
      AtalhoDoPrograma(t.atalhoAbrirArquivo, [ctrl], 'p'),
      AtalhoDoPrograma(t.atalhoTerminal, [ctrl], '`'),
      AtalhoDoPrograma(t.atalhoComentar, [ctrl], '/'),
    ];
  }
  if (eh(['chrome', 'msedge', 'firefox', 'brave', 'opera', 'safari', 'vivaldi'])) {
    return [
      AtalhoDoPrograma(t.atalhoNovaAba, [ctrl], 't'),
      AtalhoDoPrograma(t.atalhoFecharAba, [ctrl], 'w'),
      AtalhoDoPrograma(t.atalhoEndereco, [ctrl], 'l'),
      AtalhoDoPrograma(t.atalhoVoltar, [mac ? 'meta' : 'alt'], 'left'),
    ];
  }
  if (eh(['explorer', 'finder', 'nautilus', 'dolphin'])) {
    return [
      AtalhoDoPrograma(t.atalhoRenomear, const [], 'f2'),
      AtalhoDoPrograma(t.atalhoNovaPasta, [ctrl, 'shift'], 'n'),
      AtalhoDoPrograma(t.atalhoCopiar, [ctrl], 'c'),
      AtalhoDoPrograma(t.atalhoColar, [ctrl], 'v'),
    ];
  }
  return [
    AtalhoDoPrograma(t.atalhoCopiar, [ctrl], 'c'),
    AtalhoDoPrograma(t.atalhoColar, [ctrl], 'v'),
    AtalhoDoPrograma(t.atalhoDesfazer, [ctrl], 'z'),
    AtalhoDoPrograma(t.atalhoTudo, [ctrl], 'a'),
  ];
}

/// O nome do programa, para o rótulo da linha ("VS Code"), a partir do
/// executável. Nulo quando não há um nome curto conhecido.
String? nomeCurtoDoPrograma(String? exe) {
  final nome = (exe ?? '').toLowerCase();
  if (nome.isEmpty) return null;
  const conhecidos = {
    'code': 'VS Code',
    'cursor': 'Cursor',
    'chrome': 'Chrome',
    'msedge': 'Edge',
    'firefox': 'Firefox',
    'brave': 'Brave',
    'safari': 'Safari',
    'explorer': 'Explorer',
    'finder': 'Finder',
  };
  for (final e in conhecidos.entries) {
    if (nome.contains(e.key)) return e.value;
  }
  return null;
}
