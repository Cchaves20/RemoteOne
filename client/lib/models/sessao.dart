/// Um aparelho com a conta aberta, como o `/auth/sessions` o devolve.
class Sessao {
  const Sessao({
    required this.id,
    required this.aparelho,
    required this.ultimoUso,
    this.atual = false,
  });

  final String id;

  /// Como o app daquele aparelho se descreveu ("iPhone · iOS 18.1"). Vazio
  /// num app de antes desta tela.
  final String aparelho;

  final DateTime ultimoUso;

  /// A sessão deste aparelho — a que não ganha o botão "Sair".
  final bool atual;

  factory Sessao.fromJson(Map<String, dynamic> json) => Sessao(
        id: json['id'] as String,
        aparelho: (json['aparelho'] as String?) ?? '',
        // `tryParse` com o agora como reserva: uma data estranha não pode
        // derrubar a lista inteira.
        ultimoUso: DateTime.tryParse(json['ultimo_uso'] as String? ?? '')
                ?.toLocal() ??
            DateTime.now(),
        atual: json['atual'] as bool? ?? false,
      );
}
