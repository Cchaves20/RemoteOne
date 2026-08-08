/// Onde a janela de um programa fica quando se abre todos de uma vez.
///
/// **Células de uma grade, e não frações.** Três colunas em frações seriam
/// 0,333 cada, e três vezes 0,333 não fecha 1: sobraria uma fresta de um ou
/// dois pixels entre as janelas, ou elas se sobreporiam. Com a grade, a borda
/// direita de uma zona sai da mesma conta que a borda esquerda da seguinte, e o
/// encaixe é exato — quem faz essa conta é o agente, em pixels da tela.
class WindowZone {
  const WindowZone({
    required this.cols,
    required this.rows,
    required this.col,
    required this.row,
    this.colspan = 1,
    this.rowspan = 1,
  });

  /// O tamanho da grade. Viaja **dentro** de cada zona, e não no perfil, para o
  /// layout escolhido ser dedutível do que está guardado — um campo separado
  /// poderia discordar das zonas e ninguém saberia qual acreditar.
  final int cols;
  final int rows;

  final int col;
  final int row;
  final int colspan;
  final int rowspan;

  bool get isValid =>
      cols > 0 &&
      rows > 0 &&
      colspan > 0 &&
      rowspan > 0 &&
      col + colspan <= cols &&
      row + rowspan <= rows;

  Map<String, dynamic> toJson() => {
        'cols': cols,
        'rows': rows,
        'col': col,
        'row': row,
        'colspan': colspan,
        'rowspan': rowspan,
      };

  factory WindowZone.fromJson(Map<String, dynamic> json) => WindowZone(
        cols: (json['cols'] as num?)?.toInt() ?? 1,
        rows: (json['rows'] as num?)?.toInt() ?? 1,
        col: (json['col'] as num?)?.toInt() ?? 0,
        row: (json['row'] as num?)?.toInt() ?? 0,
        colspan: (json['colspan'] as num?)?.toInt() ?? 1,
        rowspan: (json['rowspan'] as num?)?.toInt() ?? 1,
      );

  @override
  bool operator ==(Object other) =>
      other is WindowZone &&
      other.cols == cols &&
      other.rows == rows &&
      other.col == col &&
      other.row == row &&
      other.colspan == colspan &&
      other.rowspan == rowspan;

  @override
  int get hashCode => Object.hash(cols, rows, col, row, colspan, rowspan);

  @override
  String toString() =>
      'WindowZone(${cols}x$rows @ $col,$row +${colspan}x$rowspan)';
}

/// Um jeito de dividir a tela, com as zonas que ele oferece.
///
/// O catálogo vive **no app**, e não no agente nem no servidor: é ele que
/// precisa desenhar o seletor. Do outro lado só chega a célula escolhida, e o
/// agente sabe transformar célula em pixels sem conhecer layout nenhum. Uma
/// cópia do catálogo lá seria uma segunda fonte de verdade para a mesma coisa.
class WindowLayout {
  const WindowLayout({
    required this.id,
    required this.cols,
    required this.rows,
    required this.zones,
  });

  /// Guardado em lugar nenhum — o id serve para o seletor comparar escolhas.
  final String id;
  final int cols;
  final int rows;
  final List<WindowZone> zones;

  /// Quantas janelas este layout acomoda.
  int get slots => zones.length;

  /// Os layouts oferecidos, na ordem em que aparecem no seletor.
  ///
  /// São os mesmos do menu de encaixe do Windows 11, e a semelhança é
  /// deliberada: quem já usou aquele menu reconhece os desenhos e não precisa
  /// aprender nada.
  static const List<WindowLayout> all = [
    // Metades: o mais usado de longe, e por isso o primeiro.
    WindowLayout(
      id: 'metades',
      cols: 2,
      rows: 1,
      zones: [
        WindowZone(cols: 2, rows: 1, col: 0, row: 0),
        WindowZone(cols: 2, rows: 1, col: 1, row: 0),
      ],
    ),
    // 2/3 + 1/3: navegador grande com um bloco de notas ao lado.
    WindowLayout(
      id: 'dois-tercos',
      cols: 3,
      rows: 1,
      zones: [
        WindowZone(cols: 3, rows: 1, col: 0, row: 0, colspan: 2),
        WindowZone(cols: 3, rows: 1, col: 2, row: 0),
      ],
    ),
    WindowLayout(
      id: 'tres-colunas',
      cols: 3,
      rows: 1,
      zones: [
        WindowZone(cols: 3, rows: 1, col: 0, row: 0),
        WindowZone(cols: 3, rows: 1, col: 1, row: 0),
        WindowZone(cols: 3, rows: 1, col: 2, row: 0),
      ],
    ),
    WindowLayout(
      id: 'quadrantes',
      cols: 2,
      rows: 2,
      zones: [
        WindowZone(cols: 2, rows: 2, col: 0, row: 0),
        WindowZone(cols: 2, rows: 2, col: 1, row: 0),
        WindowZone(cols: 2, rows: 2, col: 0, row: 1),
        WindowZone(cols: 2, rows: 2, col: 1, row: 1),
      ],
    ),
    // Uma principal à esquerda e duas empilhadas à direita.
    WindowLayout(
      id: 'principal-e-duas',
      cols: 2,
      rows: 2,
      zones: [
        WindowZone(cols: 2, rows: 2, col: 0, row: 0, rowspan: 2),
        WindowZone(cols: 2, rows: 2, col: 1, row: 0),
        WindowZone(cols: 2, rows: 2, col: 1, row: 1),
      ],
    ),
  ];

  /// O layout a que uma zona pertence, ou `null` quando ela não é de nenhum.
  ///
  /// Serve para reabrir o editor no layout que a pessoa escolheu: o perfil
  /// guarda zonas, não o nome do layout, e é daqui que ele se deduz.
  static WindowLayout? containing(WindowZone? zone) {
    if (zone == null) return null;
    for (final l in all) {
      if (l.cols == zone.cols && l.rows == zone.rows && l.zones.contains(zone)) {
        return l;
      }
    }
    return null;
  }

  /// O layout de um perfil: o do primeiro programa que tem zona.
  ///
  /// Um perfil misto (zonas de layouts diferentes) não deveria existir — o
  /// editor não deixa —, mas se existir, vence o primeiro. Melhor abrir o
  /// editor em algum layout do que em nenhum.
  static WindowLayout? ofZones(Iterable<WindowZone?> zones) {
    for (final z in zones) {
      final l = containing(z);
      if (l != null) return l;
    }
    return null;
  }
}
