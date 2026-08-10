/// O estado de um cadastro esperando o código de verificação.
///
/// É o que a primeira etapa devolve e o que a tela de verificação carrega. O
/// `destination` vem **normalizado pelo servidor** — telefone em E.164, e-mail
/// em minúsculas — e é ele que volta na segunda etapa: repetir a normalização
/// aqui abriria a chance de o app errar de um jeito diferente e mandar um
/// destino que não casa com nenhum cadastro pendente.
class SignupPending {
  const SignupPending({
    required this.destination,
    required this.channel,
    this.resendInSeconds = 60,
    this.delivered = true,
  });

  final String destination;

  /// "email" ou "phone". Decide o texto da tela — "confira sua caixa de
  /// entrada" e "confira suas mensagens" não são a mesma frase.
  final String channel;

  /// Quanto falta para o botão de reenviar valer. A tela mostra a contagem em
  /// vez de deixar a pessoa tocar e receber um erro.
  final int resendInSeconds;

  /// Falso quando o servidor ainda não tem provedor configurado e o código foi
  /// para o diário. A tela avisa — sem isso, a pessoa esperaria um SMS que
  /// nunca vai chegar, e concluiria que o app está quebrado.
  final bool delivered;

  bool get porEmail => channel == 'email';

  factory SignupPending.fromJson(Map<String, dynamic> json) => SignupPending(
        destination: (json['destination'] as String?) ?? '',
        channel: (json['channel'] as String?) ?? 'email',
        resendInSeconds: (json['resend_in_seconds'] as num?)?.toInt() ?? 60,
        delivered: json['delivered'] as bool? ?? true,
      );
}
