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
    this.plano = 'gratis',
    this.planoAte,
  });

  final int id;

  /// Um dos dois vem preenchido — é o que identifica a conta e o que se digita
  /// para entrar.
  final String? email;
  final String? phone;

  final String firstName;
  final String lastName;
  final bool twoFactorEnabled;

  /// `'gratis'` ou `'pago'`, **já considerando a validade**.
  ///
  /// O servidor calcula e manda pronto. Recalcular aqui a partir da data seria
  /// uma segunda verdade sobre a mesma conta — e a que manda é a do servidor,
  /// porque é ela que recusa as chamadas. Duas contas dessas discordando é
  /// como se constrói uma tela que promete o que a chamada seguinte nega.
  final String plano;

  /// Até quando o plano pago vale. Nulo = sem prazo, ou já no grátis.
  final DateTime? planoAte;

  bool get ehPago => plano == 'pago';

  /// Quantos dias faltam, arredondando para cima.
  ///
  /// Para cima porque é assim que uma pessoa conta: faltando 6 horas, ela diz
  /// "termina amanhã", não "faltam zero dias". Nulo quando não há prazo.
  int? get diasRestantes {
    if (planoAte == null) return null;
    final falta = planoAte!.difference(DateTime.now());
    if (falta.isNegative) return 0;
    return falta.inHours ~/ 24 + (falta.inHours % 24 > 0 ? 1 : 0);
  }

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
        plano: (json['plano'] as String?) ?? 'gratis',
        // `tryParse` e não `parse`: um backend antigo não manda o campo, e um
        // formato inesperado não pode derrubar a tela da conta inteira por
        // causa de uma data.
        planoAte: json['plano_ate'] == null
            ? null
            : DateTime.tryParse(json['plano_ate'] as String)?.toLocal(),
      );
}
