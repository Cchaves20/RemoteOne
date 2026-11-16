/// Como está o modo apresentação num computador.
///
/// O modo faz duas coisas: segura a tela acesa e cala as notificações. O que
/// ele evita é específico e constrangedor — a mensagem que salta no canto da
/// tela com o projetor ligado e a sala inteira lendo junto.
class PresentationState {
  const PresentationState({
    required this.on,
    required this.auto,
    this.detected,
    this.supported = true,
  });

  /// Se o modo está valendo agora.
  final bool on;

  /// Se a detecção automática está ligada. Editável só na área de perfis.
  final bool auto;

  /// O que a detecção está vendo — o título da janela em tela cheia.
  ///
  /// É o que explica um modo que ligou sozinho. Sem isto, a pessoa vê a chave
  /// ligada e não faz ideia de quem a ligou.
  final String? detected;

  /// Falso quando aquele Windows não tem com que silenciar as notificações.
  ///
  /// A tela continua acesa — isso o agente garante sozinho. O que falha é só o
  /// silêncio, e mostrar a diferença é melhor que prometer o que não acontece.
  final bool supported;

  factory PresentationState.fromJson(Map<String, dynamic> json) =>
      PresentationState(
        on: json['on'] as bool? ?? false,
        auto: json['auto'] as bool? ?? false,
        detected: json['detected'] as String?,
        supported: json['supported'] as bool? ?? true,
      );

  PresentationState copyWith({bool? on, bool? auto}) => PresentationState(
        on: on ?? this.on,
        auto: auto ?? this.auto,
        detected: detected,
        supported: supported,
      );
}
