/// O que o widget do celular mostra: um computador e até três botões.
///
/// Fica no servidor (`/api/v1/widget`), e não no aparelho: o widget do iPhone
/// é um programa à parte do app, e é de lá que ele lê. Ver
/// `backend/app/widget.py`.
library;

/// O que um botão do widget faz. `valor` é o nome no protocolo.
enum TipoDeBotao {
  apresentacao('apresentacao'),
  tocarPausar('tocar_pausar'),
  automacao('automacao'),
  suspender('suspender'),
  volumeMais('volume_mais'),
  volumeMenos('volume_menos'),
  silenciar('silenciar');

  const TipoDeBotao(this.valor);
  final String valor;

  static TipoDeBotao? doValor(String? valor) {
    for (final t in values) {
      if (t.valor == valor) return t;
    }
    return null;
  }
}

class BotaoDoWidget {
  const BotaoDoWidget(this.tipo, {this.automacaoId, this.automacaoNome});

  final TipoDeBotao tipo;
  final String? automacaoId;

  /// O nome da automação, como o servidor resolveu. Só para mostrar.
  final String? automacaoNome;

  /// A escolha numa linha só: `apresentacao`, ou `automacao:<id>`. É o valor
  /// dos menus da tela de widgets.
  String get chave =>
      tipo == TipoDeBotao.automacao ? 'automacao:${automacaoId ?? ''}' : tipo.valor;

  static BotaoDoWidget? daChave(String chave) {
    if (chave.startsWith('automacao:')) {
      final id = chave.substring('automacao:'.length);
      return id.isEmpty ? null : BotaoDoWidget(TipoDeBotao.automacao, automacaoId: id);
    }
    final tipo = TipoDeBotao.doValor(chave);
    return (tipo == null || tipo == TipoDeBotao.automacao) ? null : BotaoDoWidget(tipo);
  }

  static BotaoDoWidget? fromJson(Map<String, dynamic> json) {
    final tipo = TipoDeBotao.doValor(json['tipo'] as String?);
    if (tipo == null) return null; // tipo de uma versão mais nova do servidor
    return BotaoDoWidget(
      tipo,
      automacaoId: json['automacao_id'] as String?,
      automacaoNome: json['automacao_nome'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'tipo': tipo.valor,
        if (tipo == TipoDeBotao.automacao) 'automacao_id': automacaoId,
      };
}

class ConfigDoWidget {
  const ConfigDoWidget({
    this.deviceId,
    this.deviceName,
    this.online = false,
    this.botoes = const [],
    this.atalhos = const [],
  });

  final String? deviceId;
  final String? deviceName;
  final bool online;
  final List<BotaoDoWidget> botoes;

  /// As automações ao segurar o ícone do app. Vazio = as primeiras da lista.
  final List<String> atalhos;

  factory ConfigDoWidget.fromJson(Map<String, dynamic> json) => ConfigDoWidget(
        deviceId: json['device_id'] as String?,
        deviceName: json['device_name'] as String?,
        online: json['online'] as bool? ?? false,
        // `whereType` e não o `?elemento` da sintaxe nova: o pubspec ainda
        // aceita Dart 3.4, que não a conhece.
        botoes: [
          for (final b in (json['botoes'] as List?) ?? const [])
            if (b is Map<String, dynamic>) BotaoDoWidget.fromJson(b),
        ].whereType<BotaoDoWidget>().toList(),
        atalhos: [
          for (final a in (json['atalhos'] as List?) ?? const [])
            if (a is String) a,
        ],
      );

  /// O que vai no `PUT`. Só a escolha: nome e estado são do servidor.
  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'botoes': [for (final b in botoes) b.toJson()],
        'atalhos': atalhos,
      };
}
