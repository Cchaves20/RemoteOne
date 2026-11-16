/// De onde vem a energia do computador agora.
enum PowerSource {
  ac,
  battery,
  unknown;

  static PowerSource parse(String? raw) => switch (raw) {
        'ac' => PowerSource.ac,
        'battery' => PowerSource.battery,
        _ => PowerSource.unknown,
      };
}

/// Se o computador está sendo mantido pronto para ser alcançado.
///
/// São três informações e não uma, porque **ligado não é o mesmo que
/// segurando**. Um notebook na bateria com a opção ligada não está segurando
/// nada: o agente solta o pedido para não drenar a bateria com a tampa
/// fechada. Mostrar só a chave ligada prometeria um computador alcançável que
/// vai dormir na próxima pausa - e a promessa quebrada aparece justamente
/// quando a pessoa está longe e precisa dele.
class KeepAwakeState {
  const KeepAwakeState({
    required this.enabled,
    required this.holding,
    required this.source,
  });

  /// O que o usuário escolheu.
  final bool enabled;

  /// Se o pedido ao sistema está de pé neste instante.
  final bool holding;

  /// De onde vem a energia, que é o que explica a diferença entre os dois.
  final PowerSource source;

  factory KeepAwakeState.fromJson(Map<String, dynamic> json) => KeepAwakeState(
        enabled: json['enabled'] as bool? ?? false,
        holding: json['holding'] as bool? ?? false,
        source: PowerSource.parse(json['source'] as String?),
      );

  /// Ligado, mas sem efeito agora. É o estado que precisa de explicação na
  /// tela: nem "desligado", nem "tudo certo".
  bool get suspended => enabled && !holding;
}
