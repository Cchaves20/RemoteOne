/// A conta de quem está usando o app, como o `/auth/me` a devolve.
///
/// Existe por uma pergunta que a tela de conta passou a ter de responder:
/// **por qual das duas coisas esta conta se identifica?** Uma criada por
/// telefone não tem e-mail nenhum, e mostrar "Alterar e-mail" ali era oferecer
/// um botão que não servia para nada.
class Conta {
  const Conta({
    required this.id,
    this.email,
    this.phone,
    this.firstName = '',
    this.lastName = '',
    this.twoFactorEnabled = false,
  });

  final int id;

  /// Um dos dois vem preenchido — é o que identifica a conta e o que se digita
  /// para entrar.
  final String? email;
  final String? phone;

  final String firstName;
  final String lastName;
  final bool twoFactorEnabled;

  /// Se a conta se identifica por telefone.
  ///
  /// Pela **presença do telefone**, e não pela ausência do e-mail: se um dia
  /// existirem os dois (hoje não existem), a conta continua sendo "de
  /// telefone" para quem a criou assim, e a tela não muda debaixo da pessoa.
  bool get porTelefone => phone != null && phone!.isNotEmpty;

  /// Como a conta aparece na tela: o contato que a identifica.
  String get contato => porTelefone ? phone! : (email ?? '');

  /// Nome e sobrenome, ou o contato quando ainda não há nome — é o caso das
  /// contas criadas antes de o cadastro pedir nome.
  String get nomeCompleto {
    final inteiro = '$firstName $lastName'.trim();
    return inteiro.isEmpty ? contato : inteiro;
  }

  factory Conta.fromJson(Map<String, dynamic> json) => Conta(
        id: (json['id'] as num?)?.toInt() ?? 0,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        firstName: (json['first_name'] as String?) ?? '',
        lastName: (json['last_name'] as String?) ?? '',
        twoFactorEnabled: json['totp_enabled'] as bool? ?? false,
      );
}
